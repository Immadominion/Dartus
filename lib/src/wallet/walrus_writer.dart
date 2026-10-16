/// Store blobs on Walrus paid for by the person's own wallet.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:sui/sui.dart';

import '../constants/walrus_constants.dart';
import '../contracts/transaction_builder.dart';
import '../encoding/blob_encoder.dart';
import '../encoding/default_blob_encoder.dart';
import '../errors/walrus_errors.dart';
import '../models/protocol_types.dart';
import '../upload_relay/upload_relay_client.dart';
import '../utils/quilts.dart';
import 'transaction_signer.dart';
import 'walrus_chain_reader.dart';

/// Writes blobs to Walrus through an upload relay, with every cost paid by
/// the signer: WAL for storage, SUI for gas and the relay's tip.
///
/// No publisher and no server-side key are involved. A write takes two
/// wallet approvals: one to register the blob (and pay), one to certify it
/// once the relay has stored it. The resulting `Blob` object belongs to the
/// signer, or to the `recipient` passed to [write].
///
/// Works on Flutter web (metadata comes from `walrus-wasm` in a Web Worker)
/// and natively (from the `walrus_ffi` library). Chain reads use Sui's
/// gRPC-web API.
///
/// ```dart
/// final writer = WalrusWriter(network: WalrusNetwork.testnet);
/// final result = await writer.write(
///   bytes,
///   epochs: 26,
///   signer: WalletTransactionSigner(
///     address: account.address,
///     execute: (tx) => wallet.signAndExecuteTransaction(tx.json),
///   ),
///   onStage: (stage) => print(stage),
/// );
/// print('${result.blobId} is stored until epoch ${result.endEpoch}');
/// ```
class WalrusWriter {
  /// [httpClient] carries the upload to the relay; pass one that reports
  /// progress to show an upload bar. [encoder] defaults to the platform's
  /// encoder (see `createDefaultBlobEncoder`).
  WalrusWriter({
    required this.network,
    WalrusChainReader? chain,
    UploadRelayClient? relay,
    BlobEncoder? encoder,
    http.Client? httpClient,
  }) : chain = chain ?? WalrusChainReader.forNetwork(network),
       relay =
           relay ??
           UploadRelayClient(
             host: network.defaultUploadRelayUrl,
             httpClient: httpClient,
           ),
       _encoder = encoder;

  final WalrusNetwork network;
  final WalrusChainReader chain;
  final UploadRelayClient relay;
  BlobEncoder? _encoder;

  BlobEncoder get encoder => _encoder ??= createDefaultBlobEncoder();

  /// What storing [size] bytes for [epochs] epochs costs right now.
  Future<WalrusWriteEstimate> estimate({
    required int size,
    required int epochs,
  }) async {
    final snapshot = await chain.system();
    _checkEpochs(epochs, snapshot);
    final cost = snapshot.storageCost(size, epochs);
    final tip = await relay.tipConfig();
    return WalrusWriteEstimate(
      cost: cost,
      relayTip: tip?.calculateTip(cost.encodedSize) ?? BigInt.zero,
      currentEpoch: snapshot.epoch,
      endEpoch: snapshot.epoch + epochs,
    );
  }

  /// What storing [files] as one quilt (see [writeFiles]) costs right now.
  /// The quilt is laid out to measure it, so this costs about as much
  /// memory as the files themselves.
  Future<WalrusWriteEstimate> estimateFiles(
    List<QuiltBlob> files, {
    required int epochs,
  }) async {
    final shards = (await chain.system()).nShards;
    final quilt = encodeQuilt(blobs: files, numShards: shards);
    return estimate(size: quilt.quilt.length, epochs: epochs);
  }

  /// The SUI and WAL [address] holds.
  Future<WalrusWalletBalances> balances(String address) =>
      chain.balances(address);

  /// A step-by-step write of [data]. Keep the flow to retry a failed step:
  /// [WalrusWriteFlow.run] continues where it stopped, so a declined or
  /// failed approval never registers or pays twice.
  WalrusWriteFlow writeFlow(
    Uint8List data, {
    required int epochs,
    bool deletable = true,
    String? recipient,
  }) => WalrusWriteFlow._(
    this,
    data,
    epochs: epochs,
    deletable: deletable,
    recipient: recipient,
  );

  /// Store [data] for [epochs] epochs, paid by [signer].
  ///
  /// The blob goes to [recipient] when given (for example the owner of a
  /// shared album), otherwise it stays with the signer. Use [writeFlow]
  /// instead to keep the progress and retry after a failure.
  Future<WalrusWriteResult> write(
    Uint8List data, {
    required WalrusTransactionSigner signer,
    required int epochs,
    bool deletable = true,
    String? recipient,
    void Function(WalrusWriteStage stage)? onStage,
  }) => writeFlow(
    data,
    epochs: epochs,
    deletable: deletable,
    recipient: recipient,
  ).run(signer, onStage: onStage);

