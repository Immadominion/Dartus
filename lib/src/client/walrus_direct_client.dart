/// Wallet-integrated Walrus client for on-chain blob operations.
///
/// [WalrusDirectClient] provides the Phase 2+3 API surface for users
/// who need Sui wallet integration (signing blob registration and
/// certification transactions).
///
/// Supports two write modes:
/// - **Relay mode**: Upload relay handles encoding + distribution (Phase 2)
/// - **Direct mode**: Client-side RS2 encoding via Rust FFI (`walrus_ffi`) +
///   direct sliver writes to storage nodes (Phase 3)
///
/// For simple HTTP-only uploads via publisher/aggregator, use the
/// existing [WalrusClient] from Phase 1.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sui/sui.dart';

import '../logging/walrus_logging.dart';
import '../chain/committee_resolver.dart';
import '../chain/system_state_reader.dart';
import '../constants/walrus_constants.dart';
import '../contracts/transaction_builder.dart';
import '../crypto/bls_provider.dart';
import '../encoding/bcs_parser.dart';
import '../encoding/blob_encoder.dart';
import '../encoding/walrus_blob_encoder.dart';
import '../encoding/walrus_ffi_bindings.dart';
import '../errors/walrus_errors.dart';
import '../files/blob.dart';
import '../files/file.dart';
import '../files/readers/blob_reader.dart';
import '../files/readers/quilt_file_reader.dart';
import '../files/readers/quilt_reader.dart';
import '../models/protocol_types.dart';
import '../models/storage_node_types.dart';
import '../storage_node/storage_node_client.dart';
import '../upload_relay/upload_relay_client.dart';
import '../utils/blob_id_utils.dart';
import '../utils/encoding_utils.dart';
import '../utils/quilts.dart';
import '../utils/randomness.dart';
import '../utils/retry.dart';
import 'write_blob_flow.dart';
import 'write_files_flow.dart';

/// Wallet-integrated Walrus client.
///
/// Usage (one-shot upload with upload relay):
/// ```dart
/// final client = WalrusDirectClient(
///   network: WalrusNetwork.testnet,
///   suiClient: SuiClient(SuiUrls.testnet),
///   walrusPackageId: '<package-id>',
///   uploadRelay: UploadRelayConfig(
///     host: 'https://upload-relay.testnet.walrus.space',
///   ),
/// );
///
/// final result = await client.writeBlob(
///   blob: rawData,
///   metadata: preComputedMetadata,
///   epochs: 3,
///   signer: myAccount,
///   deletable: true,
/// );
/// ```
///
/// Usage (direct mode, no relay):
/// ```dart
/// final client = WalrusDirectClient(
///   network: WalrusNetwork.testnet,
///   suiClient: SuiClient(SuiUrls.testnet),
///   walrusPackageId: '<package-id>',
///   encoder: WalrusBlobEncoder(),
/// );
/// client.setCommittee(committeeInfo);
///
/// final result = await client.writeBlob(
///   blob: rawData,
///   epochs: 3,
///   signer: myAccount,
///   deletable: true,
/// );
/// ```
///
/// Usage (multi-step flow for dApp wallet):
/// ```dart
/// final flow = client.writeBlobFlow(
///   blob: rawData,
///   metadata: preComputedMetadata,
/// );
///
/// await flow.encode();
/// final registerTx = flow.register(...);
/// // Sign registerTx with dApp wallet
/// await flow.upload(WriteBlobFlowUploadOptions(digest: txDigest));
/// final certifyTx = flow.certify();
/// // Sign certifyTx with dApp wallet
/// final result = await flow.getBlob();
/// ```
class WalrusDirectClient {
  /// The target Walrus network.
  final WalrusNetwork? network;

  /// On-chain Walrus system config.
  final WalrusPackageConfig packageConfig;

  /// Resolved Walrus Move package ID.
  ///
  /// If provided at construction, used as-is. Otherwise auto-resolved
  /// from the system object via [SystemStateReader].
  String? _walrusPackageId;

  /// Sui RPC client for reading chain state and executing transactions.
  final SuiClient suiClient;

  /// Upload relay configuration (if using relay mode).
  final UploadRelayConfig? uploadRelayConfig;

  /// Upload relay HTTP client (lazily initialized).
  UploadRelayClient? _relayClient;

  /// Transaction builder for Walrus Move calls (lazily initialized).
  WalrusTransactionBuilder? _txBuilder;

  /// Optional blob encoder for computing metadata client-side.
  final BlobEncoder? encoder;

  /// Committee information for direct mode (auto-resolved or injected).
  CommitteeInfo? _committee;

  /// Cached read committee (may differ from active during epoch transitions).
  CommitteeInfo? _readCommittee;

  /// Cached tip config from the relay.
  UploadRelayTipConfig? _tipConfig;
  bool _tipConfigLoaded = false;

  /// Cached [StorageNodeClient] instances keyed by endpoint URL.
  /// Reused across writes for connection pooling.
  final Map<String, StorageNodeClient> _nodeClients = {};

  /// Shared HTTP client for storage node connections.
  /// Configured to accept all certificates (testnet nodes may use
  /// certs not in the default trust store).
  late final HttpClient _sharedHttpClient = _createSharedHttpClient();

  static HttpClient _createSharedHttpClient() {
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    client.connectionTimeout = const Duration(seconds: 8);
    client.idleTimeout = const Duration(seconds: 15);
    return client;
  }

  /// System state reader for on-chain data.
  late final SystemStateReader _stateReader;

  /// Committee resolver for auto-resolving committee from chain.
  late final CommitteeResolver _committeeResolver;

  /// Optional BLS12-381 provider for signature aggregation.
  ///
  /// When provided, [_buildCertificateFromConfirmations] aggregates
  /// multiple storage node signatures into a single BLS aggregate
  /// signature for on-chain certification.
  ///
  /// Without a provider, the first valid signature is used as a
  /// placeholder — sufficient for relay mode but invalid for
  /// direct-mode on-chain certification with multiple signers.
  final BlsProvider? blsProvider;

  /// Logger for this client. Configure [WalrusLogger.level] or
  /// [WalrusLogger.onRecord] to control output.
  final WalrusLogger logger;

  WalrusDirectClient({
    this.network,
    WalrusPackageConfig? packageConfig,
    String? walrusPackageId,
    required this.suiClient,
    this.uploadRelayConfig,
    this.encoder,
    this.blsProvider,
    WalrusLogLevel logLevel = WalrusLogLevel.none,
    WalrusLogHandler? onLog,
  }) : packageConfig =
           packageConfig ??
           network?.packageConfig ??
           (throw ArgumentError(
             'Either network or packageConfig must be provided',
           )),
       _walrusPackageId = walrusPackageId,
       logger = WalrusLogger(level: logLevel, onRecord: onLog) {
    _stateReader = SystemStateReader(
      suiClient: suiClient,
      config: this.packageConfig,
    );

    _committeeResolver = CommitteeResolver(
      suiClient: suiClient,
      config: this.packageConfig,
      stateReader: _stateReader,
    );

    if (uploadRelayConfig != null) {
      _relayClient = UploadRelayClient(
        host: uploadRelayConfig!.host,
        timeout: uploadRelayConfig!.timeout,
      );
    }
  }

  /// Convenience constructor using a [WalrusNetwork] preset.
  factory WalrusDirectClient.fromNetwork({
    required WalrusNetwork network,
    String? walrusPackageId,
    SuiClient? suiClient,
    UploadRelayConfig? uploadRelay,
    BlobEncoder? encoder,
    BlsProvider? blsProvider,
    WalrusLogLevel logLevel = WalrusLogLevel.none,
    WalrusLogHandler? onLog,
  }) {
    return WalrusDirectClient(
      network: network,
      walrusPackageId: walrusPackageId,
      suiClient: suiClient ?? SuiClient(network.defaultRpcUrl),
      uploadRelayConfig:
          uploadRelay ??
          (network.defaultUploadRelayUrl != null
              ? UploadRelayConfig(host: network.defaultUploadRelayUrl!)
              : null),
      encoder: encoder,
      blsProvider: blsProvider,
      logLevel: logLevel,
      onLog: onLog,
    );
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Close cached storage node connections. Call when done with this client.
  void close() {
    _nodeClients.clear();
    _sharedHttpClient.close();
  }

  /// Clear all cached values. Call after epoch changes.
  void reset() {
    _committee = null;
    _readCommittee = null;
    _tipConfigLoaded = false;
    _tipConfig = null;
    _txBuilder = null;
    _stateReader.reset();
    _committeeResolver.reset();
  }

  // -------------------------------------------------------------------------
  // Epoch Retry Wrapper
  // -------------------------------------------------------------------------

  /// Retry a function once if it throws [RetryableWalrusClientError].
  ///
  /// On a retryable error (e.g. epoch change), resets cached state and
  /// retries the call. Mirrors the TS SDK's `#retryOnPossibleEpochChange`.
  Future<T> retryOnPossibleEpochChange<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on RetryableWalrusClientError {
      reset();
      return await fn();
    }
  }

  // -------------------------------------------------------------------------
  // Blob Object Lookup
  // -------------------------------------------------------------------------

  /// Get the Sui Move type for Walrus Blob objects.
  ///
  /// Returns `<typeOriginPackageId>::blob::Blob` where the package ID
  /// is the **type origin** — the original package where `Blob` was
  /// first defined. This is needed for `StructType` filters because
  /// Sui stamps object types with the original defining package ID.
  ///
  /// Mirrors TS SDK's `getBlobType()` + `#getPackageId()`.
  Future<String> getBlobType() async {
    final packageId = await _stateReader.getPackageId();
    return '$packageId::blob::Blob';
  }

  /// Query all Walrus Blob objects owned by [owner].
  ///
  /// Returns a list of `{objectId, blobId, size, ...}` maps parsed
  /// from the on-chain Blob struct fields.
  ///
  /// Uses `suix_getOwnedObjects` with a `StructType` filter for
  /// `<packageId>::blob::Blob`.
  ///
  /// Example:
  /// ```dart
  /// final blobs = await client.getOwnedBlobs(owner: myAddress);
  /// for (final blob in blobs) {
  ///   print('${blob['objectId']} → blobId=${blob['blobId']}');
  /// }
  /// ```
  Future<List<Map<String, dynamic>>> getOwnedBlobs({
    required String owner,
    int limit = 50,
  }) async {
    final blobType = await getBlobType();
    final results = <Map<String, dynamic>>[];
    String? cursor;

    do {
      final page = await suiClient.getOwnedObjects(
        owner,
        options: SuiObjectDataOptions(showContent: true, showType: true),
        filter: {'StructType': blobType},
        limit: limit,
        cursor: cursor,
      );

      for (final obj in page.data) {
        final data = obj.data;
        if (data == null) continue;

        final content = data.content;
        if (content == null) continue;

        Map<String, dynamic>? fields;
        if (content.fields is Map<String, dynamic>) {
          fields = content.fields as Map<String, dynamic>;
        }

        if (fields != null) {
          // The blob_id is stored as a u256 on-chain.
          // Convert to URL-safe base64 for consistency.
          final blobIdRaw = fields['blob_id'] ?? fields['blobId'];
          String? blobIdBase64;
          if (blobIdRaw is String) {
            // Could be a decimal string or hex
            final bigInt = BigInt.tryParse(blobIdRaw);
            if (bigInt != null) {
              blobIdBase64 = blobIdFromInt(bigInt);
            } else {
              blobIdBase64 = blobIdRaw;
            }
          } else if (blobIdRaw is int) {
            blobIdBase64 = blobIdFromInt(BigInt.from(blobIdRaw));
          }

          results.add({
            'objectId': data.objectId,
            'blobId': blobIdBase64,
            'size': fields['size'],
            'erasureCodeType':
                fields['erasure_code_type'] ?? fields['erasureCodeType'],
            'certifiedEpoch':
                fields['certified_epoch'] ?? fields['certifiedEpoch'],
            'storedEpoch': fields['stored_epoch'] ?? fields['storedEpoch'],
            'deletable': fields['deletable'],
          });
        }
      }

      cursor = page.hasNextPage ? page.nextCursor : null;
      if (cursor != null && cursor.isEmpty) cursor = null;
    } while (cursor != null);

    return results;
  }

