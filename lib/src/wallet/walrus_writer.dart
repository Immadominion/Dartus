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
import '../utils/upload_policy.dart';
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
    this.maxRelayTip,
  }) : _ownsRelay = relay == null,
       chain = chain ?? WalrusChainReader.forNetwork(network),
       relay =
           relay ??
           UploadRelayClient(
             host: network.defaultUploadRelayUrl,
             httpClient: httpClient,
           ),
       _encoder = encoder {
    if (maxRelayTip != null && maxRelayTip! < BigInt.zero) {
      throw ArgumentError.value(
        maxRelayTip,
        'maxRelayTip',
        'must not be negative',
      );
    }
  }

  final WalrusNetwork network;
  final WalrusChainReader chain;
  final UploadRelayClient relay;
  final bool _ownsRelay;

  /// Maximum relay tip this caller permits, in MIST (1 SUI = 10^9 MIST).
  /// Checked for both estimates and registration, before the wallet is asked.
  /// Null means no SDK cap; the wallet still asks the person to approve the
  /// payment. Set an explicit budget for automated signers.
  final BigInt? maxRelayTip;
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
      relayTip: _relayTip(tip, cost.encodedSize),
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
  /// The bytes are copied into an immutable snapshot. [WalrusWriteFlow.run]
  /// continues where it stopped. Known wallet
  /// rejections are retryable; unknown submission outcomes require explicit
  /// resolution before another transaction can be sent.
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
  void close() {
    if (_ownsRelay) relay.close();
  }

  BigInt _relayTip(UploadRelayTipConfig? config, int encodedSize) {
    final amount = config?.calculateTip(encodedSize) ?? BigInt.zero;
    if (amount < BigInt.zero ||
        (maxRelayTip != null && amount > maxRelayTip!)) {
      throw WalrusClientError(
        'Relay tip $amount MIST exceeds the permitted budget '
        '${maxRelayTip ?? 'of non-negative amounts'}',
      );
    }
    return amount;
  }

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
/// [run] performs the remaining steps. A known rejection or relay failure
/// can be retried; an unknown wallet outcome must first be reconciled through
/// [registered], [certified] or [confirmNotCommitted]. Concurrent operations
/// on the same flow are rejected. The individual steps are public for apps
/// that sign elsewhere.
class WalrusWriteFlow {
  WalrusWriteFlow._(
    this._writer,
    Uint8List data, {
    required this.epochs,
    required this.deletable,
    String? recipient,
  }) : data = Uint8List.fromList(data).asUnmodifiableView(),
       recipient = recipient == null
           ? null
           : _walletAddress(recipient, 'recipient') {
    requireDeletableUpload(deletable);
    _positiveEpochs(epochs);
  }

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
  bool _busy = false;
  WalrusTransactionOutcomeUnknown? _unknownOutcome;
  bool _unknownIsRegistration = true;

  /// A submission whose outcome must be checked before this flow can retry.
  WalrusTransactionOutcomeUnknown? get unknownOutcome => _unknownOutcome;

  /// Allow a retry only after the wallet/chain confirms that the pending
  /// request did not succeed and cannot succeed later. For a successful
  /// request, supply its digest to [registered] or [certified] instead.
  void confirmNotCommitted() {
    if (_busy) throw StateError('A write operation is already in progress');
    if (_unknownOutcome == null) {
      throw StateError('There is no unknown submission to resolve');
    }
    _unknownOutcome = null;
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_busy) throw StateError('A write operation is already in progress');
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  /// Digest of the register transaction, once the wallet returned it.
  String? _registerDigest;
  String? get registerDigest => _registerDigest;

  /// The registered `Blob` object, once the register transaction is seen.
  String? _blobObjectId;
  String? get blobObjectId => _blobObjectId;

  /// Digest of the certify transaction, once the wallet returned it.
  String? _certifyDigest;
  String? get certifyDigest => _certifyDigest;

  /// The blob ID, once [encode] has run.
  String? get blobId => _metadata?.blobId;

  /// The finished write, once certified.
  WalrusWriteResult? get result => _result;

  /// Perform the remaining steps with [signer], reporting each stage.
  Future<WalrusWriteResult> run(
    WalrusTransactionSigner signer, {
    void Function(WalrusWriteStage stage)? onStage,
  }) => _exclusive(() => _run(signer, onStage: onStage));

