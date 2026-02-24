/// Multi-step write blob flow for wallet-integrated uploads.
///
/// Mirrors the TS SDK's `WriteBlobFlow` interface, enabling dApp
/// wallets (e.g. via Sui dApp Kit) to sign each transaction step
/// independently.
///
/// Supports both **relay mode** (Phase 2) and **direct mode** (Phase 3).
///
/// Flow:
/// 1. `encode()` → compute blob metadata (or use pre-computed)
/// 2. `register(options)` → build & return register transaction
/// 3. `upload(digest)` → upload blob to relay or storage nodes
/// 4. `certify()` → build & return certify transaction
/// 5. `getBlob()` → return final blob ID and object ID
library;

import 'dart:typed_data';

import 'package:sui/builder/transaction.dart';

import '../chain/system_state_reader.dart';
import '../contracts/transaction_builder.dart';
import '../encoding/blob_encoder.dart';
import '../encoding/walrus_blob_encoder.dart';
import '../models/protocol_types.dart';
import '../models/storage_node_types.dart';
import '../upload_relay/upload_relay_client.dart';
import '../utils/encoding_utils.dart';

/// Callback type for direct-mode sliver writing.
///
/// Avoids circular import between WriteBlobFlow and WalrusDirectClient.
typedef DirectWriteCallback =
    Future<Map<int, StorageConfirmation?>> Function({
      required EncodedBlob encodedBlob,
      required CommitteeInfo committee,
      required bool deletable,
      required String blobObjectId,
    });

/// Options for [WriteBlobFlow.register].
class WriteBlobFlowRegisterOptions {
  /// Number of storage epochs.
  final int epochs;

  /// Sui address that will own the blob object.
  final String owner;

  /// Whether the blob can be deleted.
  final bool deletable;

  /// Optional blob attributes (key-value metadata).
  final Map<String, String?>? attributes;

  /// WAL coin object ID for payment. Required for production use.
  /// If null, falls back to legacy gas-coin payment (deprecated).
  final String? walCoinObjectId;

  /// WAL coin type string (e.g., `0x...::wal::WAL`).
  /// Required when [walCoinObjectId] is provided.
  final String? walType;

  /// Pre-calculated storage cost in WAL.
  /// Required when [walCoinObjectId] is provided.
  final BigInt? storageCost;

  /// Pre-calculated write cost in WAL.
  /// Required when [walCoinObjectId] is provided.
  final BigInt? writeCost;

  /// Pre-calculated encoded blob size.
  /// Required when [walCoinObjectId] is provided.
  final int? encodedSize;

  const WriteBlobFlowRegisterOptions({
    required this.epochs,
    required this.owner,
    required this.deletable,
    this.attributes,
    this.walCoinObjectId,
    this.walType,
    this.storageCost,
    this.writeCost,
    this.encodedSize,
  });
}

/// Options for [WriteBlobFlow.upload].
class WriteBlobFlowUploadOptions {
  /// Transaction digest from the signed register transaction.
  final String digest;

  /// The full transaction result (with objectChanges / effects) so the flow
  /// can extract the Blob object ID. If [blobObjectId] is provided explicitly
  /// this may be omitted.
  final Map<String, dynamic>? txResult;

  /// Explicit Blob Sui object ID. When provided, [txResult] extraction is
  /// skipped.
  final String? blobObjectId;

  const WriteBlobFlowUploadOptions({
    required this.digest,
    this.txResult,
    this.blobObjectId,
  });
}

/// Internal state tracking for the flow steps.
enum _FlowStep { initial, encoded, registered, uploaded, certified }

/// Multi-step write blob flow for wallet integration.
///
/// This flow separates transaction building from signing, allowing
/// external wallets (dApp Kit, WalletConnect) to handle signing.
///
/// Usage:
/// ```dart
/// final flow = directClient.writeBlobFlow(blob: rawData);
///
/// // Step 1: Encode (compute metadata)
/// await flow.encode();
///
/// // Step 2: Get register transaction → sign externally
/// final registerTx = flow.register(WriteBlobFlowRegisterOptions(
///   epochs: 3,
///   owner: myAddress,
///   deletable: true,
/// ));
/// final registerResult = await wallet.signAndExecute(registerTx);
///
/// // Step 3: Upload to relay
/// await flow.upload(WriteBlobFlowUploadOptions(
///   digest: registerResult.digest,
/// ));
///
/// // Step 4: Get certify transaction → sign externally
/// final certifyTx = flow.certify();
/// await wallet.signAndExecute(certifyTx);
///
/// // Step 5: Get result
/// final result = await flow.getBlob();
/// print('Blob ID: ${result.blobId}');
/// ```
class WriteBlobFlow {
  final Uint8List _blob;
  final WalrusTransactionBuilder _txBuilder;
  final UploadRelayClient? _relayClient;
  final UploadRelayTipConfig? _tipConfig;
  final BlobEncoder? _encoder;
  final int? _numShards;