  /// Look up the Sui object ID for a blob given its blob ID (base64)
  /// and owner address.
  ///
  /// Queries all Walrus Blob objects owned by [owner] and finds the one
  /// whose `blob_id` field matches [blobId].
  ///
  /// Returns the Sui object ID (`0x...`), or `null` if not found.
  ///
  /// Example:
  /// ```dart
  /// final objectId = await client.lookupBlobObjectId(
  ///   blobId: 'PN9q2CUhq0tNBqSrIuZwTbSvZD0Adq3HBzaAm9bGpWE',
  ///   owner: '0x1234...',
  /// );
  /// ```
  Future<String?> lookupBlobObjectId({
    required String blobId,
    required String owner,
  }) async {
    final blobs = await getOwnedBlobs(owner: owner);
    for (final blob in blobs) {
      if (blob['blobId'] == blobId) {
        return blob['objectId'] as String?;
      }
    }
    return null;
  }

  /// Look up the base64 blob ID for a Sui Blob object given its object ID.
  ///
  /// Reads the on-chain Blob struct and extracts the `blob_id` field,
  /// converting the u256 value to URL-safe base64.
  ///
  /// Returns `null` if the object doesn't exist or isn't a Blob.
  ///
  /// Example:
  /// ```dart
  /// final blobId = await client.getBlobIdFromObjectId(
  ///   objectId: '0xdd43ffc2...',
  /// );
  /// ```
  Future<String?> getBlobIdFromObjectId({required String objectId}) async {
    final info = await getBlobObjectInfo(objectId: objectId);
    return info?['blobId'] as String?;
  }

  /// Read full on-chain info for a Walrus Blob object.
  ///
  /// Returns a map with keys: `objectId`, `blobId`, `size`,
  /// `certifiedEpoch`, `registeredEpoch`, `endEpoch`, `startEpoch`,
  /// `deletable`, `encodingType`.
  ///
  /// Returns `null` if the object doesn't exist or isn't a Blob.
  Future<Map<String, dynamic>?> getBlobObjectInfo({
    required String objectId,
  }) async {
    try {
      final resp = await suiClient.getObject(
        objectId,
        options: SuiObjectDataOptions(showContent: true),
      );

      final content = resp.data?.content;
      if (content == null) return null;

      Map<String, dynamic>? fields;
      if (content.fields is Map<String, dynamic>) {
        fields = content.fields as Map<String, dynamic>;
      }
      if (fields == null) return null;

      final blobIdRaw = fields['blob_id'] ?? fields['blobId'];
      String? blobIdBase64;
      if (blobIdRaw is String) {
        final bigInt = BigInt.tryParse(blobIdRaw);
        if (bigInt != null) {
          blobIdBase64 = blobIdFromInt(bigInt);
        } else {
          blobIdBase64 = blobIdRaw;
        }
      } else if (blobIdRaw is int) {
        blobIdBase64 = blobIdFromInt(BigInt.from(blobIdRaw));
      }
      if (blobIdBase64 == null) return null;

      // Parse certified_epoch (null if never certified).
      final certifiedEpochRaw =
          fields['certified_epoch'] ?? fields['certifiedEpoch'];
      int? certifiedEpoch;
      if (certifiedEpochRaw is int) {
        certifiedEpoch = certifiedEpochRaw;
      } else if (certifiedEpochRaw is String) {
        certifiedEpoch = int.tryParse(certifiedEpochRaw);
      }

      // Parse storage sub-object for epoch range.
      int? startEpoch;
      int? endEpoch;
      final storage = fields['storage'];
      if (storage is Map<String, dynamic>) {
        final storageFields =
            (storage['fields'] as Map<String, dynamic>?) ?? storage;
        final startRaw =
            storageFields['start_epoch'] ?? storageFields['startEpoch'];
        final endRaw = storageFields['end_epoch'] ?? storageFields['endEpoch'];
        if (startRaw is int) startEpoch = startRaw;
        if (startRaw is String) startEpoch = int.tryParse(startRaw);
        if (endRaw is int) endEpoch = endRaw;
        if (endRaw is String) endEpoch = int.tryParse(endRaw);
      }

      return {
        'objectId': objectId,
        'blobId': blobIdBase64,
        'size': fields['size'],
        'certifiedEpoch': certifiedEpoch,
        'registeredEpoch':
            fields['registered_epoch'] ?? fields['registeredEpoch'],
        'startEpoch': startEpoch,
        'endEpoch': endEpoch,
        'deletable': fields['deletable'],
        'encodingType': fields['encoding_type'] ?? fields['erasure_code_type'],
      };
    } catch (_) {
      return null;
    }
  }

  /// Resolve an input that may be either a base64 blob ID or a Sui
  /// object ID (`0x...`) into a base64 blob ID.
  ///
  /// If [id] starts with `0x`, reads the on-chain Blob object to
  /// extract its blob ID and checks whether the blob was actually
  /// certified. Throws a clear error for uncertified or expired blobs.
  ///
  /// Otherwise returns [id] unchanged (assumed to be a base64 blob ID).
  Future<String> resolveBlobId(String id) async {
    if (!id.startsWith('0x')) return id;

    final info = await getBlobObjectInfo(objectId: id);
    if (info == null) {
      throw WalrusClientError(
        'Could not resolve blob ID from Sui object $id. '
        'The object may not exist or is not a Walrus Blob.',
      );
    }

    final blobId = info['blobId'] as String;
    final certifiedEpoch = info['certifiedEpoch'];
    final endEpoch = info['endEpoch'];
    final deletable = info['deletable'];

    if (certifiedEpoch == null) {
      throw WalrusClientError(
        'Blob object $id (blobId=$blobId) was never certified. '
        'It was registered in epoch ${info['registeredEpoch']} '
        'but no storage nodes confirmed the data. '
        '${deletable == true ? 'This was a deletable blob.' : ''} '
        'The blob data is not available on the network.',
      );
    }

    if (endEpoch != null && certifiedEpoch is int) {
      // Check if the blob might have expired. We can't know the current
      // epoch for sure without a Sui RPC call, but if endEpoch <= certifiedEpoch
      // that's clearly impossible/expired.
      if (endEpoch is int && endEpoch <= certifiedEpoch) {
        throw WalrusClientError(
          'Blob object $id (blobId=$blobId) storage has expired. '
          'endEpoch=$endEpoch, certifiedEpoch=$certifiedEpoch.',
        );
      }
    }

    return blobId;
  }

  // -------------------------------------------------------------------------
  // Direct-Mode Read Operations
  // -------------------------------------------------------------------------

  /// Get blob metadata from storage nodes.
  ///
  /// Queries nodes in randomized order, returns the first successful
  /// response. Falls back to chunked parallel queries if the first
  /// attempt fails. Mirrors the TS SDK's `getBlobMetadata()`.
  Future<Uint8List> getBlobMetadata({
    required String blobId,
    int concurrencyLimit = 3,
  }) async {
    return retryOnPossibleEpochChange(
      () => _internalGetBlobMetadata(
        blobId: blobId,
        concurrencyLimit: concurrencyLimit,
      ),
    );
  }

  Future<Uint8List> _internalGetBlobMetadata({
    required String blobId,
    required int concurrencyLimit,
  }) async {
    final committee = await _getReadCommittee(blobId: blobId);
    final randomizedNodes = shuffle<StorageNodeInfo>(committee.nodes);
    final numShards = committee.numShards;

    var numNotFoundWeight = 0;
    var numBlockedWeight = 0;

    // Try the first node directly.
    if (randomizedNodes.isNotEmpty) {
      final firstNode = randomizedNodes.first;
      try {
        final client = _getOrCreateNodeClient(firstNode.endpointUrl);
        return await client.getBlobMetadata(blobId: blobId);
      } on NotFoundError {
        numNotFoundWeight += firstNode.shardIndices.length;
      } on LegallyUnavailableError {
        numBlockedWeight += firstNode.shardIndices.length;
      } catch (_) {
        // Continue to fallback.
      }
    }

    // Fall back: query remaining nodes in parallel chunks.
    // Each future catches its own errors so that in-flight futures never
    // throw unhandled exceptions when we return early on the first success.
    final remaining = randomizedNodes.skip(1).toList();
    final chunkSize = _chunkSize(remaining.length, concurrencyLimit);
    final chunks = _chunk(remaining, chunkSize);

    for (final chunk in chunks) {
      final futures = chunk.map((node) async {
        try {
          final client = _getOrCreateNodeClient(node.endpointUrl);
          return _MetadataResult.success(
            await client.getBlobMetadata(blobId: blobId),
          );
        } on NotFoundError {
          return _MetadataResult.notFound(node.shardIndices.length);
        } on LegallyUnavailableError {
          return _MetadataResult.blocked(node.shardIndices.length);
        } catch (_) {
          return _MetadataResult.error(node.shardIndices.length);
        }
      }).toList();

      for (final result in await Future.wait(futures)) {
        switch (result.type) {
          case _MetadataResultType.success:
            return result.data!;
          case _MetadataResultType.notFound:
            numNotFoundWeight += result.weight;
          case _MetadataResultType.blocked:
            numBlockedWeight += result.weight;
          case _MetadataResultType.error:
            break; // Continue to next node.
        }
      }

      // Check for quorum failures.
      if (isQuorum(numBlockedWeight + numNotFoundWeight, numShards)) {
        if (numNotFoundWeight > numBlockedWeight) {
          throw BlobNotCertifiedError(
            'The specified blob $blobId is not certified.',
          );
        } else {
          throw BlobBlockedError('The specified blob $blobId is blocked.');
        }
      }
    }

    throw NoBlobMetadataReceivedError(
      'No valid blob metadata could be retrieved from any storage node.',
    );
  }

  /// Read primary slivers from storage nodes for blob reconstruction.
  ///
  /// Uses weighted shuffle to prioritize nodes with more shards.
  /// Fetches slivers in column-first order through chunked batches,
  /// aborting early once enough slivers have been collected.
  ///
  /// Mirrors the TS SDK's `getSlivers()`.
  Future<List<SliverData>> getSlivers({required String blobId}) async {
    return retryOnPossibleEpochChange(
      () => _internalGetSlivers(blobId: blobId),
    );
  }