  /// A step-by-step write of several [files] as one quilt (see
  /// [writeFiles]).
  WalrusWriteFilesFlow writeFilesFlow(
    List<QuiltBlob> files, {
    required int epochs,
    bool deletable = true,
    String? recipient,
  }) => WalrusWriteFilesFlow._(
    this,
    files,
    epochs: epochs,
    deletable: deletable,
    recipient: recipient,
  );

  /// Store several [files] together as one Walrus quilt: one blob, so one
  /// payment approval, one certify approval and one storage fee for the
  /// whole batch. (Every blob pays for at least about 64 MB of encoded
  /// storage, so a quilt of small files costs a fraction of separate
  /// blobs.)
  ///
  /// Each file comes back with a quilt patch ID, which aggregators serve at
  /// `/v1/blobs/by-quilt-patch-id/<id>` (`WalrusClient.getQuiltPatch`).
  /// Identifiers must be unique within the batch.
  Future<WalrusWriteFilesResult> writeFiles(
    List<QuiltBlob> files, {
    required WalrusTransactionSigner signer,
    required int epochs,
    bool deletable = true,
    String? recipient,
    void Function(WalrusWriteStage stage)? onStage,
  }) => writeFilesFlow(
    files,
    epochs: epochs,
    deletable: deletable,
    recipient: recipient,
  ).run(signer, onStage: onStage);

  /// Close the relay's HTTP client if this writer created it.
  void close() => relay.close();

  void _checkEpochs(int epochs, WalrusSystemSnapshot snapshot) {
    if (epochs < 1 || epochs > snapshot.maxEpochsAhead) {
      throw ArgumentError.value(
        epochs,
        'epochs',
        'must be between 1 and ${snapshot.maxEpochsAhead}',
      );
    }
  }

  Future<WalletTransaction> _forWallet(
    Transaction tx,
    String sender,
    String description,
  ) async => WalletTransaction(
    json: await chain.serializeForWallet(tx, sender),
    sender: sender,
    chain: network.suiChain,
    description: description,
  );
}

/// The stage a write is entering, reported by [WalrusWriteFlow.run].
enum WalrusWriteStage {
  /// Computing the blob ID (about a second, more for large files).
  encoding,

  /// Waiting for the wallet to approve and pay for registration.
  registering,

  /// Sending the bytes to the upload relay.
  uploading,

  /// Waiting for the wallet to approve certification.
  certifying,
}

/// A write of one blob, step by step.
///
/// [run] performs the remaining steps and can be called again after any
/// failure. The individual steps are public for apps that sign elsewhere.
class WalrusWriteFlow {
  WalrusWriteFlow._(
    this._writer,
    this.data, {
    required this.epochs,
    required this.deletable,
    this.recipient,
  });

  final WalrusWriter _writer;
  final Uint8List data;
  final int epochs;
  final bool deletable;

  /// Who receives the blob once it is certified; the signer when null.
  final String? recipient;

  BlobMetadata? _metadata;
  int? _metadataShards;
  String? _owner;
  WalrusStorageCost? _cost;
  BigInt _tip = BigInt.zero;
  bool _tipped = false;
  ProtocolMessageCertificate? _certificate;
  WalrusWriteResult? _result;

  /// Digest of the register transaction, once the wallet returned it.
  String? registerDigest;

  /// The registered `Blob` object, once the register transaction is seen.
  String? blobObjectId;

  /// Digest of the certify transaction, once the wallet returned it.
  String? certifyDigest;

  /// The blob ID, once [encode] has run.
  String? get blobId => _metadata?.blobId;

  /// The finished write, once certified.
  WalrusWriteResult? get result => _result;

  /// Perform the remaining steps with [signer], reporting each stage.
  Future<WalrusWriteResult> run(
    WalrusTransactionSigner signer, {
    void Function(WalrusWriteStage stage)? onStage,
  }) async {
    if (_result != null) return _result!;
    if (registerDigest != null && _owner != signer.address) {
      throw StateError(
        'This write was registered by $_owner; continue it with that account',
      );
    }

    if (registerDigest == null) {
      onStage?.call(WalrusWriteStage.encoding);
      await encode();
      onStage?.call(WalrusWriteStage.registering);
      final transaction = await registerTransaction(signer.address);
      registerDigest = await signer.signAndExecute(transaction);
    }
    if (blobObjectId == null) await registered(registerDigest!);

    if (_certificate == null) {
      onStage?.call(WalrusWriteStage.uploading);
      await upload();
    }

    if (certifyDigest == null) {
      onStage?.call(WalrusWriteStage.certifying);
      certifyDigest = await signer.signAndExecute(await certifyTransaction());
    }
    return certified(certifyDigest!);
  }