  // Pre-computed metadata (if user provides it instead of an encoder).
  final BlobMetadata? _precomputedMetadata;

  // Direct mode (Phase 3).
  final CommitteeInfo? _committee;
  final dynamic _directClient; // WalrusDirectClient (avoids circular import)

  // On-chain state reader for WAL payment resolution.
  final SystemStateReader? _stateReader;

  // Sui RPC client for auto-resolving WAL coins.
  final dynamic _suiClient; // SuiClient (avoids tight coupling)

  // State
  _FlowStep _step = _FlowStep.initial;
  BlobMetadata? _metadata;
  EncodedBlob? _encodedBlob;
  String? _blobObjectId;
  ProtocolMessageCertificate? _certificate;
  bool _deletable = false;

  WriteBlobFlow({
    required Uint8List blob,
    required WalrusTransactionBuilder txBuilder,
    UploadRelayClient? relayClient,
    UploadRelayTipConfig? tipConfig,
    BlobEncoder? encoder,
    int? numShards,
    BlobMetadata? precomputedMetadata,
    CommitteeInfo? committee,
    dynamic directClient,
    SystemStateReader? stateReader,
    dynamic suiClient,
  }) : _blob = blob,
       _txBuilder = txBuilder,
       _relayClient = relayClient,
       _tipConfig = tipConfig,
       _encoder = encoder,
       _numShards = numShards,
       _precomputedMetadata = precomputedMetadata,
       _committee = committee,
       _directClient = directClient,
       _stateReader = stateReader,
       _suiClient = suiClient;

  /// Step 1: Encode the blob and compute metadata.
  ///
  /// If pre-computed metadata was provided, this is a no-op.
  /// If an encoder is available, it computes the metadata.
  /// In direct mode with a [WalrusBlobEncoder], also produces
  /// encoded slivers for distribution to storage nodes.
  Future<void> encode() async {
    if (_step != _FlowStep.initial) {
      throw StateError('encode() already called');
    }

    if (_precomputedMetadata != null) {
      _metadata = _precomputedMetadata;
    } else if (_relayClient != null) {
      // Relay mode: use computeMetadata() which generates a random nonce
      // and SHA-256 blobDigest. The relay verifies the auth payload in
      // the register transaction against these values.
      //
      // Mirrors TS SDK's writeBlobFlow:
      //   const metadata = this.#uploadRelayClient
      //       ? await this.computeBlobMetadata({ bytes: blob })
      //       : await this.encodeBlob(blob);
      final walrusEncoder = _encoder is WalrusBlobEncoder
          ? _encoder
          : WalrusBlobEncoder();
      int effectiveShards = _committee?.numShards ?? _numShards ?? 0;
      if (effectiveShards == 0 && _stateReader != null) {
        final state = await _stateReader.systemState();
        effectiveShards = state.nShards;
      }
      if (effectiveShards == 0) effectiveShards = 1000;
      _metadata = await walrusEncoder.computeMetadata(_blob, effectiveShards);
    } else if (_encoder != null) {
      // Direct mode: if encoder is WalrusBlobEncoder, do full encode
      // and produce slivers for storage node distribution.
      final effectiveShards = _committee?.numShards ?? _numShards ?? 1000;

      if (_encoder is WalrusBlobEncoder) {
        final walrusEncoder = _encoder;
        final encoded = walrusEncoder.encodeBlob(_blob, effectiveShards);
        _encodedBlob = encoded;
        _metadata = await walrusEncoder.computeMetadata(_blob, effectiveShards);
      } else {
        _metadata = await _encoder.computeMetadata(_blob, effectiveShards);
      }
    } else if (_directClient != null && _committee != null) {
      // Direct mode with default encoder.
      final walrusEncoder = WalrusBlobEncoder();
      final encoded = walrusEncoder.encodeBlob(_blob, _committee.numShards);
      _encodedBlob = encoded;
      _metadata = await walrusEncoder.computeMetadata(
        _blob,
        _committee.numShards,
      );
    } else {
      throw StateError(
        'No encoder, relay client, or pre-computed metadata available.',
      );
    }

    _step = _FlowStep.encoded;
  }

