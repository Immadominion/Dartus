import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:sui/sui.dart';
import 'package:test/test.dart';

const _owner =
    '0x00000000000000000000000000000000000000000000000000000000000a11ce';
const _host =
    '0x0000000000000000000000000000000000000000000000000000000000000b0b';
const _relayAddress =
    '0x00000000000000000000000000000000000000000000000000000000000071e5';
const _blobObject =
    '0x00000000000000000000000000000000000000000000000000000000000000b1';
const _packageId =
    '0x00000000000000000000000000000000000000000000000000000000000000aa';
const _typeOrigin =
    '0x00000000000000000000000000000000000000000000000000000000000000ab';
const _walType = '0x8::wal::WAL';
const _blobId = 'M4hsZGQ1oCktdzegB6HnI1Mx0p2v6V1mtJmzv1FwUMg';

final _snapshot = WalrusSystemSnapshot(
  epoch: 100,
  nShards: 1000,
  committeeSize: 99,
  storagePricePerUnit: BigInt.from(100),
  writePricePerUnit: BigInt.from(20),
  packageId: _packageId,
  typeOriginPackageId: _typeOrigin,
  maxEpochsAhead: 53,
);

void main() {
  late _FakeChain chain;
  late _FakeRelay relay;
  late _FakeSigner signer;
  late WalrusWriter writer;
  final data = Uint8List.fromList(utf8.encode('hello walrus'));

  setUp(() {
    chain = _FakeChain();
    relay = _FakeRelay();
    signer = _FakeSigner(_owner);
    writer = WalrusWriter(
      network: WalrusNetwork.testnet,
      chain: chain,
      relay: relay,
      encoder: _FakeEncoder(),
    );
  });

  test('estimate prices the encoded size and the relay tip', () async {
    final estimate = await writer.estimate(size: 1048576, epochs: 26);
    // 1 MiB encodes to 70,038,000 bytes on 1000 shards = 67 storage units.
    expect(estimate.cost.encodedSize, 70038000);
    expect(estimate.cost.storageCost, BigInt.from(67 * 100 * 26));
    expect(estimate.cost.writeCost, BigInt.from(67 * 20));
    expect(estimate.relayTip, BigInt.from(105));
    expect(estimate.endEpoch, 126);
  });

  test('epochs outside 1..maxEpochsAhead are refused', () {
    expect(
      () => writer.estimate(size: 1, epochs: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => writer.estimate(size: 1, epochs: 54),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a write registers, uploads and certifies with two approvals', () async {
    final stages = <WalrusWriteStage>[];
    final result = await writer.write(
      data,
      signer: signer,
      epochs: 5,
      onStage: stages.add,
    );

    expect(stages, WalrusWriteStage.values);
    expect(signer.signed.map((t) => t.description), [
      'Register Walrus blob',
      'Certify Walrus blob',
    ]);
    expect(signer.signed.every((t) => t.chain == 'sui:testnet'), isTrue);
    expect(signer.signed.every((t) => t.sender == _owner), isTrue);

    final register = _Tx(signer.signed.first.json);
    expect(register.moveCalls, [
      '$_packageId::system::reserve_space',
      '0x2::coin::destroy_zero',
      '$_packageId::system::register_blob',
      '0x2::coin::destroy_zero',
    ]);
    // WAL is requested as exact-amount coins, resolved before signing.
    final cost = _snapshot.storageCost(data.length, 5);
    expect(register.walIntents, [cost.storageCost, cost.writeCost]);
    expect(register.transferredTo, contains(_relayAddress));
    expect(register.transferredTo.last, _owner);

    expect(relay.writes.single['blobObjectId'], _blobObject);
    expect(relay.writes.single['txDigest'], 'register-digest');
    expect(relay.writes.single['requiresTip'], isTrue);
    expect(relay.writes.single['deletable'], isTrue);

    final certify = _Tx(signer.signed.last.json);
    expect(certify.moveCalls, ['$_packageId::system::certify_blob']);
    expect(certify.transferredTo, isEmpty);

    expect(result.blobId, _blobId);
    expect(result.blobObjectId, _blobObject);
    expect(result.registerDigest, 'register-digest');
    expect(result.certifyDigest, 'certify-digest');
    expect(result.cost?.total, cost.total);
    expect(result.relayTip, BigInt.from(105));
  });

  test('a recipient receives the blob in the certify transaction', () async {
    await writer.write(data, signer: signer, epochs: 1, recipient: _host);
    final certify = _Tx(signer.signed.last.json);
    expect(certify.moveCalls, ['$_packageId::system::certify_blob']);
    expect(certify.transferredTo, [_host]);
  });

  test('too little WAL fails before the wallet is asked', () async {
    chain.wal = BigInt.from(10);
    await expectLater(
      writer.write(data, signer: signer, epochs: 1),
      throwsA(isA<InsufficientWalBalanceError>()),
    );
    expect(signer.signed, isEmpty);
  });

  test('no tip and no auth payload when the relay asks for none', () async {
    relay.tip = null;
    await writer.write(data, signer: signer, epochs: 1);
    final register = _Tx(signer.signed.first.json);
    expect(register.transferredTo, [_owner]);
    expect(relay.writes.single['requiresTip'], isFalse);
  });

  group('a flow continues where it stopped', () {
    test('after a declined registration', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      signer.declineNext = true;
      await expectLater(flow.run(signer), throwsA(isA<StateError>()));
      expect(flow.registerDigest, isNull);

      await flow.run(signer);
      expect(signer.signed.map((t) => t.description), [
        'Register Walrus blob',
        'Register Walrus blob',
        'Certify Walrus blob',
      ]);
      expect(relay.writes, hasLength(1));
    });

    test('after a failed upload, without paying again', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      relay.failNext = true;
      await expectLater(flow.run(signer), throwsA(isA<UploadRelayError>()));

      await flow.run(signer);
      expect(signer.signed.map((t) => t.description), [
        'Register Walrus blob',
        'Certify Walrus blob',
      ]);
      expect(relay.writes, hasLength(1));
    });

    test('after a declined certification, without uploading again', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      signer.declineAfter = 1;
      await expectLater(flow.run(signer), throwsA(isA<StateError>()));
      expect(flow.blobObjectId, _blobObject);

      final result = await flow.run(signer);
      expect(result.certifyDigest, 'certify-digest');
      expect(relay.writes, hasLength(1));
      expect(
        signer.signed.where((t) => t.description == 'Register Walrus blob'),
        hasLength(1),
      );
    });

    test('after the register transaction could not be found yet', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      chain.createdFailures = 1;
      await expectLater(flow.run(signer), throwsA(isA<WalrusClientError>()));
      expect(flow.registerDigest, 'register-digest');

      await flow.run(signer);
      expect(
        signer.signed.where((t) => t.description == 'Register Walrus blob'),
        hasLength(1),
      );
    });

    test('but only with the account that registered it', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      signer.declineAfter = 1;
      await expectLater(flow.run(signer), throwsA(isA<StateError>()));
      await expectLater(
        flow.run(_FakeSigner(_host)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('registered by'),
          ),
        ),
      );
    });

    test('with another account if nothing was registered yet', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      signer.declineNext = true;
      await expectLater(flow.run(signer), throwsA(isA<StateError>()));

      final other = _FakeSigner(_host);
      final result = await flow.run(other);
      expect(result.registerDigest, 'register-digest');
      expect(other.signed.every((t) => t.sender == _host), isTrue);
    });

    test('and returns the same result once done', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      final first = await flow.run(signer);
      expect(await flow.run(signer), same(first));
      expect(signer.signed, hasLength(2));
    });
  });

  group('writeFiles', () {
    test('stores a batch as one quilt with two approvals', () async {
      final files = [
        QuiltBlob(identifier: 'b.txt', contents: Uint8List.fromList([2])),
        QuiltBlob(
          identifier: 'a.jpg',
          contents: Uint8List.fromList([1, 1]),
          tags: const {'type': 'image/jpeg'},
        ),
      ];
      final result = await writer.writeFiles(files, signer: signer, epochs: 3);

      expect(signer.signed, hasLength(2));
      expect(relay.writes, hasLength(1));
      expect(result.files.map((f) => f.identifier), ['a.jpg', 'b.txt']);
      expect(result.file('a.jpg').tags, {'type': 'image/jpeg'});
      for (final file in result.files) {
        final id = parseQuiltPatchId(file.patchId);
        expect(id.quiltId, _blobId);
        expect(id.version, 1);
        expect(id.endIndex, greaterThan(id.startIndex));
      }
    });

    test('needs at least one file', () {
      expect(
        () => writer.writeFilesFlow(const [], epochs: 1),
        throwsArgumentError,
      );
    });

    test('a failed batch continues without paying twice', () async {
      final flow = writer.writeFilesFlow([
        QuiltBlob(identifier: 'a', contents: Uint8List(1)),
      ], epochs: 1);
      relay.failNext = true;
      await expectLater(flow.run(signer), throwsA(isA<UploadRelayError>()));
      await flow.run(signer);
      expect(signer.signed.map((t) => t.description), [
        'Register Walrus blob',
        'Certify Walrus blob',
      ]);
    });
  });

  test('upload and certify refuse to run out of order', () async {
    final flow = writer.writeFlow(data, epochs: 1);
    expect(flow.upload, throwsA(isA<StateError>()));
    expect(flow.certifyTransaction, throwsA(isA<StateError>()));
  });
}