  /// Compute the blob ID and the relay nonce for the current shard count.
  Future<BlobMetadata> encode() async {
    final snapshot = await _writer.chain.system();
    if (_metadata == null || _metadataShards != snapshot.nShards) {
      _metadata = await _writer.encoder.computeMetadata(data, snapshot.nShards);
      _metadataShards = snapshot.nShards;
    }
    return _metadata!;
  }

  /// The transaction that pays for and registers the blob, for [owner] to
  /// sign. Throws [InsufficientWalBalanceError] when [owner] lacks the WAL.
  Future<WalletTransaction> registerTransaction(String owner) async {
    if (registerDigest != null) {
      throw StateError('The blob is already registered ($registerDigest)');
    }
    final metadata = await encode();
    final snapshot = await _writer.chain.system();
    _writer._checkEpochs(epochs, snapshot);
    final cost = snapshot.storageCost(data.length, epochs);

    final balances = await _writer.chain.balances(owner);
    if (balances.wal < cost.total) {
      throw InsufficientWalBalanceError(
        ownerAddress: owner,
        requiredAmount: cost.total,
        message:
            '$owner holds ${balances.wal} FROST of WAL; storing this blob '
            'for $epochs epochs needs ${cost.total}',
      );
    }

    final tipConfig = await _writer.relay.tipConfig();
    final builder = WalrusTransactionBuilder(
      packageConfig: _writer.network.packageConfig,
      walrusPackageId: snapshot.packageId,
    );
    final tx = Transaction();
    if (tipConfig != null) {
      builder.sendUploadRelayTip(
        size: data.length,
        encodedSize: cost.encodedSize,
        blobDigest: metadata.blobDigest,
        nonce: metadata.nonce,
        tipConfig: tipConfig,
        transaction: tx,
      );
    }
    final blob = builder.addRegisterBlob(
      tx,
      blobId: metadata.blobId,
      rootHash: metadata.rootHash,
      size: data.length,
      encodedSize: cost.encodedSize,
      epochs: epochs,
      deletable: deletable,
      walType: _writer.chain.walCoinType,
      storageCost: cost.storageCost,
      writeCost: cost.writeCost,
    );
    tx.transferObjects([blob], tx.pure.address(owner));

    _owner = owner;
    _cost = cost;
    _tipped = tipConfig != null;
    _tip = tipConfig?.calculateTip(cost.encodedSize) ?? BigInt.zero;
    return _writer._forWallet(tx, owner, 'Register Walrus blob');
  }

  /// Record the register transaction [digest] and find the new blob.
  Future<void> registered(String digest) async {
    registerDigest = digest;
    final snapshot = await _writer.chain.system();
    final created = await _writer.chain.createdObjects(
      digest,
      type: snapshot.blobType,
    );
    if (created.length != 1) {
      throw WalrusClientError(
        'Expected one new Walrus blob in $digest, found ${created.length}',
      );
    }
    blobObjectId = created.single;
  }

  /// Send the bytes to the upload relay and keep its certificate.
  Future<void> upload() async {
    final metadata = _metadata;
    if (metadata == null || registerDigest == null || blobObjectId == null) {
      throw StateError('Register the blob before uploading it');
    }
    final result = await _writer.relay.writeBlob(
      blobId: metadata.blobId,
      blob: data,
      nonce: metadata.nonce,
      txDigest: registerDigest!,
      blobObjectId: blobObjectId!,
      deletable: deletable,
      requiresTip: _tipped,
      encodingType: 'RS2',
    );
    _certificate = result.certificate;
  }

  /// The transaction that certifies the uploaded blob (and hands it to
  /// [recipient]), for the same account that registered it.
  Future<WalletTransaction> certifyTransaction() async {
    final certificate = _certificate;
    if (certificate == null || _owner == null) {
      throw StateError('Upload the blob before certifying it');
    }
    final snapshot = await _writer.chain.system();
    final builder = WalrusTransactionBuilder(
      packageConfig: _writer.network.packageConfig,
      walrusPackageId: snapshot.packageId,
    );
    final tx = builder.certifyBlobTransaction(
      CertifyBlobOptions(
        blobId: _metadata!.blobId,
        blobObjectId: blobObjectId!,
        deletable: deletable,
        certificate: certificate,
        committeeSize: snapshot.committeeSize,
      ),
    );
    final to = recipient;
    if (to != null && to != _owner) {
      tx.transferObjects([tx.object(blobObjectId!)], tx.pure.address(to));
    }
    return _writer._forWallet(tx, _owner!, 'Certify Walrus blob');
  }

