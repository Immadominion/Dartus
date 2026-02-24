/// Multi-step write files flow for wallet-integrated quilt uploads.
///
/// Mirrors the TS SDK's `WriteFilesFlow` interface, enabling dApp
/// wallets to sign each transaction step independently when uploading
/// multiple files as a quilt.
///
/// Flow:
/// 1. `encode()` → encode files into a quilt, compute metadata
/// 2. `register(options)` → build & return register transaction
/// 3. `upload(digest)` → upload quilt blob to relay or storage nodes
/// 4. `certify()` → build & return certify transaction
/// 5. `listFiles()` → return file patch IDs and blob info
library;

import 'dart:typed_data';

import 'package:sui/builder/transaction.dart';

import '../chain/system_state_reader.dart';
import '../contracts/transaction_builder.dart';
import '../encoding/blob_encoder.dart';
import '../encoding/walrus_blob_encoder.dart';
import '../files/file.dart';
import '../models/protocol_types.dart';
import '../models/storage_node_types.dart';
import '../upload_relay/upload_relay_client.dart';
import '../utils/encoding_utils.dart';
import '../utils/quilts.dart';
import 'write_blob_flow.dart';

/// Result for a single file in a [WriteFilesFlow].
class WriteFileResult {
  /// Quilt patch ID for this file (URL-safe base64, 37 bytes decoded).
  final String id;

  /// The quilt blob ID (URL-safe base64, 32 bytes decoded).
  final String blobId;

  /// The blob Sui object ID.
  final String blobObjectId;

  const WriteFileResult({
    required this.id,
    required this.blobId,
    required this.blobObjectId,
  });

  @override
  String toString() =>
      'WriteFileResult(id: $id, blobId: $blobId, blobObjectId: $blobObjectId)';
}

/// Options for [WriteFilesFlow.register].
class WriteFilesFlowRegisterOptions {
  /// Number of storage epochs.
  final int epochs;

  /// Sui address that will own the blob object.
  final String owner;

  /// Whether the blob can be deleted.
  final bool deletable;

  /// Optional blob attributes (key-value metadata).
  final Map<String, String?>? attributes;

  /// WAL coin object ID for payment.
  final String? walCoinObjectId;

  /// WAL coin type string.
  final String? walType;

  /// Pre-calculated storage cost in WAL.
  final BigInt? storageCost;

  /// Pre-calculated write cost in WAL.
  final BigInt? writeCost;

  /// Pre-calculated encoded blob size.
  final int? encodedSize;