  /// Step 2: Build the register transaction.
  ///
  /// Returns an unsigned [Transaction] for external signing.
  ///
  /// If [options.walCoinObjectId] is provided along with cost info,
  /// uses proper WAL payment via [WalrusTransactionBuilder.registerBlobWithWal].
  ///
  /// When [WriteBlobFlowRegisterOptions.walCoinObjectId] is not provided and
  /// a [SuiClient] + [SystemStateReader] are available (the default when
  /// created via [WalrusDirectClient.writeBlobFlow]), the flow automatically
  /// finds a WAL coin with sufficient balance for the owner.
  ///
  /// For convenience, if [_stateReader] is available and WAL cost info is not
  /// provided, this method auto-resolves costs from chain state.
  Future<Transaction> register(WriteBlobFlowRegisterOptions options) async {
    if (_step != _FlowStep.encoded) {
      throw StateError('Must call encode() before register()');
    }

    _deletable = options.deletable;
    final metadata = _metadata!;

    final tx = Transaction();
    tx.setSenderIfNotSet(options.owner);

    // Add upload relay tip if configured.
    if (_relayClient != null && _tipConfig != null) {
      final tipConfig = _tipConfig;
      _txBuilder.sendUploadRelayTip(
        size: _blob.length,
        blobDigest: metadata.blobDigest,
        nonce: metadata.nonce,
        tipConfig: tipConfig,
        transaction: tx,
      );
    }

    // Resolve WAL payment parameters.
    String? walCoinObjectId = options.walCoinObjectId;
    String? walType = options.walType;
    BigInt? storageCost = options.storageCost;
    BigInt? writeCost = options.writeCost;
    int? encodedSize = options.encodedSize;

    // Auto-resolve from chain if state reader is available.
    if (_stateReader != null &&
        (walType == null ||
            storageCost == null ||
            writeCost == null ||
            encodedSize == null)) {
      walType ??= await _stateReader.getWalType();
      final costs = await _stateReader.storageCost(
        _blob.length,
        options.epochs,
      );
      storageCost ??= costs.storageCost;
      writeCost ??= costs.writeCost;
      final state = await _stateReader.systemState();
      encodedSize ??= encodedBlobLength(_blob.length, state.nShards);
    }

    // Auto-resolve WAL coin when not provided.
    if (walCoinObjectId == null &&
        _suiClient != null &&
        walType != null &&
        storageCost != null &&
        writeCost != null) {
      final totalWalNeeded = storageCost + writeCost;
      final coins = await _suiClient.getCoins(options.owner, coinType: walType);
      final coinList = coins.data as List?;
      if (coinList != null) {
        for (final coin in coinList) {
          final balance =
              BigInt.tryParse(coin.balance as String) ?? BigInt.zero;
          if (balance >= totalWalNeeded) {
            walCoinObjectId = coin.coinObjectId as String?;
            break;
          }
        }
      }
    }

    // Register the blob on-chain with WAL payment.
    if (walCoinObjectId != null &&
        walType != null &&
        storageCost != null &&
        writeCost != null &&
        encodedSize != null) {
      _txBuilder.registerBlobWithWal(
        RegisterBlobOptions(
          size: _blob.length,
          epochs: options.epochs,
          blobId: metadata.blobId,
          rootHash: metadata.rootHash,
          deletable: options.deletable,
          owner: options.owner,
        ),
        walCoinObjectId: walCoinObjectId,
        walType: walType,
        storageCost: storageCost,
        writeCost: writeCost,
        encodedSize: encodedSize,
        transaction: tx,
      );
    } else {
      throw StateError(
        'WAL payment requires a WAL coin with sufficient balance. '
        'Either provide walCoinObjectId explicitly, or ensure a SuiClient '
        'and SystemStateReader are available for auto-resolution. '
        'Resolved: walCoinObjectId=$walCoinObjectId, walType=$walType, '
        'storageCost=$storageCost, writeCost=$writeCost, encodedSize=$encodedSize',
      );
    }

    _step = _FlowStep.registered;
    return tx;
  }

  /// Step 3: Upload the blob data.
  ///
  /// For upload relay mode: sends blob to the relay.
  /// For direct mode: writes encoded slivers to storage nodes (Phase 3).
  ///
  /// [options.digest] is the transaction digest from signing the
  /// register transaction in Step 2.
  Future<void> upload(WriteBlobFlowUploadOptions options) async {
    if (_step != _FlowStep.registered) {
      throw StateError('Must call register() before upload()');
    }

    final metadata = _metadata!;

    // Resolve the Blob Sui object ID.
    _blobObjectId = _resolveBlobObjectId(options);

    if (_relayClient != null) {
      // Relay mode: upload to relay.
      //
      // We must wait for the register transaction to be indexed so the relay
      // can verify the on-chain registration and payment.
      // Mirrors TS SDK's `client.waitForTransaction({ digest })`.
      await _suiClient.waitForTransaction(options.digest);

      final relay = _relayClient;
      final result = await relay.writeBlob(
        blobId: metadata.blobId,
        blob: _blob,
        nonce: metadata.nonce,
        txDigest: options.digest,
        blobObjectId: _blobObjectId ?? '',
        deletable: _deletable,
        requiresTip: _tipConfig != null,
        encodingType: _encodingTypeToString(metadata.encodingType),
      );
      _certificate = result.certificate;
    } else if (_directClient != null &&
        _committee != null &&
        _encodedBlob != null) {
      // Direct mode (Phase 3): write slivers to storage nodes.
      // Use the WalrusDirectClient's writeEncodedBlobToNodes method.
      final client = _directClient;
      final confirmations =
          await client.writeEncodedBlobToNodes(
                encodedBlob: _encodedBlob,
                committee: _committee,
                deletable: _deletable,
                blobObjectId: _blobObjectId ?? '',
              )
              as Map<int, StorageConfirmation?>;

      // Build certificate from confirmations.
      _certificate =
          client._buildCertificateFromConfirmations(
                confirmations: confirmations,
                committee: _committee,
              )
              as ProtocolMessageCertificate;
    } else {
      throw StateError(
        'No relay client or direct mode configuration available. '
        'Configure an upload relay or set committee + encoder for direct mode.',
      );
    }

    _step = _FlowStep.uploaded;
  }