  /// Record the certify transaction [digest] and read the stored blob.
  Future<WalrusWriteResult> certified(String digest) async {
    certifyDigest = digest;
    await _writer.chain.waitForSuccess(digest);
    final blob = await _writer.chain.blobObject(blobObjectId!);
    if (!blob.isCertified) {
      throw WalrusClientError('Blob ${blob.blobId} is not certified yet');
    }
    return _result = WalrusWriteResult(
      blob: blob,
      registerDigest: registerDigest!,
      certifyDigest: digest,
      cost: _cost,
      relayTip: _tip,
    );
  }
}

/// A write of several files as one quilt, step by step. Like
/// [WalrusWriteFlow], [run] continues where it stopped after a failure.
class WalrusWriteFilesFlow {
  WalrusWriteFilesFlow._(
    this._writer,
    List<QuiltBlob> files, {
    required this.epochs,
    required this.deletable,
    this.recipient,
  }) : files = List.unmodifiable(files) {
    if (files.isEmpty) throw ArgumentError.value(files, 'files', 'is empty');
  }

  final WalrusWriter _writer;
  final List<QuiltBlob> files;
  final int epochs;
  final bool deletable;
  final String? recipient;

  WalrusWriteFlow? _flow;
  QuiltIndex? _index;
  int? _shards;

  /// The flow writing the quilt blob, once the quilt is laid out.
  WalrusWriteFlow? get blobFlow => _flow;

  /// Perform the remaining steps with [signer], reporting each stage.
  Future<WalrusWriteFilesResult> run(
    WalrusTransactionSigner signer, {
    void Function(WalrusWriteStage stage)? onStage,
  }) async {
    final flow = await _quiltFlow();
    final result = await flow.run(signer, onStage: onStage);
    return WalrusWriteFilesResult(
      quilt: result,
      files: [
        for (final patch in _index!.patches)
          WalrusStoredFile(
            identifier: patch.identifier,
            tags: patch.tags,
            patchId: encodeQuiltPatchId(
              quiltBlobId: result.blobId,
              version: 1,
              startIndex: patch.startIndex,
              endIndex: patch.endIndex,
            ),
          ),
      ],
    );
  }

  /// The quilt layout depends on the shard count, so it is redone if that
  /// changed before the blob was registered.
  Future<WalrusWriteFlow> _quiltFlow() async {
    final existing = _flow;
    if (existing != null && existing.registerDigest != null) return existing;
    final shards = (await _writer.chain.system()).nShards;
    if (existing != null && _shards == shards) return existing;
    final quilt = encodeQuilt(blobs: files, numShards: shards);
    _index = quilt.index;
    _shards = shards;
    return _flow = _writer.writeFlow(
      quilt.quilt,
      epochs: epochs,
      deletable: deletable,
      recipient: recipient,
    );
  }
}

/// One file of a quilt.
@immutable
class WalrusStoredFile {
  const WalrusStoredFile({
    required this.identifier,
    required this.patchId,
    required this.tags,
  });

  final String identifier;

  /// Reads this file alone: `/v1/blobs/by-quilt-patch-id/<patchId>`.
  final String patchId;

  final Map<String, String> tags;
}

/// A certified quilt and its files.
@immutable
class WalrusWriteFilesResult {
  const WalrusWriteFilesResult({required this.quilt, required this.files});

  /// The quilt blob's write (its object, digests and cost).
  final WalrusWriteResult quilt;

  /// One entry per file, in quilt order.
  final List<WalrusStoredFile> files;

  /// The file stored under [identifier].
  WalrusStoredFile file(String identifier) =>
      files.firstWhere((f) => f.identifier == identifier);
}

/// What a write will cost.
@immutable
class WalrusWriteEstimate {
  const WalrusWriteEstimate({
    required this.cost,
    required this.relayTip,
    required this.currentEpoch,
    required this.endEpoch,
  });

  /// WAL for storage and registration, in FROST.
  final WalrusStorageCost cost;

  /// SUI tip for the upload relay, in MIST (gas comes on top).
  final BigInt relayTip;

  final int currentEpoch;

  /// Storage would end at the start of this epoch.
  final int endEpoch;
}

/// A certified blob and how it got there.
@immutable
class WalrusWriteResult {
  const WalrusWriteResult({
    required this.blob,
    required this.registerDigest,
    required this.certifyDigest,
    required this.cost,
    required this.relayTip,
  });

  /// The `Blob` object as read back from Sui after certification.
  final WalrusBlobObject blob;

  final String registerDigest;
  final String certifyDigest;

  /// WAL paid, when this flow built the register transaction.
  final WalrusStorageCost? cost;

  /// SUI tip paid to the relay, in MIST.
  final BigInt relayTip;

  String get blobId => blob.blobId;
  String get blobObjectId => blob.objectId;
  int get endEpoch => blob.endEpoch;
}