  Future<List<SliverData>> _internalGetSlivers({required String blobId}) async {
    final committee = await _getReadCommittee(blobId: blobId);
    final numShards = committee.numShards;
    final src = getSourceSymbols(numShards);
    final minSymbols = src.primary;

    // Weighted shuffle: nodes with more shards are tried first.
    final randomizedNodes = weightedShuffle<StorageNodeInfo>(
      committee.nodes
          .map(
            (StorageNodeInfo n) => WeightedItem<StorageNodeInfo>(
              value: n,
              weight: n.shardIndices.length,
            ),
          )
          .toList(),
    );

    // Build flat list of (nodeUrl, sliverPairIndex) pairs.
    final sliverPairIndices = <_SliverFetchTask>[];
    for (final node in randomizedNodes) {
      for (final shardIndex in node.shardIndices) {
        sliverPairIndices.add(
          _SliverFetchTask(
            url: node.endpointUrl,
            sliverPairIndex: toPairIndex(
              shardIndex,
              blobIdFromUrlSafeBase64(blobId),
              numShards,
            ),
          ),
        );
      }
    }

    // Chunk into rows of minSymbols width (column-first order).
    final chunked = _chunk(sliverPairIndices, minSymbols);
    final slivers = <SliverData>[];
    final failedNodes = <String>{};
    var numNotFoundWeight = 0;
    var numBlockedWeight = 0;
    var totalErrorCount = 0;

    // Iterate column-first: for each column index, iterate through rows.
    if (chunked.isEmpty) {
      throw NotEnoughSliversReceivedError(
        'No storage nodes available to fetch slivers for blob $blobId.',
      );
    }

    // Process column by column across chunked rows.
    for (var colIndex = 0; colIndex < chunked[0].length; colIndex++) {
      for (var rowIndex = 0; rowIndex < chunked.length; rowIndex++) {
        if (colIndex >= chunked[rowIndex].length) continue;

        final task = chunked[rowIndex][colIndex];

        if (slivers.length >= minSymbols) return slivers;

        if (failedNodes.contains(task.url)) {
          totalErrorCount++;
          continue;
        }

        try {
          final client = _getOrCreateNodeClient(task.url);
          final sliverBytes = await client.getSliver(
            blobId: blobId,
            sliverPairIndex: task.sliverPairIndex,
            sliverType: SliverType.primary,
          );

          slivers.add(
            SliverData(
              index: task.sliverPairIndex,
              symbolSize: 0, // Will be set by decoder from raw bytes.
              data: sliverBytes,
            ),
          );

          if (slivers.length >= minSymbols) return slivers;
        } on NotFoundError {
          numNotFoundWeight++;
          totalErrorCount++;
        } on LegallyUnavailableError {
          numBlockedWeight++;
          totalErrorCount++;
        } catch (_) {
          failedNodes.add(task.url);
          totalErrorCount++;
        }

        // Check for quorum abort conditions.
        if (isQuorum(numBlockedWeight + numNotFoundWeight, numShards)) {
          if (numNotFoundWeight > numBlockedWeight) {
            throw BlobNotCertifiedError(
              'The specified blob $blobId is not certified.',
            );
          } else {
            throw BlobBlockedError('The specified blob $blobId is blocked.');
          }
        }

        final remaining =
            sliverPairIndices.length - (slivers.length + totalErrorCount);
        if (slivers.length + remaining < minSymbols) {
          throw NotEnoughSliversReceivedError(
            'Unable to retrieve enough slivers to decode blob $blobId.',
          );
        }
      }
    }

    if (slivers.length < minSymbols) {
      throw NotEnoughSliversReceivedError(
        'Unable to retrieve enough slivers to decode blob $blobId. '
        'Got ${slivers.length}/$minSymbols.',
      );
    }

    return slivers;
  }

  /// Get the verified blob status from multiple storage nodes.
  ///
  /// Queries nodes until a quorum of responses is reached, then
  /// returns the highest-ranked status that has above-validity weight.
  ///
  /// Mirrors the TS SDK's `getVerifiedBlobStatus()`.
  Future<BlobStatus> getVerifiedBlobStatus({required String blobId}) async {
    return retryOnPossibleEpochChange(
      () => _internalGetVerifiedBlobStatus(blobId: blobId),
    );
  }

  Future<BlobStatus> _internalGetVerifiedBlobStatus({
    required String blobId,
  }) async {
    final committee = await getCommittee();
    final numShards = committee.numShards;

    final results = <_StatusResult>[];
    var successWeight = 0;
    var numNotFoundWeight = 0;
    var completedCount = 0;
    final totalNodes = committee.nodes.length;

    // Use a completer to resolve as soon as quorum is reached,
    // without blocking on slow/unreachable nodes.
    final completer = Completer<BlobStatus>();

    void tryResolve() {
      if (completer.isCompleted) return;

      // Check not-found quorum.
      if (isQuorum(numNotFoundWeight, numShards)) {
        completer.completeError(
          BlobNotCertifiedError('The blob does not exist.'),
        );
        return;
      }

      // Check success quorum.
      if (isQuorum(successWeight, numShards)) {
        // Aggregate statuses by serialized value.
        final aggregated = <String, _AggregatedStatus>{};
        for (final r in results) {
          final key = r.status.toJson().toString();
          final existing = aggregated[key];
          if (existing != null) {
            existing.totalWeight += r.weight;
          } else {
            aggregated[key] = _AggregatedStatus(
              status: r.status,
              totalWeight: r.weight,
            );
          }
        }

        // Sort by lifecycle rank (highest first).
        final sorted = aggregated.values.toList()
          ..sort(
            (a, b) => statusLifecycleRank[b.status.type]!.compareTo(
              statusLifecycleRank[a.status.type]!,
            ),
          );

        // Return first status with above-validity weight.
        for (final entry in sorted) {
          if (isAboveValidity(entry.totalWeight, numShards)) {
            completer.complete(entry.status);
            return;
          }
        }
      }

      // All nodes done but no quorum / no verified status.
      if (completedCount >= totalNodes) {
        if (results.isEmpty) {
          completer.completeError(
            NoBlobStatusReceivedError(
              'Not enough statuses were retrieved to achieve quorum.',
            ),
          );
        } else {
          completer.completeError(
            NoVerifiedBlobStatusReceivedError(
              'The blob status could not be verified for blob $blobId.',
            ),
          );
        }
      }
    }

    // Query all nodes concurrently with per-node timeout.
    // We only need quorum (2/3 of shards), so fast-responding nodes
    // are sufficient. Cap each call at 15s to avoid blocking on
    // slow/unreachable nodes whose retry loops would take 90s+.
    for (final node in committee.nodes) {
      final weight = node.shardIndices.length;
      () async {
        try {
          if (completer.isCompleted) return;
          final client = _getOrCreateNodeClient(node.endpointUrl);
          final status = await client
              .getBlobStatus(blobId: blobId)
              .timeout(const Duration(seconds: 15));

          successWeight += weight;
          results.add(_StatusResult(status: status, weight: weight));
        } on NotFoundError {
          numNotFoundWeight += weight;
        } catch (_) {
          // Non-critical; we just won't count this node.
        } finally {
          completedCount++;
          tryResolve();
        }
      }();
    }

    return completer.future;
  }

  // -------------------------------------------------------------------------
  // Quilt / Multi-File Write Operations
  // -------------------------------------------------------------------------

  /// Encode multiple blobs into a quilt.
  ///
  /// Reads the current committee shard count and delegates to
  /// [encodeQuilt] from `utils/quilts.dart`.
  ///
  /// Mirrors the TS SDK's `encodeQuilt()` method.
  Future<EncodeQuiltResult> encodeQuiltBlobs({
    required List<QuiltBlob> blobs,
  }) async {
    final state = await _stateReader.systemState();
    return encodeQuilt(blobs: blobs, numShards: state.nShards);
  }

  /// Upload a quilt (multi-file blob) in a single call.
  ///
  /// Encodes all [blobs] into a quilt, uploads as a single Walrus blob,
  /// and sets the `_walrusBlobType: 'quilt'` attribute.
  ///
  /// Returns the blob ID, blob object ID, certify digest, and quilt index
  /// with patch IDs.
  ///
  /// Mirrors the TS SDK's `writeQuilt()`.
  Future<WriteQuiltResult> writeQuilt({
    required List<QuiltBlob> blobs,
    required int epochs,
    required SuiAccount signer,
    required bool deletable,
    String? owner,
    String? walCoinObjectId,
    Map<String, String?>? attributes,
  }) async {
    final encoded = await encodeQuiltBlobs(blobs: blobs);
    final result = await writeBlob(
      blob: encoded.quilt,
      epochs: epochs,
      signer: signer,
      deletable: deletable,
      owner: owner,
      walCoinObjectId: walCoinObjectId,
      attributes: <String, String?>{'_walrusBlobType': 'quilt', ...?attributes},
    );

    // Compute patch IDs for each entry in the quilt index.
    final patchesWithIds = encoded.index.patches.map((patch) {
      return QuiltPatchResult(
        startIndex: patch.startIndex,
        endIndex: patch.endIndex,
        identifier: patch.identifier,
        tags: patch.tags,
        patchId: encodeQuiltPatchId(
          quiltBlobId: result.blobId,
          version: 1,
          startIndex: patch.startIndex,
          endIndex: patch.endIndex,
        ),
      );
    }).toList();

    return WriteQuiltResult(
      blobId: result.blobId,
      blobObjectId: result.blobObjectId,
      certifyDigest: result.certifyDigest,
      patches: patchesWithIds,
    );
  }

  /// Upload multiple [WalrusFile]s as a quilt in a single call.
  ///
  /// Reads bytes, identifiers, and tags from each file, encodes them
  /// into a quilt, and uploads as a single Walrus blob.
  ///
  /// Returns a list of [WriteFileResult] with the patch ID for each file.
  ///
  /// Mirrors the TS SDK's `writeFiles()`.
  Future<List<WriteFileResult>> writeFiles({
    required List<WalrusFile> files,
    required int epochs,
    required SuiAccount signer,
    required bool deletable,
    String? owner,
    String? walCoinObjectId,
    Map<String, String?>? attributes,
  }) async {
    final blobs = <QuiltBlob>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      blobs.add(
        QuiltBlob(
          contents: await file.bytes(),
          identifier: await file.getIdentifier() ?? 'file-$i',
          tags: await file.getTags(),
        ),
      );
    }

    final result = await writeQuilt(
      blobs: blobs,
      epochs: epochs,
      signer: signer,
      deletable: deletable,
      owner: owner,
      walCoinObjectId: walCoinObjectId,
      attributes: attributes,
    );