/// Reads the commands of a serialized transaction.
class _Tx {
  _Tx(String json) : _data = jsonDecode(json) as Map<String, dynamic>;

  final Map<String, dynamic> _data;

  List<Map<String, dynamic>> get _commands =>
      (_data['commands'] as List).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> get _inputs =>
      (_data['inputs'] as List).cast<Map<String, dynamic>>();

  List<String> get moveCalls => [
    for (final command in _commands)
      if (command['MoveCall'] case final Map<String, dynamic> call)
        '${call['package']}::${call['module']}::${call['function']}'
            .replaceFirst(RegExp('^0x0+2::'), '0x2::'),
  ];

  List<BigInt> get walIntents => [
    for (final command in _commands)
      if (command[r'$Intent'] case final Map<String, dynamic> intent)
        if ((intent['data'] as Map)['type'].toString().endsWith('::wal::WAL'))
          BigInt.parse((intent['data'] as Map)['balance'] as String),
  ];

  /// Recipients of every TransferObjects, decoded from their pure inputs.
  List<String> get transferredTo => [
    for (final command in _commands)
      if (command['TransferObjects'] case final Map<String, dynamic> transfer)
        _address(transfer['address'] as Map<String, dynamic>),
  ];

  String _address(Map<String, dynamic> argument) {
    final input = _inputs[argument['Input'] as int];
    final bytes = base64Decode((input['Pure'] as Map)['bytes'] as String);
    return '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

class _FakeEncoder extends BlobEncoder {
  @override
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards) async =>
      BlobMetadata(
        blobId: 'M4hsZGQ1oCktdzegB6HnI1Mx0p2v6V1mtJmzv1FwUMg',
        rootHash: Uint8List(32),
        unencodedLength: data.length,
        encodingType: 1,
        nonce: Uint8List(32),
        blobDigest: Uint8List(32),
      );
}

class _FakeSigner implements WalrusTransactionSigner {
  _FakeSigner(this.address);