  Future<WalrusWriteResult> _run(
    WalrusTransactionSigner signer, {
    void Function(WalrusWriteStage stage)? onStage,
  }) async {
    if (_result != null) return _result!;
    final owner = _walletAddress(signer.address, 'signer.address');
    if (_unknownOutcome != null) throw _unknownOutcome!;
    if (registerDigest != null && _owner != owner) {
      throw StateError(
        'This write was registered by $_owner; continue it with that account',
      );
    }

    if (registerDigest == null) {
      onStage?.call(WalrusWriteStage.encoding);
      await _encode();
      onStage?.call(WalrusWriteStage.registering);
      final transaction = await _registerTransaction(owner);
      _registerDigest = await _submit(signer, transaction, registration: true);
    }
    if (blobObjectId == null) await _registered(registerDigest!);

    if (_certificate == null) {
      onStage?.call(WalrusWriteStage.uploading);
      await _upload();
    }

    if (certifyDigest == null) {
      onStage?.call(WalrusWriteStage.certifying);
      _certifyDigest = await _submit(
        signer,
        await _certifyTransaction(),
        registration: false,
      );
    }
    return _certified(certifyDigest!);
  }

  Future<String> _submit(
    WalrusTransactionSigner signer,
    WalletTransaction transaction, {
    required bool registration,
  }) async {
    try {
      final digest = await signer.signAndExecute(transaction);
      if (digest.trim().isEmpty) {
        throw StateError('The wallet returned no transaction digest');
      }
      return digest;
    } on WalrusTransactionNotCommitted {
      rethrow;
    } catch (error) {
      var definitelyNotCommitted = false;
      if (signer is WalletTransactionSigner) {
        try {
          definitelyNotCommitted =
              signer.isDefinitelyNotCommitted?.call(error) == true;
        } catch (_) {
          // A broken classifier does not establish a safe retry.
        }
      }
      if (definitelyNotCommitted) rethrow;
      _unknownIsRegistration = registration;
      throw _unknownOutcome = WalrusTransactionOutcomeUnknown(
        transaction,
        error,
      );
    }
  }

  /// Compute the blob ID and the relay nonce for the current shard count.
  Future<BlobMetadata> encode() => _exclusive(_encode);

  Future<BlobMetadata> _encode() async {
    // A paid or possibly-paid registration commits this exact metadata and
    // nonce. Epoch changes must not silently replace them during recovery.
    if (_metadata != null &&
        (registerDigest != null || _unknownOutcome != null)) {
      return _metadata!;
    }
    final snapshot = await _writer.chain.system();
    if (_metadata == null || _metadataShards != snapshot.nShards) {
      _metadata = await _writer.encoder.computeMetadata(data, snapshot.nShards);
      _metadataShards = snapshot.nShards;
    }
    return _metadata!;
  }

  /// The transaction that pays for and registers the blob, for [owner] to
  /// sign. Throws [InsufficientWalBalanceError] when [owner] lacks the WAL.
  Future<WalletTransaction> registerTransaction(String owner) =>
      _exclusive(() => _registerTransaction(owner));

  Future<WalletTransaction> _registerTransaction(String owner) async {
    owner = _walletAddress(owner, 'owner');
    if (_unknownOutcome != null) throw _unknownOutcome!;
    if (registerDigest != null) {
      throw StateError('The blob is already registered ($registerDigest)');
    }
    final metadata = await _encode();
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
    final tipAmount = _writer._relayTip(tipConfig, cost.encodedSize);
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
    _tip = tipAmount;
    return _writer._forWallet(tx, owner, 'Register Walrus blob');
  }

  /// Record the register transaction [digest] and find the new blob.
  Future<void> registered(String digest) =>
      _exclusive(() => _registered(digest));

  Future<void> _registered(String digest) async {
    if (_unknownOutcome != null && !_unknownIsRegistration) {
      throw StateError('Resolve the unknown certification, not registration');
    }
    if (_owner == null || _metadata == null) {
      throw StateError('Build the register transaction before recording it');
    }
    if (digest.trim().isEmpty) throw ArgumentError.value(digest, 'digest');
    if (registerDigest != null && registerDigest != digest) {
      throw StateError('This flow already has a registration digest');
    }
    _registerDigest = digest;
    final snapshot = await _writer.chain.system();
    final List<String> created;
    try {
      created = await _writer.chain.createdObjects(
        digest,
        type: snapshot.blobType,
      );
    } on WalrusTransactionExecutionFailed {
      _registerDigest = null;
      _unknownOutcome = null;
      rethrow;
    }
    if (created.length != 1) {
      throw WalrusClientError(
        'Expected one new Walrus blob in $digest, found ${created.length}',
      );
    }
    final blob = await _writer.chain.blobObject(created.single);
    _validateBlob(blob, expectedOwner: _owner!, objectId: created.single);
    _blobObjectId = created.single;
    _unknownOutcome = null;
  }

  /// Send the bytes to the upload relay and keep its certificate.
  Future<void> upload() => _exclusive(_upload);