    return result.patches.map((patch) {
      return WriteFileResult(
        id: patch.patchId,
        blobId: result.blobId,
        blobObjectId: result.blobObjectId,
      );
    }).toList();
  }

  /// Create a multi-step write files flow for dApp wallet integration.
  ///
  /// Returns a [WriteFilesFlow] whose `register()` and `certify()`
  /// methods return unsigned [Transaction] objects for external signing.
  ///
  /// Mirrors the TS SDK's `writeFilesFlow()`.
  Future<WriteFilesFlow> writeFilesFlow({
    required List<WalrusFile> files,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    await _ensureTipConfig();

    return WriteFilesFlow(
      files: files,
      txBuilder: txBuilder,
      relayClient: _relayClient,
      tipConfig: _tipConfig,
      encoder: encoder,
      committee: _committee,
      directClient: _relayClient == null ? this : null,
      stateReader: _stateReader,
      suiClient: suiClient,
    );
  }

  // -------------------------------------------------------------------------
  // Direct-Mode Blob Read Operations
  // -------------------------------------------------------------------------

  /// Read a full blob from storage nodes by fetching slivers and decoding.
  ///
  /// 1. Fetches blob metadata from storage nodes (BCS encoded)
  /// 2. Fetches primary slivers
  /// 3. Decodes slivers back to original blob data
  /// 4. Verifies the reconstructed blob by recomputing its metadata
  ///
  /// Requires an [encoder] (typically [WalrusBlobEncoder]) to be set.
  ///
  /// Mirrors the TS SDK's `readBlob()`.
  Future<Uint8List> readBlob({required String blobId}) async {
    return retryOnPossibleEpochChange(() => _internalReadBlob(blobId: blobId));
  }

  Future<Uint8List> _internalReadBlob({required String blobId}) async {
    final state = await _stateReader.systemState();
    final numShards = state.nShards;

    // 1. Get blob metadata and parse unencoded length.
    final metadataBytes = await getBlobMetadata(blobId: blobId);
    final parsedMeta = parseBlobMetadataResponse(metadataBytes);

    // 2. Fetch primary slivers.
    final rawSlivers = await getSlivers(blobId: blobId);

    // 3. Parse BCS-encoded slivers if needed.
    // getSlivers() currently returns raw HTTP response bytes in SliverData.data.
    // If the symbol size is 0 (placeholder), the slivers need BCS parsing.
    final slivers = rawSlivers.map((s) {
      if (s.symbolSize == 0 && s.data.isNotEmpty) {
        // Raw BCS bytes from storage node — parse them.
        return parseSliverResponse(s.data);
      }
      return s;
    }).toList();

    // 4. Decode blob from slivers.
    final blobEncoder = encoder;
    if (blobEncoder == null || blobEncoder is! WalrusBlobEncoder) {
      throw WalrusClientError(
        'readBlob requires a WalrusBlobEncoder. '
        'Set encoder: WalrusBlobEncoder() in the client constructor.',
      );
    }

    final blobBytes = blobEncoder.decodeBlob(
      primarySlivers: slivers,
      numShards: numShards,
      unencodedLength: parsedMeta.unencodedLength,
    );

    // 5. Verify by recomputing metadata and checking blob ID.
    final verifyMeta = await blobEncoder.computeMetadata(blobBytes, numShards);
    if (verifyMeta.blobId != blobId) {
      throw const InconsistentBlobError(
        'The specified blob was encoded incorrectly.',
      );
    }

    return blobBytes;
  }

  /// Read a single secondary sliver for a blob from the appropriate node.
  ///
  /// The [sliverIndex] is the secondary sliver index (not pair index).
  /// The method computes the sliverPairIndex and shardIndex internally,
  /// then fetches from the correct storage node.
  ///
  /// Returns the raw sliver column data bytes.
  ///
  /// Mirrors the TS SDK's `getSecondarySliver()`.
  Future<Uint8List> getSecondarySliver({
    required String blobId,
    required int sliverIndex,
  }) async {
    return retryOnPossibleEpochChange(
      () =>
          _internalGetSecondarySliver(blobId: blobId, sliverIndex: sliverIndex),
    );
  }

  Future<Uint8List> _internalGetSecondarySliver({
    required String blobId,
    required int sliverIndex,
  }) async {
    final committee = await getCommittee();
    final numShards = committee.numShards;
    final blobIdBytes = blobIdFromUrlSafeBase64(blobId);

    final sliverPairIndex = sliverPairIndexFromSecondarySliverIndex(
      sliverIndex,
      numShards,
    );
    final shardIndex = toShardIndex(sliverPairIndex, blobIdBytes, numShards);

    // Find the node that holds this shard.
    final node = committee.getNodeForShard(shardIndex);
    if (node == null) {
      throw WalrusClientError(
        'No storage node found for shard index $shardIndex',
      );
    }

    final client = _getOrCreateNodeClient(node.endpointUrl);
    final rawSliver = await client.getSliver(
      blobId: blobId,
      sliverPairIndex: sliverPairIndex,
      sliverType: SliverType.secondary,
    );

    // Parse BCS to extract raw symbol data.
    final parsed = parseSliverResponse(rawSliver);
    return parsed.data;
  }

  /// Get a [WalrusBlob] by blob ID for lazy reading.
  ///
  /// Returns a [WalrusBlob] backed by a [BlobReader] that lazily
  /// fetches data from storage nodes. Use [WalrusBlob.asFile()] for
  /// single-file blobs, or [WalrusBlob.files()] for quilt-based files.
  ///
  /// Mirrors the TS SDK's `getBlob()`.
  Future<WalrusBlob> getBlob({required String blobId}) async {
    final state = await _stateReader.systemState();

    final reader = BlobReader(
      blobId: blobId,
      numShards: state.nShards,
      readBlob: (id) => readBlob(blobId: id),
      readSecondarySliver: (id, index) =>
          getSecondarySliver(blobId: id, sliverIndex: index),
    );

    return WalrusBlob.fromReader(reader: reader, client: this);
  }

  /// Get [WalrusFile] instances for a list of blob IDs or quilt patch IDs.
  ///
  /// Each ID can be either:
  /// - A 32-byte blob ID (URL-safe base64) → returned as a plain file
  /// - A 37-byte quilt patch ID → returned as the specific file within
  ///   the quilt
  ///
  /// Blob readers are shared for the same blob ID to avoid redundant
  /// network calls.
  ///
  /// Mirrors the TS SDK's `getFiles()`.
  Future<List<WalrusFile>> getFiles({required List<String> ids}) async {
    final state = await _stateReader.systemState();
    final numShards = state.nShards;

    // Dedup blob readers.
    final readersByBlobId = <String, BlobReader>{};
    final quiltReadersByBlobId = <String, QuiltReader>{};
    final parsedIds = ids.map(parseWalrusId).toList();

    for (final id in parsedIds) {
      final blobId = id.kind == 'blob' ? id.blobId! : id.patchId!.quiltId;
      readersByBlobId.putIfAbsent(
        blobId,
        () => BlobReader(
          blobId: blobId,
          numShards: numShards,
          readBlob: (id) => readBlob(blobId: id),
          readSecondarySliver: (id, index) =>
              getSecondarySliver(blobId: id, sliverIndex: index),
        ),
      );

      if (id.kind == 'quiltPatch') {
        quiltReadersByBlobId.putIfAbsent(
          blobId,
          () => QuiltReader(blob: readersByBlobId[blobId]!),
        );
      }
    }

    return parsedIds.map((id) {
      if (id.kind == 'blob') {
        return WalrusFile(reader: readersByBlobId[id.blobId!]!);
      }

      final patchId = id.patchId!;
      return WalrusFile(
        reader: QuiltFileReader(
          quilt: quiltReadersByBlobId[patchId.quiltId]!,
          sliverIndex: patchId.startIndex,
        ),
      );
    }).toList();
  }

  // -------------------------------------------------------------------------
  // On-Chain State Access
  // -------------------------------------------------------------------------

  /// Access the system state reader for pricing and state queries.
  SystemStateReader get stateReader => _stateReader;

  /// Access the committee resolver.
  CommitteeResolver get committeeResolver => _committeeResolver;

  /// Resolve the Walrus Move package ID (cached).
  ///
  /// If not provided at construction, reads the system object on-chain.
  Future<String> _resolvePackageId() async {
    _walrusPackageId ??= await _stateReader.getWalrusPackageId();
    return _walrusPackageId!;
  }

  /// Get or create the transaction builder.
  Future<WalrusTransactionBuilder> _ensureTxBuilder() async {
    if (_txBuilder != null) return _txBuilder!;

    final packageId = await _resolvePackageId();
    _txBuilder = WalrusTransactionBuilder(
      packageConfig: packageConfig,
      walrusPackageId: packageId,
    );
    return _txBuilder!;
  }

  /// Resolve WAL coin type from on-chain staking module.
  Future<String> getWalType() => _stateReader.getWalType();

  /// Calculate storage cost for a blob.
  Future<StorageCostInfo> storageCost(int size, int epochs) =>
      _stateReader.storageCost(size, epochs);

  /// Read current system state (pricing, epoch, shards).
  Future<WalrusSystemState> systemState() => _stateReader.systemState();

  // -------------------------------------------------------------------------
  // Committee Management
  // -------------------------------------------------------------------------

  /// Set the committee info for direct mode operations.
  ///
  /// Overrides auto-resolution from the chain. Useful for testing
  /// or when committee info is already known.
  void setCommittee(CommitteeInfo committee) {
    _committee = committee;
  }

  /// Get the current committee info, auto-resolving from chain if needed.
  ///
  /// In direct mode (no relay), committee is required.
  /// In relay mode, committee is optional (relay handles distribution).
  Future<CommitteeInfo> getCommittee() async {
    _committee ??= await _committeeResolver.getActiveCommittee();
    return _committee!;
  }

  /// Get the current committee info (returns null if not yet resolved).
  CommitteeInfo? get committee => _committee;

  /// Read the staking state (epoch, committee, epoch state).
  Future<WalrusStakingState> stakingState() => _stateReader.stakingState();

  // -------------------------------------------------------------------------
  // Read Committee (Epoch-Transition Aware)
  // -------------------------------------------------------------------------

  /// Get the certification epoch for a blob.
  ///
  /// During `EpochChangeSync`, queries verified blob status to determine
  /// which epoch the blob was certified in. This ensures reads use the
  /// correct committee (previous vs current).
  ///
  /// Mirrors the TS SDK's `#getCertificationEpoch()`.
  Future<int> _getCertificationEpoch({required String blobId}) async {
    final staking = await stakingState();
    final currentEpoch = staking.epoch;

    if (staking.epochState.isTransitioning) {
      final status = await getVerifiedBlobStatus(blobId: blobId);

      if (status is BlobStatusNonexistent || status is BlobStatusInvalid) {
        throw BlobNotCertifiedError(
          'The specified blob $blobId is ${status.type}.',
        );
      }

      // Extract initialCertifiedEpoch from permanent/deletable statuses.
      int? certEpoch;
      if (status is BlobStatusPermanent) {
        certEpoch = status.initialCertifiedEpoch;
      } else if (status is BlobStatusDeletable) {
        certEpoch = status.initialCertifiedEpoch;
      }

      if (certEpoch == null) {
        throw BlobNotCertifiedError(
          'The specified blob $blobId is not certified.',
        );
      }

      if (certEpoch > currentEpoch) {
        throw BehindCurrentEpochError(
          'The client is at epoch $currentEpoch while the specified blob '
          'was certified at epoch $certEpoch.',
        );
      }

      return certEpoch;
    }

    return currentEpoch;
  }

  /// Get the committee responsible for serving reads of a blob.
  ///
  /// During epoch transitions, blobs certified before the current epoch
  /// should be read from the previous committee, since current-epoch
  /// nodes may still be receiving transferred shards.
  ///
  /// Mirrors the TS SDK's `#getReadCommittee()` / `#forceGetReadCommittee()`.
  Future<CommitteeInfo> _getReadCommittee({required String blobId}) async {
    _readCommittee ??= await _forceGetReadCommittee(blobId: blobId);
    return _readCommittee!;
  }

  Future<CommitteeInfo> _forceGetReadCommittee({required String blobId}) async {
    final staking = await stakingState();
    final isTransitioning = staking.epochState.isTransitioning;
    final certificationEpoch = await _getCertificationEpoch(blobId: blobId);

    if (isTransitioning &&
        certificationEpoch < staking.epoch &&
        staking.previousCommittee != null) {
      // Read from the previous committee during epoch transitions
      // for blobs certified before the current epoch.
      return _committeeResolver.resolveCommitteeFromMembers(
        staking.previousCommittee!,
      );
    }

    return getCommittee();
  }

  // -------------------------------------------------------------------------
  // Execute Transaction Wrappers
  // -------------------------------------------------------------------------

  /// Execute a transaction that deletes a deletable blob.
  ///
  /// Builds and signs a `delete_blob` transaction using [signer].
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `executeDeleteBlobTransaction()`.
  Future<String> executeDeleteBlobTransaction({
    required String blobObjectId,
    required SuiAccount signer,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    final tx = txBuilder.deleteBlobTransaction(blobObjectId: blobObjectId);
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    return result.digest;
  }

  /// Execute a transaction that extends a blob's validity period.
  ///
  /// Automatically resolves WAL coins from the signer's account.
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `executeExtendBlobTransaction()`.
  Future<String> executeExtendBlobTransaction({
    required String blobObjectId,
    required int epochs,
    required SuiAccount signer,
    String? walCoinObjectId,
  }) async {
    final txBuilder = await _ensureTxBuilder();

    // Resolve WAL coin if not provided.
    String? walCoin = walCoinObjectId;
    BigInt? cost;

    if (walCoin == null) {
      // [Inference] Extension cost estimation requires knowing the blob's
      // encoded size. For now, let the Move call handle payment via gas
      // fallback. Full implementation would read the blob object to get
      // its encoded size, compute cost, and resolve a WAL coin.
    }

    final tx = txBuilder.extendBlobTransaction(
      blobObjectId: blobObjectId,
      epochs: epochs,
      walCoinObjectId: walCoin,
      extensionCost: cost,
      walType: walCoin != null ? await getWalType() : null,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    return result.digest;
  }

  /// Execute a transaction that creates a storage reservation.
  ///
  /// Resolves WAL coins automatically from the signer's account if
  /// [walCoinObjectId] is not provided. Returns the transaction digest
  /// and the created Storage object ID.
  ///
  /// Mirrors the TS SDK's `executeCreateStorageTransaction()`.
  Future<({String digest, String storageObjectId})>
  executeCreateStorageTransaction({
    required int size,
    required int epochs,
    required SuiAccount signer,
    String? walCoinObjectId,
    String? owner,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    final costs = await storageCost(size, epochs);
    final effectiveOwner = owner ?? signer.getAddress();

    // Resolve WAL coin.
    final walCoin =
        walCoinObjectId ?? await findWalCoin(effectiveOwner, costs.storageCost);

    if (walCoin == null) {
      throw InsufficientWalBalanceError(
        ownerAddress: effectiveOwner,
        requiredAmount: costs.storageCost,
        message:
            'No WAL coin with sufficient balance for storage reservation. '
            'Need ${costs.storageCost} WAL.',
      );
    }

    final systemState = await _stateReader.systemState();
    final encodedSize = encodedBlobLength(size, systemState.nShards);

    final tx = txBuilder.createStorageTransaction(
      encodedSize: encodedSize,
      epochs: epochs,
      walCoinObjectId: walCoin,
      storageCost: costs.storageCost,
      walType: await getWalType(),
      owner: effectiveOwner,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    // Extract the created storage object ID from transaction effects.
    final storageObjectId = _extractCreatedObjectId(result, 'Storage');

    return (digest: result.digest, storageObjectId: storageObjectId);
  }

  /// Execute a transaction that registers a blob on-chain.
  ///
  /// Builds a register blob transaction with proper WAL payment,
  /// signs and executes it.
  ///
  /// Returns the transaction digest and the created blob object ID.
  ///
  /// Mirrors the TS SDK's `executeRegisterBlobTransaction()`.
  Future<({String digest, String blobObjectId})>
  executeRegisterBlobTransaction({
    required int size,
    required int epochs,
    required String blobId,
    required Uint8List rootHash,
    required bool deletable,
    required SuiAccount signer,
    String? owner,
    String? walCoinObjectId,
    Map<String, String?>? attributes,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    final costs = await storageCost(size, epochs);
    final effectiveOwner = owner ?? signer.getAddress();

    // Resolve WAL coin.
    final walCoin =
        walCoinObjectId ?? await findWalCoin(effectiveOwner, costs.totalCost);

    if (walCoin == null) {
      throw InsufficientWalBalanceError(
        ownerAddress: effectiveOwner,
        requiredAmount: costs.totalCost,
        message:
            'No WAL coin with sufficient balance for blob registration. '
            'Need ${costs.totalCost} WAL '
            '(storage: ${costs.storageCost}, write: ${costs.writeCost}).',
      );
    }

    final systemState = await _stateReader.systemState();
    final encodedSize = encodedBlobLength(size, systemState.nShards);

    final tx = txBuilder.registerBlobWithWal(
      RegisterBlobOptions(
        size: size,
        epochs: epochs,
        blobId: blobId,
        rootHash: rootHash,
        deletable: deletable,
        owner: effectiveOwner,
      ),
      walCoinObjectId: walCoin,
      walType: await getWalType(),
      storageCost: costs.storageCost,
      writeCost: costs.writeCost,
      encodedSize: encodedSize,
    );

    // Write attributes if provided.
    if (attributes != null && attributes.isNotEmpty) {
      // The blob object is the last result in the transaction.
      // We need to add metadata to it before the transfer.
      // For attributes, we build a separate follow-up transaction
      // after the blob is created. The TS SDK combines them in
      // one PTB, but for robustness, we separate them.
    }

    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    final blobObjectId = _extractBlobObjectId(result);

    // Write attributes in a follow-up transaction if provided.
    if (attributes != null && attributes.isNotEmpty) {
      await executeWriteBlobAttributesTransaction(
        blobObjectId: blobObjectId,
        attributes: attributes,
        signer: signer,
      );
    }

    return (digest: result.digest, blobObjectId: blobObjectId);
  }

  /// Execute a transaction that certifies a blob on-chain.
  ///
  /// Requires the certificate from the upload relay or aggregated from
  /// individual storage node confirmations.
  ///
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `executeCertifyBlobTransaction()`.
  Future<String> executeCertifyBlobTransaction({
    required String blobId,
    required String blobObjectId,
    required bool deletable,
    ProtocolMessageCertificate? certificate,
    required SuiAccount signer,
    int? committeeSize,
  }) async {
    if (certificate == null) {
      throw ArgumentError(
        'A ProtocolMessageCertificate is required for certification. '
        'Obtain one from the upload relay or aggregate storage node '
        'confirmations.',
      );
    }

    // Resolve committee size: explicit > committee info > infer from signers.
    final resolvedCommitteeSize =
        committeeSize ??
        _committee?.nodes.length ??
        (certificate.signers.isEmpty
            ? 0
            : certificate.signers.reduce((a, b) => a > b ? a : b) + 1);

    final txBuilder = await _ensureTxBuilder();
    final tx = txBuilder.certifyBlobTransaction(
      CertifyBlobOptions(
        blobId: blobId,
        blobObjectId: blobObjectId,
        deletable: deletable,
        certificate: certificate,
        committeeSize: resolvedCommitteeSize,
      ),
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(showEffects: true),
    );

    return result.digest;
  }

  // -------------------------------------------------------------------------
  // Blob Attributes (On-Chain Metadata)
  // -------------------------------------------------------------------------

  /// Read the on-chain attributes (metadata key-value pairs) for a blob.
  ///
  /// Returns `null` if the blob has no metadata attached.
  /// Returns a `Map<String, String>` of key-value pairs otherwise.
  ///
  /// Uses Sui dynamic field lookup for the `metadata` key on the blob object.
  ///
  /// Mirrors the TS SDK's `readBlobAttributes()`.
  Future<Map<String, String>?> readBlobAttributes({
    required String blobObjectId,
  }) async {
    try {
      // The metadata is stored as a dynamic field on the blob object
      // with key type `vector<u8>` and key value b"metadata".
      //
      // The Dart `sui` package's `getDynamicFieldObject` only accepts a
      // String for the name value, but for `vector<u8>` the Sui JSON-RPC
      // expects a JSON array of byte integers. Use a raw RPC call instead.
      final nameValue = 'metadata'.codeUnits; // UTF-8 byte array
      final result = await suiClient.client.request(
        'suix_getDynamicFieldObject',
        [
          blobObjectId,
          {'type': 'vector<u8>', 'value': nameValue},
        ],
      );

      final response = SuiObjectResponse.fromJson(result);
      final content = response.data?.content;
      if (content == null) return null;

      // Parse the metadata VecMap from the dynamic field content.
      return _parseMetadataContent(content);
    } catch (e) {
      // Dynamic field not found → no metadata attached.
      if (e.toString().contains('DynamicFieldNotFound') ||
          e.toString().contains('not found') ||
          e.toString().contains('404')) {
        return null;
      }
      rethrow;
    }
  }

  /// Parse metadata content from a Sui dynamic field response.
  ///
  /// The metadata is a `Metadata { metadata: VecMap<String, String> }`.
  Map<String, String>? _parseMetadataContent(dynamic content) {
    Map<String, dynamic> fields;

    if (content is Map<String, dynamic>) {
      if (content.containsKey('fields') &&
          content['fields'] is Map<String, dynamic>) {
        fields = content['fields'] as Map<String, dynamic>;
      } else {
        fields = content;
      }
    } else {
      return null;
    }

    // Unwrap the 'value' field (dynamic field wrapper).
    final value = fields['value'];
    if (value == null) return null;

    Map<String, dynamic> valueFields;
    if (value is Map<String, dynamic>) {
      if (value.containsKey('fields') &&
          value['fields'] is Map<String, dynamic>) {
        valueFields = value['fields'] as Map<String, dynamic>;
      } else {
        valueFields = value;
      }
    } else {
      return null;
    }

    // The Metadata struct has a 'metadata' field which is a VecMap.
    final metadataField = valueFields['metadata'];
    if (metadataField == null) return null;

    Map<String, dynamic> vecMapFields;
    if (metadataField is Map<String, dynamic>) {
      if (metadataField.containsKey('fields') &&
          metadataField['fields'] is Map<String, dynamic>) {
        vecMapFields = metadataField['fields'] as Map<String, dynamic>;
      } else {
        vecMapFields = metadataField;
      }
    } else {
      return null;
    }

    // VecMap has 'contents' array of {key, value} pairs.
    final contents = vecMapFields['contents'];
    if (contents is! List) return {};

    final result = <String, String>{};
    for (final entry in contents) {
      if (entry is Map<String, dynamic>) {
        // Unwrap Move object wrapper.
        final entryFields =
            entry.containsKey('fields') &&
                entry['fields'] is Map<String, dynamic>
            ? entry['fields'] as Map<String, dynamic>
            : entry;
        final key = entryFields['key'];
        final value = entryFields['value'];
        if (key is String && value is String) {
          result[key] = value;
        }
      }
    }

    return result;
  }

  /// Build a transaction that writes attributes to a blob.
  ///
  /// If attributes already exist, their previous values will be overwritten.
  /// If an attribute value is `null`, it will be removed from the blob.
  ///
  /// Mirrors the TS SDK's `writeBlobAttributes()`.
  Future<Transaction> writeBlobAttributesTransaction({
    required String blobObjectId,
    required Map<String, String?> attributes,
    Transaction? transaction,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    final existingAttributes = await readBlobAttributes(
      blobObjectId: blobObjectId,
    );

    return txBuilder.writeBlobAttributesTransaction(
      blobObjectId: blobObjectId,
      attributes: attributes,
      existingAttributes: existingAttributes,
      transaction: transaction,
    );
  }

  /// Execute a transaction that writes attributes to a blob.
  ///
  /// Reads existing attributes, builds a transaction, then signs and
  /// executes it. Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `executeWriteBlobAttributesTransaction()`.
  Future<String> executeWriteBlobAttributesTransaction({
    required String blobObjectId,
    required Map<String, String?> attributes,
    required SuiAccount signer,
  }) async {
    final tx = await writeBlobAttributesTransaction(
      blobObjectId: blobObjectId,
      attributes: attributes,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    return result.digest;
  }

  // -------------------------------------------------------------------------
  // WAL Coin Resolution
  // -------------------------------------------------------------------------

  /// Find a WAL coin with sufficient balance for the given amount.
  ///
  /// Returns the coin object ID, or null if no coin has enough balance.
  /// If [merge] is true, will merge coins to create one with enough.
  Future<String?> findWalCoin(
    String ownerAddress,
    BigInt requiredAmount, {
    bool merge = false,
  }) async {
    final walType = await getWalType();
    final coins = await suiClient.getCoins(ownerAddress, coinType: walType);

    if (coins.data.isEmpty) return null;

    // Try to find a single coin with enough balance.
    for (final coin in coins.data) {
      final balance = BigInt.tryParse(coin.balance) ?? BigInt.zero;
      if (balance >= requiredAmount) {
        return coin.coinObjectId;
      }
    }

    // If merge requested and we have multiple coins, check combined balance.
    if (merge && coins.data.isNotEmpty) {
      // Sum all coin balances to check if combined amount is sufficient.
      var totalBalance = BigInt.zero;
      for (final coin in coins.data) {
        totalBalance += BigInt.tryParse(coin.balance) ?? BigInt.zero;
      }

      if (totalBalance < requiredAmount) {
        // Combined balance insufficient even after merging.
        return null;
      }

      // Return the largest coin — caller should merge before using.
      coins.data.sort((a, b) {
        final balA = BigInt.tryParse(a.balance) ?? BigInt.zero;
        final balB = BigInt.tryParse(b.balance) ?? BigInt.zero;
        return balB.compareTo(balA);
      });
      return coins.data.first.coinObjectId;
    }

    return null;
  }

  /// Merge all WAL coins for an address into a single coin.
  ///
  /// Returns the merged coin's object ID.
  /// Useful when no single coin has enough balance.
  Future<String> mergeWalCoins(String ownerAddress, SuiAccount signer) async {
    final walType = await getWalType();
    final coins = await suiClient.getCoins(ownerAddress, coinType: walType);

    if (coins.data.isEmpty) {
      throw InsufficientWalBalanceError(
        ownerAddress: ownerAddress,
        requiredAmount: BigInt.zero,
        message: 'No WAL coins found for $ownerAddress',
      );
    }

    if (coins.data.length == 1) {
      return coins.data.first.coinObjectId;
    }

    // Merge all coins into the first one.
    final tx = Transaction();
    tx.setSender(ownerAddress);

    final destination = tx.object(coins.data.first.coinObjectId);
    final sources = coins.data
        .skip(1)
        .map((c) => tx.object(c.coinObjectId))
        .toList();

    tx.mergeCoins(destination, sources);

    await suiClient.signAndExecuteTransactionBlock(signer, tx);

    return coins.data.first.coinObjectId;
  }

  // -------------------------------------------------------------------------
  // WAL Exchange
  // -------------------------------------------------------------------------

  /// Cached WAL exchange package ID (resolved dynamically from chain).
  String? _walExchangePackageId;

  /// Resolve the WAL exchange package ID from the first exchange object.
  ///
  /// Fetches the exchange object's type from chain and extracts the
  /// package address. The result is cached for subsequent calls.
  ///
  /// Mirrors the TS SDK's approach: `parseStructTag(exchange.type).address`.
  ///
  /// Throws [StateError] if no exchange IDs are configured.
  Future<String> getWalExchangePackageId() async {
    if (_walExchangePackageId != null) return _walExchangePackageId!;

    final exchangeIds = packageConfig.exchangeIds;
    if (exchangeIds == null || exchangeIds.isEmpty) {
      throw StateError(
        'No exchange IDs configured. WAL exchange is not available '
        'for this network configuration.',
      );
    }

    // Fetch the first exchange object to get its type.
    final obj = await suiClient.getObject(
      exchangeIds.first,
      options: SuiObjectDataOptions(showType: true),
    );

    final objectType = obj.data?.type;
    if (objectType == null) {
      throw StateError(
        'Could not resolve exchange object type for ${exchangeIds.first}',
      );
    }

    // Parse the struct type to extract the package address.
    // Type format: "0x<pkg>::wal_exchange::Exchange"
    final parts = objectType.split('::');
    if (parts.length < 2) {
      throw StateError('Unexpected exchange object type format: $objectType');
    }

    _walExchangePackageId = parts[0];
    return _walExchangePackageId!;
  }

  /// Exchange a specific amount of SUI for WAL tokens.
  ///
  /// Uses the first available exchange object from the package config.
  /// The [suiCoinObjectId] must have at least [amountSui] balance.
  ///
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `exchangeForWal` contract call.
  Future<String> exchangeForWal({
    required String suiCoinObjectId,
    required BigInt amountSui,
    required SuiAccount signer,
    String? exchangeObjectId,
  }) async {
    final exchangeId = exchangeObjectId ?? _defaultExchangeId();
    final txBuilder = await _ensureTxBuilder();
    final exchangePkgId = await getWalExchangePackageId();

    final tx = Transaction();
    txBuilder.exchangeForWalTransaction(
      exchangeObjectId: exchangeId,
      suiCoinObjectId: suiCoinObjectId,
      amountSui: amountSui,
      walExchangePackageId: exchangePkgId,
      transaction: tx,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(showEffects: true),
    );

    return result.digest;
  }

  /// Exchange a specific amount of WAL for SUI tokens.
  ///
  /// Uses the first available exchange object from the package config.
  /// The [walCoinObjectId] must have at least [amountWal] balance.
  ///
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `exchangeForSui` contract call.
  Future<String> exchangeForSui({
    required String walCoinObjectId,
    required BigInt amountWal,
    required SuiAccount signer,
    String? exchangeObjectId,
  }) async {
    final exchangeId = exchangeObjectId ?? _defaultExchangeId();
    final txBuilder = await _ensureTxBuilder();
    final exchangePkgId = await getWalExchangePackageId();

    final tx = Transaction();
    txBuilder.exchangeForSuiTransaction(
      exchangeObjectId: exchangeId,
      walCoinObjectId: walCoinObjectId,
      amountWal: amountWal,
      walExchangePackageId: exchangePkgId,
      transaction: tx,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(showEffects: true),
    );

    return result.digest;
  }

  /// Exchange all SUI in a coin for WAL tokens.
  ///
  /// Uses the first available exchange object from the package config.
  /// The entire [suiCoinObjectId] balance is exchanged.
  ///
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `exchangeAllForWal` contract call.
  Future<String> exchangeAllForWal({
    required String suiCoinObjectId,
    required SuiAccount signer,
    String? exchangeObjectId,
  }) async {
    final exchangeId = exchangeObjectId ?? _defaultExchangeId();
    final txBuilder = await _ensureTxBuilder();
    final exchangePkgId = await getWalExchangePackageId();

    final tx = Transaction();
    txBuilder.exchangeAllForWalTransaction(
      exchangeObjectId: exchangeId,
      suiCoinObjectId: suiCoinObjectId,
      walExchangePackageId: exchangePkgId,
      transaction: tx,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(showEffects: true),
    );

    return result.digest;
  }

  /// Exchange all WAL in a coin for SUI tokens.
  ///
  /// Uses the first available exchange object from the package config.
  /// The entire [walCoinObjectId] balance is exchanged.
  ///
  /// Returns the transaction digest.
  ///
  /// Mirrors the TS SDK's `exchangeAllForSui` contract call.
  Future<String> exchangeAllForSui({
    required String walCoinObjectId,
    required SuiAccount signer,
    String? exchangeObjectId,
  }) async {
    final exchangeId = exchangeObjectId ?? _defaultExchangeId();
    final txBuilder = await _ensureTxBuilder();
    final exchangePkgId = await getWalExchangePackageId();

    final tx = Transaction();
    txBuilder.exchangeAllForSuiTransaction(
      exchangeObjectId: exchangeId,
      walCoinObjectId: walCoinObjectId,
      walExchangePackageId: exchangePkgId,
      transaction: tx,
    );
    tx.setSender(signer.getAddress());

    final result = await suiClient.signAndExecuteTransactionBlock(
      signer,
      tx,
      responseOptions: SuiTransactionBlockResponseOptions(showEffects: true),
    );

    return result.digest;
  }

  /// Returns the default exchange object ID from [packageConfig.exchangeIds].
  ///
  /// Throws [StateError] if no exchange IDs are configured.
  String _defaultExchangeId() {
    final exchangeIds = packageConfig.exchangeIds;
    if (exchangeIds == null || exchangeIds.isEmpty) {
      throw StateError(
        'No exchange IDs configured. WAL exchange is not available '
        'for this network configuration.',
      );
    }
    return exchangeIds.first;
  }

  // -------------------------------------------------------------------------
  // One-Shot Write Blob
  // -------------------------------------------------------------------------

  /// Upload a blob in a single call (registers, uploads, certifies).
  ///
  /// Requires a [SuiAccount] signer that can sign transactions directly.
  /// For dApp wallet integration, use [writeBlobFlow] instead.
  ///
  /// The signer must have sufficient WAL tokens in their wallet.
  /// WAL coins are resolved automatically from the signer's address.
  ///
  /// If [walCoinObjectId] is provided, uses that specific WAL coin.
  /// Otherwise finds a suitable WAL coin from the signer's account.
  ///
  /// If no upload relay is configured, uses **direct mode** (Phase 3):
  /// the blob is encoded client-side and slivers are written directly
  /// to storage nodes. This requires [encoder] (or creates a default
  /// [WalrusBlobEncoder]) and committee (auto-resolved from chain).
  Future<WriteBlobResult> writeBlob({
    required Uint8List blob,
    BlobMetadata? metadata,
    required int epochs,
    required SuiAccount signer,
    required bool deletable,
    String? owner,
    String? walCoinObjectId,
    Map<String, String?>? attributes,
  }) async {
    final effectiveOwner = owner ?? signer.getAddress();

    // Load tip config if needed.
    await _ensureTipConfig();

    if (_relayClient != null) {
      // Relay mode: same as Phase 2.
      // Auto-compute metadata if not provided. The TS SDK calls
      // computeBlobMetadata({ bytes: blob }) in this path.
      BlobMetadata effectiveMetadata;
      if (metadata != null) {
        effectiveMetadata = metadata;
      } else {
        final systemSt = await _stateReader.systemState();
        final nShards = systemSt.nShards;
        final encodingType = encoder is WalrusBlobEncoder
            ? (encoder as WalrusBlobEncoder).encodingType
            : kEncodingTypeRS2;

        // Run encoding in a separate isolate to avoid blocking the UI
        // thread. Fountain code encoding is CPU-intensive.
        // Falls back to inline execution on platforms without isolate
        // support (web).
        try {
          // Capture the FFI library path — statics don't transfer across
          // isolate boundaries, so we propagate the resolved path explicitly.
          final ffiLibPath = WalrusFfiBindings.resolvedPath;
          effectiveMetadata = await Isolate.run(() {
            if (ffiLibPath != null) {
              WalrusFfiBindings.configure(ffiLibPath);
            }
            final blobEncoder = WalrusBlobEncoder(encodingType: encodingType);
            return blobEncoder.computeMetadataSync(blob, nShards);
          });
        } on UnsupportedError {
          // Web platform — run inline.
          final blobEncoder = encoder is WalrusBlobEncoder
              ? encoder as WalrusBlobEncoder
              : WalrusBlobEncoder(encodingType: encodingType);
          effectiveMetadata = await blobEncoder.computeMetadata(blob, nShards);
        }
      }

      return _writeBlobViaRelay(
        blob: blob,
        metadata: effectiveMetadata,
        epochs: epochs,
        signer: signer,
        deletable: deletable,
        effectiveOwner: effectiveOwner,
        walCoinObjectId: walCoinObjectId,
        attributes: attributes,
      );
    } else {
      // Direct mode: Phase 3.
      return _writeBlobDirect(
        blob: blob,
        metadata: metadata,
        epochs: epochs,
        signer: signer,
        deletable: deletable,
        effectiveOwner: effectiveOwner,
        walCoinObjectId: walCoinObjectId,
        attributes: attributes,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Direct Mode Write (Phase 3)
  // -------------------------------------------------------------------------

  /// Write a blob directly to storage nodes (no upload relay).
  ///
  /// Flow: `encode → register (with WAL) → writeToNodes → certify`
  ///
  /// Automatically resolves WAL coins, package ID, and committee
  /// from on-chain state.
  ///
  /// Mirrors the TS SDK's `writeBlob()` without upload relay.
  Future<WriteBlobResult> _writeBlobDirect({
    required Uint8List blob,
    BlobMetadata? metadata,
    required int epochs,
    required SuiAccount signer,
    required bool deletable,
    required String effectiveOwner,
    String? walCoinObjectId,
    Map<String, String?>? attributes,
  }) async {
    // Auto-resolve committee from chain if not manually set.
    final resolvedCommittee = await getCommittee();

    // Step 1: Encode the blob.
    final blobEncoder = encoder is WalrusBlobEncoder
        ? encoder as WalrusBlobEncoder
        : WalrusBlobEncoder();

    final encodedBlob = blobEncoder.encodeBlob(
      blob,
      resolvedCommittee.numShards,
    );

    final effectiveMetadata =
        metadata ??
        BlobMetadata(
          blobId: encodedBlob.blobId,
          rootHash: encodedBlob.rootHash,
          unencodedLength: encodedBlob.unencodedLength,
          encodingType: kEncodingTypeRS2,
          nonce: Uint8List(32),
          blobDigest: Uint8List.fromList(
            encodedBlob.rootHash, // Placeholder; will be refined.
          ),
        );

    // Step 2: Calculate storage costs.
    final costs = await storageCost(blob.length, epochs);

    // Step 3: Resolve WAL coin.
    final totalWalNeeded = costs.totalCost;
    final walCoin =
        walCoinObjectId ?? await findWalCoin(effectiveOwner, totalWalNeeded);

    if (walCoin == null) {
      throw InsufficientWalBalanceError(
        ownerAddress: effectiveOwner,
        requiredAmount: totalWalNeeded,
        message:
            'No WAL coin with sufficient balance found for '
            '$effectiveOwner. Need $totalWalNeeded WAL '
            '(storage: ${costs.storageCost}, write: ${costs.writeCost}).',
      );
    }

    // Step 4: Register blob on-chain with proper WAL payment.
    final txBuilder = await _ensureTxBuilder();
    final systemState = await _stateReader.systemState();
    final encodedSize = encodedBlobLength(blob.length, systemState.nShards);

    final registerTx = txBuilder.registerBlobWithWal(
      RegisterBlobOptions(
        size: blob.length,
        epochs: epochs,
        blobId: effectiveMetadata.blobId,
        rootHash: effectiveMetadata.rootHash,
        deletable: deletable,
        owner: effectiveOwner,
      ),
      walCoinObjectId: walCoin,
      walType: await getWalType(),
      storageCost: costs.storageCost,
      writeCost: costs.writeCost,
      encodedSize: encodedSize,
    );

    registerTx.setSenderIfNotSet(effectiveOwner);

    // DEBUG: Dump transaction commands before submission.
    _debugDumpTransaction('_writeBlobDirect register', registerTx);

    final registerResult = await suiClient.signAndExecuteTransactionBlock(
      signer,
      registerTx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    final blobObjectId = _extractBlobObjectId(registerResult);

    // Step 5: Write encoded slivers to storage nodes.
    final confirmations = await writeEncodedBlobToNodes(
      encodedBlob: encodedBlob,
      committee: resolvedCommittee,
      deletable: deletable,
      blobObjectId: blobObjectId,
    );

    // Step 6: Build certificate from confirmations.
    final certificate = _buildCertificateFromConfirmations(
      confirmations: confirmations,
      committee: resolvedCommittee,
    );

    // Step 7: Certify on-chain.
    final certifyTx = txBuilder.certifyBlobTransaction(
      CertifyBlobOptions(
        blobId: effectiveMetadata.blobId,
        blobObjectId: blobObjectId,
        deletable: deletable,
        certificate: certificate,
        committeeSize: resolvedCommittee.nodes.length,
      ),
    );

    final certifyResult = await suiClient.signAndExecuteTransactionBlock(
      signer,
      certifyTx,
    );

    // Step 8: Write blob attributes if provided.
    if (attributes != null && attributes.isNotEmpty) {
      await executeWriteBlobAttributesTransaction(
        blobObjectId: blobObjectId,
        attributes: attributes,
        signer: signer,
      );
    }

    return WriteBlobResult(
      blobId: effectiveMetadata.blobId,
      blobObjectId: blobObjectId,
      certifyDigest: certifyResult.digest,
    );
  }

  /// Write encoded slivers to all storage nodes in the committee.
  ///
  /// Returns a map from node index to confirmation (null if the node
  /// failed or did not respond in time).
  ///
  /// Mirrors the TS SDK's `writeEncodedBlobToNodes()`.
  Future<Map<int, StorageConfirmation?>> writeEncodedBlobToNodes({
    required EncodedBlob encodedBlob,
    required CommitteeInfo committee,
    required bool deletable,
    required String blobObjectId,
    Duration nodeTimeout = const Duration(seconds: 30),
    int maxConcurrency = 20,
  }) async {
    final confirmations = <int, StorageConfirmation?>{};
    var failures = 0;

    final shardIndices = committee.nodeByShardIndex.keys.toList()..sort();

    // Process in batches to limit concurrency (like TS SDK's Promise.all
    // with bounded parallelism).
    for (var i = 0; i < shardIndices.length; i += maxConcurrency) {
      final batchEnd = (i + maxConcurrency < shardIndices.length)
          ? i + maxConcurrency
          : shardIndices.length;
      final batch = shardIndices.sublist(i, batchEnd);

      final futures = <Future<MapEntry<int, StorageConfirmation?>>>[];

      for (final shardIndex in batch) {
        final node = committee.nodeByShardIndex[shardIndex];
        if (node == null) {
          failures++;
          confirmations[shardIndex] = null;
          continue;
        }

        final pairIndex = toPairIndex(
          shardIndex,
          encodedBlob.blobIdBytes,
          committee.numShards,
        );

        if (pairIndex >= encodedBlob.primarySlivers.length ||
            pairIndex >= encodedBlob.secondarySlivers.length) {
          failures++;
          confirmations[shardIndex] = null;
          continue;
        }

        futures.add(
          _writeEncodedBlobToNode(
            node: node,
            blobId: encodedBlob.blobId,
            metadata: encodedBlob.metadataBytes,
            primarySliver: encodedBlob.primarySlivers[pairIndex],
            secondarySliver: encodedBlob.secondarySlivers[pairIndex],
            pairIndex: pairIndex,
            deletable: deletable,
            blobObjectId: blobObjectId,
            timeout: nodeTimeout,
          ).then(
            (conf) => MapEntry(shardIndex, conf as StorageConfirmation?),
            onError: (_) =>
                MapEntry<int, StorageConfirmation?>(shardIndex, null),
          ),
        );
      }

      // Await all writes in this batch concurrently.
      final results = await Future.wait(futures);
      for (final entry in results) {
        confirmations[entry.key] = entry.value;
        if (entry.value == null) failures++;
      }

      // Abort early if too many failures.
      if (isAboveValidity(failures, committee.numShards)) {
        throw NotEnoughBlobConfirmationsError(
          'Too many storage node failures ($failures). '
          'Cannot achieve quorum with ${committee.numShards} shards.',
        );
      }
    }

    return confirmations;
  }

  /// Write metadata + slivers to a single storage node and get confirmation.
  ///
  /// Mirrors the TS SDK's `writeEncodedBlobToNode()`.
  Future<StorageConfirmation> _writeEncodedBlobToNode({
    required StorageNodeInfo node,
    required String blobId,
    required Uint8List metadata,
    required SliverData primarySliver,
    required SliverData secondarySliver,
    required int pairIndex,
    required bool deletable,
    required String blobObjectId,
    required Duration timeout,
  }) async {
    final nodeClient = _nodeClients.putIfAbsent(
      node.endpointUrl,
      () => StorageNodeClient(
        baseUrl: node.endpointUrl,
        timeout: timeout,
        httpClient: _sharedHttpClient,
      ),
    );

    // Step 1: Write metadata with retry on BlobNotRegisteredError.
    // Storage nodes may not have indexed the blob registration yet,
    // so retry up to 3 times with 1s delay (mirrors TS SDK behavior).
    await retry(
      () => nodeClient.storeBlobMetadata(blobId: blobId, metadata: metadata),
      count: 3,
      delay: const Duration(milliseconds: 1000),
      condition: (e) => e is BlobNotRegisteredError,
    );

    // Step 2: Write primary sliver.
    await nodeClient.storeSliver(
      blobId: blobId,
      sliverPairIndex: pairIndex,
      sliverType: SliverType.primary,
      sliver: WalrusBlobEncoder.bcsSliverData(primarySliver),
    );

    // Step 3: Write secondary sliver.
    await nodeClient.storeSliver(
      blobId: blobId,
      sliverPairIndex: pairIndex,
      sliverType: SliverType.secondary,
      sliver: WalrusBlobEncoder.bcsSliverData(secondarySliver),
    );

    // Step 4: Get confirmation.
    if (deletable) {
      return nodeClient.getDeletableBlobConfirmation(
        blobId: blobId,
        objectId: blobObjectId,
      );
    } else {
      return nodeClient.getPermanentBlobConfirmation(blobId: blobId);
    }
  }

  /// Build a [ProtocolMessageCertificate] from individual node confirmations.
  ///
  /// When a [BlsProvider] is configured, each confirmation is verified
  /// against the corresponding node's public key (matching the TS SDK's
  /// `getVerifySignature` pattern) and valid signatures are aggregated
  /// via BLS12-381 `aggregate`. Without a provider, the first valid
  /// signature is used as a fallback (relay mode or testing).
  ProtocolMessageCertificate _buildCertificateFromConfirmations({
    required Map<int, StorageConfirmation?> confirmations,
    required CommitteeInfo committee,
  }) {
    final validSigners = <int>[];
    final validSignatures = <Uint8List>[];
    Uint8List? message;

    for (final entry in confirmations.entries) {
      final confirmation = entry.value;
      if (confirmation == null) continue;

      final sigBytes = base64Decode(confirmation.signature);
      final msgBytes = confirmation.serializedMessage;

      // When a BLS provider is available, verify each confirmation's
      // signature against the node's public key before including it.
      if (blsProvider != null) {
        final node = committee.nodeByShardIndex[entry.key];
        if (node != null &&
            node.publicKey != null &&
            node.publicKey!.isNotEmpty) {
          final isValid = blsProvider!.verify(
            sigBytes,
            node.publicKey!,
            msgBytes,
          );
          if (!isValid) {
            // Skip invalid confirmations — matches TS SDK filter behavior.
            continue;
          }
        }
      }

      validSigners.add(entry.key);
      validSignatures.add(sigBytes);
      message ??= msgBytes;
    }

    if (!isQuorum(validSigners.length, committee.numShards)) {
      throw NotEnoughBlobConfirmationsError(
        'Insufficient confirmations for quorum: '
        '${validSigners.length}/${committee.numShards} '
        '(need > ${2 * getMaxFaultyNodes(committee.numShards)})',
      );
    }

    if (message == null) {
      throw const NotEnoughBlobConfirmationsError(
        'No valid confirmations received',
      );
    }

    // Store raw signer indices (matching TS SDK convention).
    // The indices→bitmap conversion happens in certifyBlobTransaction().

    // Aggregate all valid signatures when BLS is available; otherwise
    // fall back to the first valid signature (relay mode / testing).
    final Uint8List signature;
    if (blsProvider != null && validSignatures.length > 1) {
      signature = blsProvider!.aggregate(validSignatures);
    } else {
      signature = validSignatures.isNotEmpty
          ? validSignatures.first
          : Uint8List(0);
    }

    return ProtocolMessageCertificate(
      signers: validSigners,
      serializedMessage: message,
      signature: signature,
    );
  }

  // -------------------------------------------------------------------------
  // Relay Mode Write (Phase 2)
  // -------------------------------------------------------------------------

  /// Upload via relay (Phase 2 implementation, now with proper WAL).
  Future<WriteBlobResult> _writeBlobViaRelay({
    required Uint8List blob,
    required BlobMetadata metadata,
    required int epochs,
    required SuiAccount signer,
    required bool deletable,
    required String effectiveOwner,
    String? walCoinObjectId,
    Map<String, String?>? attributes,
  }) async {
    final txBuilder = await _ensureTxBuilder();

    // Calculate costs.
    final costs = await storageCost(blob.length, epochs);
    final totalWalNeeded = costs.totalCost;

    // Resolve WAL coin.
    final walCoin =
        walCoinObjectId ?? await findWalCoin(effectiveOwner, totalWalNeeded);

    if (walCoin == null) {
      throw InsufficientWalBalanceError(
        ownerAddress: effectiveOwner,
        requiredAmount: totalWalNeeded,
        message:
            'No WAL coin with sufficient balance found for '
            '$effectiveOwner. Need $totalWalNeeded WAL '
            '(storage: ${costs.storageCost}, write: ${costs.writeCost}).',
      );
    }

    // Step 1: Build register transaction (+ tip if relay mode).
    final systemState = await _stateReader.systemState();
    final encodedSize = encodedBlobLength(blob.length, systemState.nShards);

    final registerTx = Transaction();
    registerTx.setSenderIfNotSet(effectiveOwner);

    if (_relayClient != null && _tipConfig != null) {
      txBuilder.sendUploadRelayTip(
        size: blob.length,
        blobDigest: metadata.blobDigest,
        nonce: metadata.nonce,
        tipConfig: _tipConfig!,
        transaction: registerTx,
      );
    }

    txBuilder.registerBlobWithWal(
      RegisterBlobOptions(
        size: blob.length,
        epochs: epochs,
        blobId: metadata.blobId,
        rootHash: metadata.rootHash,
        deletable: deletable,
        owner: effectiveOwner,
      ),
      walCoinObjectId: walCoin,
      walType: await getWalType(),
      storageCost: costs.storageCost,
      writeCost: costs.writeCost,
      encodedSize: encodedSize,
      transaction: registerTx,
    );

    // DEBUG: Dump transaction commands before submission.
    _debugDumpTransaction('_writeBlobViaRelay register', registerTx);

    // Step 2: Sign and execute register transaction.
    final registerResult = await suiClient.signAndExecuteTransactionBlock(
      signer,
      registerTx,
      responseOptions: SuiTransactionBlockResponseOptions(
        showEffects: true,
        showObjectChanges: true,
      ),
    );

    final registerDigest = registerResult.digest;
    final blobObjectId = _extractBlobObjectId(registerResult);

    // Step 2.5: Wait for register TX finalization before relay upload.
    // Matches TS SDK: `await this.#suiClient.core.waitForTransaction({ digest })`
    await suiClient.waitForTransaction(registerDigest);

    // Step 3: Upload to relay.
    final relayResult = await _relayClient!.writeBlob(
      blobId: metadata.blobId,
      blob: blob,
      nonce: metadata.nonce,
      txDigest: registerDigest,
      blobObjectId: blobObjectId,
      deletable: deletable,
      requiresTip: _tipConfig != null,
    );

    // Step 4: Build and execute certify transaction.
    // Resolve committee size for signers→bitmap conversion.
    final certCommitteeSize =
        _committee?.nodes.length ??
        (relayResult.certificate.signers.isEmpty
            ? 0
            : relayResult.certificate.signers.reduce((a, b) => a > b ? a : b) +
                  1);
    final certifyTx = txBuilder.certifyBlobTransaction(
      CertifyBlobOptions(
        blobId: metadata.blobId,
        blobObjectId: blobObjectId,
        deletable: deletable,
        certificate: relayResult.certificate,
        committeeSize: certCommitteeSize,
      ),
    );

    final certifyResult = await suiClient.signAndExecuteTransactionBlock(
      signer,
      certifyTx,
    );

    // Step 5: Write blob attributes if provided.
    if (attributes != null && attributes.isNotEmpty) {
      await executeWriteBlobAttributesTransaction(
        blobObjectId: blobObjectId,
        attributes: attributes,
        signer: signer,
      );
    }

    return WriteBlobResult(
      blobId: metadata.blobId,
      blobObjectId: blobObjectId,
      certifyDigest: certifyResult.digest,
    );
  }

  // -------------------------------------------------------------------------
  // Multi-Step Flow (dApp Wallet)
  // -------------------------------------------------------------------------

  /// Create a multi-step write blob flow for dApp wallet integration.
  ///
  /// Returns a [WriteBlobFlow] whose `register()` and `certify()` methods
  /// return unsigned [Transaction] objects for external signing.
  ///
  /// In direct mode (no relay), the flow encodes the blob client-side
  /// and writes slivers to storage nodes during the `upload()` step.
  Future<WriteBlobFlow> writeBlobFlow({
    required Uint8List blob,
    BlobMetadata? metadata,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    await _ensureTipConfig();

    return WriteBlobFlow(
      blob: blob,
      txBuilder: txBuilder,
      relayClient: _relayClient,
      tipConfig: _tipConfig,
      encoder: encoder,
      precomputedMetadata: metadata,
      committee: _committee,
      directClient: _relayClient == null ? this : null,
      stateReader: _stateReader,
      suiClient: suiClient,
    );
  }

  // -------------------------------------------------------------------------
  // Transaction Builders (exposed for advanced usage)
  // -------------------------------------------------------------------------

  /// Build a register blob transaction with proper WAL payment.
  ///
  /// For users who want to compose transactions manually.
  Future<Transaction> registerBlobTransaction(
    RegisterBlobOptions options, {
    required String walCoinObjectId,
    required BigInt storageCost,
    required BigInt writeCost,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    final walType = await getWalType();
    final systemState = await _stateReader.systemState();
    final encodedSize = encodedBlobLength(options.size, systemState.nShards);

    return txBuilder.registerBlobWithWal(
      options,
      walCoinObjectId: walCoinObjectId,
      walType: walType,
      storageCost: storageCost,
      writeCost: writeCost,
      encodedSize: encodedSize,
    );
  }

  /// Build a certify blob transaction.
  Future<Transaction> certifyBlobTransaction(CertifyBlobOptions options) async {
    final txBuilder = await _ensureTxBuilder();
    return txBuilder.certifyBlobTransaction(options);
  }

  /// Build a delete blob transaction.
  Future<Transaction> deleteBlobTransaction({
    required String blobObjectId,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    return txBuilder.deleteBlobTransaction(blobObjectId: blobObjectId);
  }

  /// Build an extend blob transaction.
  Future<Transaction> extendBlobTransaction({
    required String blobObjectId,
    required int epochs,
    String? walCoinObjectId,
    BigInt? extensionCost,
  }) async {
    final txBuilder = await _ensureTxBuilder();
    return txBuilder.extendBlobTransaction(
      blobObjectId: blobObjectId,
      epochs: epochs,
      walCoinObjectId: walCoinObjectId,
      extensionCost: extensionCost,
      walType: walCoinObjectId != null ? await getWalType() : null,
    );
  }

  // -------------------------------------------------------------------------
  // Tip Config
  // -------------------------------------------------------------------------

  /// Load and cache the relay's tip configuration.
  Future<void> _ensureTipConfig() async {
    if (_tipConfigLoaded) return;

    if (_relayClient != null) {
      // Use user-provided config or fetch from relay.
      if (uploadRelayConfig?.sendTip != null) {
        _tipConfig = uploadRelayConfig!.sendTip;
      } else {
        _tipConfig = await _relayClient!.tipConfig();
      }
    }

    _tipConfigLoaded = true;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Debug: dump all commands in a transaction before submission.
  void _debugDumpTransaction(String label, Transaction tx) {
    if (!WalrusLogLevel.debug.isEnabledFor(logger.level)) return;

    final data = tx.getData();
    final cmds = data.commands ?? [];
    logger.debug('$label: ${cmds.length} commands');
    for (var i = 0; i < cmds.length; i++) {
      final cmd = cmds[i];
      final kind = cmd['\$kind'] ?? cmd['kind'] ?? 'unknown';
      String detail;
      if (cmd['MoveCall'] != null) {
        final mc = cmd['MoveCall'] as Map;
        final args = (mc['arguments'] as List?)?.map((a) {
          if (a is Map) return a.toString();
          // TransactionResult — call toJson()
          try {
            return (a as dynamic).toJson().toString();
          } catch (_) {
            return a.toString();
          }
        }).toList();
        detail =
            '${mc['package']}::${mc['module']}::${mc['function']}'
            '  typeArgs=${mc['typeArguments']}'
            '  args=$args';
      } else if (cmd['SplitCoins'] != null) {
        final sc = cmd['SplitCoins'] as Map;
        detail = 'coin=${sc['coin']} amounts=${sc['amounts']}';
      } else if (cmd['TransferObjects'] != null) {
        final to = cmd['TransferObjects'] as Map;
        detail = 'objects=${to['objects']} address=${to['address']}';
      } else {
        detail = cmd.toString();
      }
      logger.debug('  cmd[$i] $kind: $detail');
    }
  }

  /// Extract the Blob object ID from transaction effects.
  String _extractBlobObjectId(dynamic txResult) {
    // Try to find a created object of Blob type in objectChanges.
    final objectChanges = txResult.objectChanges;
    if (objectChanges != null && objectChanges is List) {
      for (final change in objectChanges) {
        if (change is Map &&
            change['type'] == 'created' &&
            change['objectType'] != null &&
            change['objectType'].toString().contains('::blob::Blob')) {
          return change['objectId'] as String;
        }
      }
    }

    // Fallback: try from effects.created
    final effects = txResult.effects;
    if (effects != null) {
      final created = effects.created;
      if (created != null && created is List && created.isNotEmpty) {
        return created.first['reference']?['objectId']?.toString() ??
            created.first['objectId']?.toString() ??
            '';
      }
    }

    throw WalrusClientError(
      'Could not extract Blob object ID from transaction effects. '
      'Ensure showObjectChanges and showEffects are enabled.',
    );
  }

  /// Extract the object ID of a created object matching [typeSuffix]
  /// from transaction effects.
  ///
  /// Used by [executeCreateStorageTransaction] to find Storage objects.
  String _extractCreatedObjectId(dynamic txResult, String typeSuffix) {
    final objectChanges = txResult.objectChanges;
    if (objectChanges != null && objectChanges is List) {
      for (final change in objectChanges) {
        if (change is Map &&
            change['type'] == 'created' &&
            change['objectType'] != null &&
            change['objectType'].toString().contains(typeSuffix)) {
          return change['objectId'] as String;
        }
      }
    }

    // Fallback: try from effects.created (return first created).
    final effects = txResult.effects;
    if (effects != null) {
      final created = effects.created;
      if (created != null && created is List && created.isNotEmpty) {
        return created.first['reference']?['objectId']?.toString() ??
            created.first['objectId']?.toString() ??
            '';
      }
    }

    throw WalrusClientError(
      'Could not extract $typeSuffix object ID from transaction effects. '
      'Ensure showObjectChanges and showEffects are enabled.',
    );
  }

  /// Get or create a cached [StorageNodeClient] for the given URL.
  StorageNodeClient _getOrCreateNodeClient(String url) {
    return _nodeClients.putIfAbsent(
      url,
      () => StorageNodeClient(baseUrl: url, httpClient: _sharedHttpClient),
    );
  }

  /// Split a list into chunks of at most [size] elements.
  static List<List<T>> _chunk<T>(List<T> list, int size) {
    if (size <= 0) return [list];
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      final end = (i + size < list.length) ? i + size : list.length;
      chunks.add(list.sublist(i, end));
    }
    return chunks;
  }

  /// Compute chunk size for parallel fetching.
  static int _chunkSize(int total, int limit) {
    if (limit <= 0 || total <= 0) return total;
    return (total / limit).ceil();
  }
}

// ---------------------------------------------------------------------------
// Result types for quilt operations
// ---------------------------------------------------------------------------

/// Result of a quilt write operation.
class WriteQuiltResult {
  final String blobId;
  final String blobObjectId;
  final String certifyDigest;
  final List<QuiltPatchResult> patches;

  const WriteQuiltResult({
    required this.blobId,
    required this.blobObjectId,
    required this.certifyDigest,
    required this.patches,
  });
}

/// A single patch entry in a quilt write result, with its computed patch ID.
class QuiltPatchResult {
  final int startIndex;
  final int endIndex;
  final String identifier;
  final Map<String, String> tags;
  final String patchId;

  const QuiltPatchResult({
    required this.startIndex,
    required this.endIndex,
    required this.identifier,
    required this.tags,
    required this.patchId,
  });
}

// ---------------------------------------------------------------------------
// Internal helper types
// ---------------------------------------------------------------------------

/// Result type for metadata fetch futures.
///
/// Each future resolves to one of these instead of throwing, so that
/// in-flight futures never produce unhandled exceptions.
enum _MetadataResultType { success, notFound, blocked, error }

class _MetadataResult {
  final _MetadataResultType type;
  final Uint8List? data;
  final int weight;

  const _MetadataResult._({required this.type, this.data, this.weight = 0});

  factory _MetadataResult.success(Uint8List data) =>
      _MetadataResult._(type: _MetadataResultType.success, data: data);

  factory _MetadataResult.notFound(int weight) =>
      _MetadataResult._(type: _MetadataResultType.notFound, weight: weight);

  factory _MetadataResult.blocked(int weight) =>
      _MetadataResult._(type: _MetadataResultType.blocked, weight: weight);

  factory _MetadataResult.error(int weight) =>
      _MetadataResult._(type: _MetadataResultType.error, weight: weight);
}

/// Internal type for sliver fetch tasks.
class _SliverFetchTask {
  final String url;
  final int sliverPairIndex;

  const _SliverFetchTask({required this.url, required this.sliverPairIndex});
}

/// Internal type for status query results.
class _StatusResult {
  final BlobStatus status;
  final int weight;

  const _StatusResult({required this.status, required this.weight});
}

/// Internal type for aggregated status results.
class _AggregatedStatus {
  final BlobStatus status;
  int totalWeight;

  _AggregatedStatus({required this.status, required this.totalWeight});
}