  /// Step 4: Build the certify transaction.
  ///
  /// Returns an unsigned [Transaction] for external signing.
  Transaction certify() {
    if (_step != _FlowStep.uploaded) {
      throw StateError('Must call upload() before certify()');
    }

    if (_certificate == null) {
      throw StateError('No certificate available for certification');
    }

    // Determine committee size for signers→bitmap conversion.
    // Prefer committee info if available; otherwise infer from the
    // certificate's signer indices (max index + 1, rounded to byte).
    final committeeSize =
        _committee?.nodes.length ??
        ((_certificate!.signers.isEmpty
            ? 0
            : _certificate!.signers.reduce((a, b) => a > b ? a : b) + 1));

    final tx = _txBuilder.certifyBlobTransaction(
      CertifyBlobOptions(
        blobId: _metadata!.blobId,
        blobObjectId: _blobObjectId!,
        deletable: _deletable,
        certificate: _certificate,
        committeeSize: committeeSize,
      ),
    );

    _step = _FlowStep.certified;
    return tx;
  }

  /// Step 5: Get the final blob result.
  Future<WriteBlobResult> getBlob() async {
    if (_step != _FlowStep.certified) {
      throw StateError('Must call certify() before getBlob()');
    }

    return WriteBlobResult(
      blobId: _metadata!.blobId,
      blobObjectId: _blobObjectId!,
      certifyDigest: '', // Populated after certify tx is signed
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Resolve the Blob Sui object ID from [options].
  ///
  /// Priority: explicit [blobObjectId] > extraction from [txResult].
  String _resolveBlobObjectId(WriteBlobFlowUploadOptions options) {
    // 1. Explicit object ID.
    if (options.blobObjectId != null && options.blobObjectId!.isNotEmpty) {
      return options.blobObjectId!;
    }

    // 2. Extract from full transaction result.
    if (options.txResult != null) {
      return _extractBlobObjectIdFromResult(options.txResult!);
    }

    throw ArgumentError(
      'WriteBlobFlowUploadOptions must provide either blobObjectId or '
      'txResult (with objectChanges / effects) so the Blob Sui object ID '
      'can be resolved.',
    );
  }

  /// Extract the Blob object ID from a Sui transaction result map.
  String _extractBlobObjectIdFromResult(Map<String, dynamic> txResult) {
    // Try objectChanges first (preferred).
    final objectChanges = txResult['objectChanges'];
    if (objectChanges is List) {
      for (final change in objectChanges) {
        if (change is Map &&
            change['type'] == 'created' &&
            change['objectType'] != null &&
            change['objectType'].toString().contains('::blob::Blob')) {
          return change['objectId'] as String;
        }
      }
    }

    // Fallback: effects.created
    final effects = txResult['effects'];
    if (effects is Map) {
      final created = effects['created'];
      if (created is List && created.isNotEmpty) {
        final first = created.first;
        if (first is Map) {
          final objId = first['reference']?['objectId'] ?? first['objectId'];
          if (objId != null) return objId.toString();
        }
      }
    }

    throw ArgumentError(
      'Could not extract Blob object ID from transaction result. '
      'Ensure showObjectChanges or showEffects is enabled when executing '
      'the transaction.',
    );
  }

  /// Convert integer encoding type to the string the relay expects.
  ///
  /// Matches TS SDK's `EncodingType` = `'RS2' | 'RedStuff'`.
  static String? _encodingTypeToString(int encodingType) {
    switch (encodingType) {
      case kEncodingTypeRS2:
        return 'RS2';
      case kEncodingTypeRedStuff:
        return 'RedStuff';
      default:
        return null;
    }
  }
}