  Future<void> _upload() async {
    if (_unknownOutcome != null) throw _unknownOutcome!;
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
  Future<WalletTransaction> certifyTransaction() =>
      _exclusive(_certifyTransaction);

  Future<WalletTransaction> _certifyTransaction() async {
    if (_unknownOutcome != null) throw _unknownOutcome!;
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
  Future<WalrusWriteResult> certified(String digest) =>
      _exclusive(() => _certified(digest));

  Future<WalrusWriteResult> _certified(String digest) async {
    if (_unknownOutcome != null && _unknownIsRegistration) {
      throw StateError('Resolve the unknown registration first');
    }
    if (blobObjectId == null || _owner == null || _certificate == null) {
      throw StateError(
        'Upload the registered blob before recording certification',
      );
    }
    if (digest.trim().isEmpty) throw ArgumentError.value(digest, 'digest');
    if (certifyDigest != null && certifyDigest != digest) {
      throw StateError('This flow already has a certification digest');
    }
    _certifyDigest = digest;
    try {
      await _writer.chain.waitForSuccess(digest);
    } on WalrusTransactionExecutionFailed {
      _certifyDigest = null;
      _unknownOutcome = null;
      rethrow;
    }
    final blob = await _writer.chain.blobObject(blobObjectId!);
    _validateBlob(
      blob,
      expectedOwner: recipient ?? _owner!,
      objectId: blobObjectId!,
    );
    if (!blob.isCertified) {
      throw WalrusClientError('Blob ${blob.blobId} is not certified yet');
    }
    _unknownOutcome = null;
    return _result = WalrusWriteResult(
      blob: blob,
      registerDigest: registerDigest!,
      certifyDigest: digest,
      cost: _cost,
      relayTip: _tip,
    );
  }

  void _validateBlob(
    WalrusBlobObject blob, {
    required String expectedOwner,
    required String objectId,
  }) {
    if (_walletAddress(blob.objectId, 'blob.objectId') !=
            _walletAddress(objectId, 'objectId') ||
        blob.blobId != _metadata!.blobId ||
        blob.size != data.length ||
        blob.deletable != deletable ||
        blob.owner == null ||
        _walletAddress(blob.owner!, 'blob.owner') != expectedOwner ||
        blob.endEpoch - blob.startEpoch != epochs) {
      throw WalrusClientError(
        'Blob ${blob.objectId} does not match this write\'s content, size, '
        'owner, deletability or storage period',
      );
    }
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
    String? recipient,
  }) : files = List.unmodifiable([
         for (final file in files)
           QuiltBlob(
             contents: Uint8List.fromList(file.contents).asUnmodifiableView(),
             identifier: file.identifier,
             tags: file.tags == null ? null : Map.unmodifiable(file.tags!),
           ),
       ]),
       recipient = recipient == null
           ? null
           : _walletAddress(recipient, 'recipient') {
    requireDeletableUpload(deletable);
    _positiveEpochs(epochs);
    if (files.isEmpty) throw ArgumentError.value(files, 'files', 'is empty');
    if (files.map((file) => file.identifier).toSet().length != files.length) {
      throw ArgumentError.value(files, 'files', 'identifiers must be unique');
    }
  }

  final WalrusWriter _writer;
  final List<QuiltBlob> files;
  final int epochs;
  final bool deletable;
  final String? recipient;

  WalrusWriteFlow? _flow;
  QuiltIndex? _index;
  int? _shards;
  bool _busy = false;

  /// The flow writing the quilt blob, once the quilt is laid out.
  WalrusWriteFlow? get blobFlow => _flow;

  /// Perform the remaining steps with [signer], reporting each stage.
  Future<WalrusWriteFilesResult> run(
    WalrusTransactionSigner signer, {
    void Function(WalrusWriteStage stage)? onStage,
  }) async {
    _walletAddress(signer.address, 'signer.address');
    if (_busy) throw StateError('A batch write is already in progress');
    _busy = true;
    try {
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
    } finally {
      _busy = false;
    }
  }

  /// The quilt layout depends on the shard count, so it is redone if that
  /// changed before the blob was registered.
  Future<WalrusWriteFlow> _quiltFlow() async {
    final existing = _flow;
    if (existing != null &&
        (existing.registerDigest != null || existing.unknownOutcome != null)) {
      return existing;
    }
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

String _walletAddress(String value, String name) {
  if (!RegExp(r'^(?:0x)?[0-9a-fA-F]{1,64}$').hasMatch(value)) {
    throw ArgumentError.value(value, name, 'must be a Sui address');
  }
  final hex = value.startsWith('0x') ? value.substring(2) : value;
  return '0x${hex.toLowerCase().padLeft(64, '0')}';
}

void _positiveEpochs(int epochs) {
  if (epochs < 1) {
    throw ArgumentError.value(epochs, 'epochs', 'must be positive');
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