  const WriteFilesFlowRegisterOptions({
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

/// Multi-step write files flow for wallet integration.
///
/// Similar to [WriteBlobFlow] but encodes multiple files into a quilt
/// and returns per-file patch IDs at the end.
///
/// Usage:
/// ```dart
/// final flow = await directClient.writeFilesFlow(files: myFiles);
///
/// // Step 1: Encode files into quilt
/// await flow.encode();
///
/// // Step 2: Get register transaction → sign externally
/// final registerTx = await flow.register(WriteFilesFlowRegisterOptions(
///   epochs: 3,
///   owner: myAddress,
///   deletable: true,
/// ));
/// final registerResult = await wallet.signAndExecute(registerTx);
///
/// // Step 3: Upload quilt blob
/// await flow.upload(WriteBlobFlowUploadOptions(
///   digest: registerResult.digest,
/// ));
///
/// // Step 4: Get certify transaction → sign externally
/// final certifyTx = flow.certify();
/// await wallet.signAndExecute(certifyTx);
///
/// // Step 5: Get file results
/// final files = await flow.listFiles();
/// for (final file in files) {
///   print('File ID: ${file.id}');
/// }
/// ```
class WriteFilesFlow {
  final List<WalrusFile> _files;
  final WalrusTransactionBuilder _txBuilder;
  final UploadRelayClient? _relayClient;
  final UploadRelayTipConfig? _tipConfig;
  final BlobEncoder? _encoder;

  // Direct mode.
  final CommitteeInfo? _committee;
  final dynamic _directClient;

  // On-chain state reader.
  final SystemStateReader? _stateReader;

  // Sui RPC client for auto-resolving WAL coins.
  final dynamic _suiClient;

  // State
  _WriteFilesFlowStep _step = _WriteFilesFlowStep.initial;
  Uint8List? _quiltBytes;
  QuiltIndex? _quiltIndex;
  BlobMetadata? _metadata;
  EncodedBlob? _encodedBlob;
  String? _blobObjectId;
  ProtocolMessageCertificate? _certificate;
  bool _deletable = false;

  WriteFilesFlow({
    required List<WalrusFile> files,
    required WalrusTransactionBuilder txBuilder,
    UploadRelayClient? relayClient,
    UploadRelayTipConfig? tipConfig,
    BlobEncoder? encoder,
    CommitteeInfo? committee,
    dynamic directClient,
    SystemStateReader? stateReader,
    dynamic suiClient,
  }) : _files = files,
       _txBuilder = txBuilder,
       _relayClient = relayClient,
       _tipConfig = tipConfig,
       _encoder = encoder,
       _committee = committee,
       _directClient = directClient,
       _stateReader = stateReader,
       _suiClient = suiClient;

  /// Step 1: Encode files into a quilt and compute metadata.
  Future<void> encode() async {
    if (_step != _WriteFilesFlowStep.initial) {
      throw StateError('encode() already called');
    }

    // Read all files' bytes, identifiers, and tags.
    final blobs = <QuiltBlob>[];
    for (var i = 0; i < _files.length; i++) {
      final file = _files[i];
      blobs.add(
        QuiltBlob(
          contents: await file.bytes(),
          identifier: await file.getIdentifier() ?? 'file-$i',
          tags: await file.getTags(),
        ),
      );
    }

    // Determine shard count.
    int numShards;
    if (_committee != null) {
      numShards = _committee.numShards;
    } else if (_stateReader != null) {
      final state = await _stateReader.systemState();
      numShards = state.nShards;
    } else {
      numShards = 1000; // Testnet default.
    }

    // Encode quilt.
    final quiltResult = encodeQuilt(blobs: blobs, numShards: numShards);
    _quiltBytes = quiltResult.quilt;
    _quiltIndex = quiltResult.index;

    // Compute blob metadata for the quilt.
    if (_encoder is WalrusBlobEncoder) {
      final walrusEncoder = _encoder;
      final encoded = walrusEncoder.encodeBlob(_quiltBytes!, numShards);
      _encodedBlob = encoded;
      _metadata = await walrusEncoder.computeMetadata(_quiltBytes!, numShards);
    } else if (_encoder != null) {
      _metadata = await _encoder.computeMetadata(_quiltBytes!, numShards);
    } else if (_relayClient != null) {
      throw StateError(
        'Upload relay mode requires a BlobEncoder for quilt encoding.',
      );
    } else {
      throw StateError('No encoder available for quilt encoding.');
    }

    _step = _WriteFilesFlowStep.encoded;
  }

  /// Step 2: Build the register transaction.
  ///
  /// Returns an unsigned [Transaction] for external signing.
  /// Sets the `_walrusBlobType: 'quilt'` attribute automatically.
  Future<Transaction> register(WriteFilesFlowRegisterOptions options) async {
    if (_step != _WriteFilesFlowStep.encoded) {
      throw StateError('Must call encode() before register()');
    }

    _deletable = options.deletable;
    final metadata = _metadata!;
    final quiltBytes = _quiltBytes!;

    final tx = Transaction();
    tx.setSenderIfNotSet(options.owner);

    // Add upload relay tip if configured.
    if (_relayClient != null && _tipConfig != null) {
      _txBuilder.sendUploadRelayTip(
        size: quiltBytes.length,
        blobDigest: metadata.blobDigest,
        nonce: metadata.nonce,
        tipConfig: _tipConfig,
        transaction: tx,
      );
    }

    // Register the blob on-chain.
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
        quiltBytes.length,
        options.epochs,
      );
      storageCost ??= costs.storageCost;
      writeCost ??= costs.writeCost;
      final state = await _stateReader.systemState();
      encodedSize ??= encodedBlobLength(quiltBytes.length, state.nShards);
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

    if (walCoinObjectId != null &&
        walType != null &&
        storageCost != null &&
        writeCost != null &&
        encodedSize != null) {
      _txBuilder.registerBlobWithWal(
        RegisterBlobOptions(
          size: quiltBytes.length,
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

    _step = _WriteFilesFlowStep.registered;
    return tx;
  }

  /// Step 3: Upload the quilt blob data.
  Future<void> upload(WriteBlobFlowUploadOptions options) async {
    if (_step != _WriteFilesFlowStep.registered) {
      throw StateError('Must call register() before upload()');
    }

    final metadata = _metadata!;
    final quiltBytes = _quiltBytes!;

    // Resolve the Blob Sui object ID.
    _blobObjectId = _resolveBlobObjectId(options);

    if (_relayClient != null) {
      // Wait for register tx to be indexed before contacting relay.
      // Mirrors TS SDK's waitForTransaction before writeBlobToUploadRelay.
      await _suiClient.waitForTransaction(options.digest);

      final result = await _relayClient.writeBlob(
        blobId: metadata.blobId,
        blob: quiltBytes,
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
      final client = _directClient;
      final confirmations =
          await client.writeEncodedBlobToNodes(
                encodedBlob: _encodedBlob,
                committee: _committee,
                deletable: _deletable,
                blobObjectId: _blobObjectId ?? '',
              )
              as Map<int, StorageConfirmation?>;

      _certificate =
          client._buildCertificateFromConfirmations(
                confirmations: confirmations,
                committee: _committee,
              )
              as ProtocolMessageCertificate;
    } else {
      throw StateError(
        'No relay client or direct mode configuration available.',
      );
    }

    _step = _WriteFilesFlowStep.uploaded;
  }

  /// Step 4: Build the certify transaction.
  Transaction certify() {
    if (_step != _WriteFilesFlowStep.uploaded) {
      throw StateError('Must call upload() before certify()');
    }

    if (_certificate == null) {
      throw StateError('No certificate available for certification');
    }

    // Determine committee size for signers→bitmap conversion.
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

    _step = _WriteFilesFlowStep.certified;
    return tx;
  }

  /// Step 5: Get the final file results with patch IDs.
  Future<List<WriteFileResult>> listFiles() async {
    if (_step != _WriteFilesFlowStep.certified) {
      throw StateError('Must call certify() before listFiles()');
    }

    final metadata = _metadata!;
    final index = _quiltIndex!;

    return index.patches.map((patch) {
      return WriteFileResult(
        id: encodeQuiltPatchId(
          quiltBlobId: metadata.blobId,
          version: 1,
          startIndex: patch.startIndex,
          endIndex: patch.endIndex,
        ),
        blobId: metadata.blobId,
        blobObjectId: _blobObjectId!,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _resolveBlobObjectId(WriteBlobFlowUploadOptions options) {
    if (options.blobObjectId != null && options.blobObjectId!.isNotEmpty) {
      return options.blobObjectId!;
    }

    if (options.txResult != null) {
      return _extractBlobObjectIdFromResult(options.txResult!);
    }

    throw ArgumentError(
      'WriteBlobFlowUploadOptions must provide either blobObjectId or '
      'txResult so the Blob Sui object ID can be resolved.',
    );
  }

  String _extractBlobObjectIdFromResult(Map<String, dynamic> txResult) {
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
      'Could not extract Blob object ID from transaction result.',
    );
  }

  /// Convert integer encoding type to the string the relay expects.
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

/// Internal flow step tracking.
enum _WriteFilesFlowStep { initial, encoded, registered, uploaded, certified }