  @override
  final String address;

  final signed = <WalletTransaction>[];
  bool declineNext = false;
  int? declineAfter;

  @override
  Future<String> signAndExecute(WalletTransaction transaction) async {
    signed.add(transaction);
    if (declineNext || declineAfter == signed.length - 1) {
      declineNext = false;
      declineAfter = null;
      throw StateError('You cancelled the request in the wallet.');
    }
    return transaction.description.startsWith('Register')
        ? 'register-digest'
        : 'certify-digest';
  }
}

class _FakeRelay implements UploadRelayClient {
  UploadRelayTipConfig? tip = UploadRelayTipConfig(
    address: _relayAddress,
    kind: ConstTipStrategy(amount: BigInt.from(105)),
  );
  bool failNext = false;
  final writes = <Map<String, Object?>>[];

  @override
  String get host => 'https://relay.test';

  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  void Function(Object error)? get onError => null;

  @override
  void close() {}

  @override
  Future<UploadRelayTipConfig?> tipConfig() async => tip;

  @override
  Future<UploadRelayWriteResult> writeBlob({
    required String blobId,
    required Uint8List blob,
    required Uint8List nonce,
    required String txDigest,
    required String blobObjectId,
    required bool deletable,
    bool requiresTip = false,
    String? encodingType,
  }) async {
    if (failNext) {
      failNext = false;
      throw UploadRelayError(
        statusCode: 503,
        body: 'busy',
        uri: Uri.parse('$host/v1/blob-upload-relay'),
      );
    }
    writes.add({
      'blobObjectId': blobObjectId,
      'txDigest': txDigest,
      'requiresTip': requiresTip,
      'deletable': deletable,
    });
    return UploadRelayWriteResult(
      blobId: blobId,
      certificate: ProtocolMessageCertificate(
        signers: const [0, 1, 2],
        serializedMessage: Uint8List(4),
        signature: Uint8List(96),
      ),
    );
  }
}

class _FakeChain implements WalrusChainReader {
  BigInt wal = BigInt.from(10).pow(12);
  int createdFailures = 0;

  @override
  SuiGrpcClient get sui => throw UnimplementedError();

  @override
  WalrusPackageConfig get packageConfig => testnetWalrusPackageConfig;

  @override
  String get walCoinType => _walType;

  @override
  Duration get cacheFor => Duration.zero;

  @override
  void reset() {}

  @override
  Future<WalrusSystemSnapshot> system() async => _snapshot;

  @override
  Future<WalrusWalletBalances> balances(String owner) async =>
      WalrusWalletBalances(sui: BigInt.from(10).pow(12), wal: wal);

  @override
  Future<String> serializeForWallet(Transaction tx, String sender) async {
    tx.setSender(sender);
    return tx.toJson();
  }

  @override
  Future<List<String>> createdObjects(
    String digest, {
    required String type,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (createdFailures > 0) {
      createdFailures--;
      throw const WalrusClientError('Transaction not found yet');
    }
    expect(type, _snapshot.blobType);
    return [_blobObject];
  }

  @override
  Future<void> waitForSuccess(
    String digest, {
    Duration timeout = const Duration(seconds: 60),
  }) async {}

  @override
  Future<WalrusBlobObject> blobObject(String objectId) async =>
      WalrusBlobObject(
        objectId: objectId,
        blobId: _blobId,
        size: 12,
        registeredEpoch: 100,
        certifiedEpoch: 100,
        startEpoch: 100,
        endEpoch: 101,
        deletable: true,
        owner: _owner,
      );
}
