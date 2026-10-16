import 'dart:async';
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
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionNotCommitted>()),
      );
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
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionNotCommitted>()),
      );
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
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionNotCommitted>()),
      );
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
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionNotCommitted>()),
      );

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

    test('a batch estimate prices the laid-out quilt', () async {
      final files = [
        QuiltBlob(identifier: 'a', contents: Uint8List(10)),
        QuiltBlob(identifier: 'b', contents: Uint8List(20)),
      ];
      final quilt = encodeQuilt(blobs: files, numShards: 1000).quilt;
      final batch = await writer.estimateFiles(files, epochs: 2);
      final single = await writer.estimate(size: quilt.length, epochs: 2);
      expect(batch.cost.total, single.cost.total);
      expect(batch.relayTip, single.relayTip);
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

  test('close leaves a caller-owned relay open', () {
    writer.close();
    expect(relay.closes, 0);
  });

  group('payment safety', () {
    test(
      'a caller tip budget is enforced for estimates and before signing',
      () async {
        final bounded = WalrusWriter(
          network: WalrusNetwork.testnet,
          chain: chain,
          relay: relay,
          encoder: _FakeEncoder(),
          maxRelayTip: BigInt.from(200),
        );
        expect(
          (await bounded.estimate(size: data.length, epochs: 1)).relayTip,
          BigInt.from(105),
        );
        // The relay changes its demand after the displayed estimate.
        relay.tip = UploadRelayTipConfig(
          address: _relayAddress,
          kind: ConstTipStrategy(amount: BigInt.from(1000000000)),
        );
        await expectLater(
          bounded.estimate(size: data.length, epochs: 1),
          throwsA(isA<WalrusClientError>()),
        );
        await expectLater(
          bounded.write(data, signer: signer, epochs: 1),
          throwsA(isA<WalrusClientError>()),
        );
        expect(signer.signed, isEmpty);
        expect(relay.writes, isEmpty);
      },
    );

    test(
      'negative tip budgets are invalid and a zero budget accepts free relays',
      () async {
        expect(
          () => WalrusWriter(
            network: WalrusNetwork.testnet,
            chain: chain,
            relay: relay,
            maxRelayTip: BigInt.from(-1),
          ),
          throwsArgumentError,
        );
        final free = WalrusWriter(
          network: WalrusNetwork.testnet,
          chain: chain,
          relay: relay,
          encoder: _FakeEncoder(),
          maxRelayTip: BigInt.zero,
        );
        relay.tip = null;
        await free.write(data, signer: signer, epochs: 1);
        expect(signer.signed, hasLength(2));
      },
    );

    test('one in-flight operation per single flow', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      signer.gate = Completer<void>();
      signer.started = Completer<void>();
      final first = flow.run(signer);
      await signer.started!.future;
      await expectLater(flow.run(signer), throwsStateError);
      await expectLater(flow.registerTransaction(_owner), throwsStateError);
      await expectLater(flow.encode(), throwsStateError);
      expect(signer.signed, hasLength(1));
      signer.gate!.complete();
      await first;
      expect(signer.signed, hasLength(2));
      expect(relay.writes, hasLength(1));
    });

    test('one in-flight operation per quilt, including layout', () async {
      final flow = writer.writeFilesFlow([
        QuiltBlob(identifier: 'a', contents: Uint8List(1)),
      ], epochs: 1);
      signer.gate = Completer<void>();
      signer.started = Completer<void>();
      final first = flow.run(signer);
      await expectLater(flow.run(signer), throwsStateError);
      await signer.started!.future;
      await expectLater(flow.blobFlow!.run(signer), throwsStateError);
      signer.gate!.complete();
      await first;
      expect(signer.signed, hasLength(2));
      expect(relay.writes, hasLength(1));
    });

    test(
      'invalid recipients, epochs and permanent storage fail before I/O',
      () {
        expect(
          () => writer.writeFlow(data, epochs: 1, recipient: 'wrong'),
          throwsArgumentError,
        );
        expect(() => writer.writeFlow(data, epochs: 0), throwsArgumentError);
        expect(
          () => writer.writeFlow(data, epochs: 1, deletable: false),
          throwsArgumentError,
        );
        final files = [QuiltBlob(identifier: 'a', contents: Uint8List(1))];
        expect(
          () => writer.writeFilesFlow(files, epochs: 1, recipient: 'wrong'),
          throwsArgumentError,
        );
        expect(
          () => writer.writeFilesFlow(files, epochs: 1, deletable: false),
          throwsArgumentError,
        );
        expect(
          () => writer.writeFilesFlow([files.first, files.first], epochs: 1),
          throwsArgumentError,
        );
        expect(chain.systemCalls, 0);
        expect(signer.signed, isEmpty);
      },
    );

    test('invalid signer fails before chain or relay calls', () async {
      final flow = writer.writeFlow(data, epochs: 1);
      await expectLater(flow.run(_FakeSigner('wrong')), throwsArgumentError);
      final batch = writer.writeFilesFlow([
        QuiltBlob(identifier: 'a', contents: Uint8List(1)),
      ], epochs: 1);
      await expectLater(batch.run(_FakeSigner('wrong')), throwsArgumentError);
      expect(chain.systemCalls, 0);
    });

    test('bytes are snapshotted before encoding or payment', () async {
      final original = Uint8List.fromList([1, 2, 3]);
      final flow = writer.writeFlow(original, epochs: 1);
      original[0] = 9;
      expect(() => flow.data[0] = 8, throwsUnsupportedError);
      await flow.run(signer);
      expect(relay.writes.single['blob'], [1, 2, 3]);
    });

    test('quilt files and tags are snapshotted before layout', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final tags = {'type': 'original'};
      final flow = writer.writeFilesFlow([
        QuiltBlob(identifier: 'a', contents: bytes, tags: tags),
      ], epochs: 1);
      final expected = encodeQuilt(blobs: flow.files, numShards: 1000).quilt;
      bytes[0] = 9;
      tags['type'] = 'changed';
      await flow.run(signer);
      expect(relay.writes.single['blob'], expected);
      expect(flow.files.single.tags, {'type': 'original'});
    });

    test(
      'unknown registration blocks a second payment until digest recovery',
      () async {
        final flow = writer.writeFlow(data, epochs: 1);
        signer.errorNext = TimeoutException('response lost after execution');
        await expectLater(
          flow.run(signer),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        expect(flow.unknownOutcome, isNotNull);
        await expectLater(
          flow.run(signer),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        await expectLater(
          flow.registerTransaction(_owner),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        expect(signer.signed, hasLength(1));
        await flow.registered('register-digest');
        expect(flow.unknownOutcome, isNull);
        await flow.run(signer);
        expect(signer.signed, hasLength(2));
      },
    );

    test('unknown quilt registration keeps its original flow', () async {
      final flow = writer.writeFilesFlow([
        QuiltBlob(identifier: 'a', contents: Uint8List(1)),
      ], epochs: 1);
      signer.errorNext = TimeoutException('response lost');
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionOutcomeUnknown>()),
      );
      final original = flow.blobFlow;
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionOutcomeUnknown>()),
      );
      expect(flow.blobFlow, same(original));
      expect(signer.signed, hasLength(1));
    });

    test(
      'a caller can explicitly resolve a definitely uncommitted request',
      () async {
        final flow = writer.writeFlow(data, epochs: 1);
        signer.errorNext = TimeoutException('unknown initially');
        await expectLater(
          flow.run(signer),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        flow.confirmNotCommitted();
        await flow.run(signer);
        expect(signer.signed, hasLength(3));
      },
    );

    test(
      'unknown certification retains payment and blocks resubmission',
      () async {
        final flow = writer.writeFlow(data, epochs: 1);
        signer.errorNext = TimeoutException('certification response lost');
        signer.errorAfter = 1;
        await expectLater(
          flow.run(signer),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        await expectLater(
          flow.run(signer),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        await expectLater(flow.registered('register-digest'), throwsStateError);
        expect(signer.signed, hasLength(2));
        await flow.certified('certify-digest');
        await flow.run(signer);
        expect(signer.signed, hasLength(2));
        expect(relay.writes, hasLength(1));
      },
    );

    test(
      'confirmed failed registration can retry without getting stuck',
      () async {
        chain.failRegistration = true;
        final flow = writer.writeFlow(data, epochs: 1);
        await expectLater(
          flow.run(signer),
          throwsA(isA<WalrusTransactionExecutionFailed>()),
        );
        expect(flow.registerDigest, isNull);
        await flow.run(signer);
        expect(signer.signed, hasLength(3));
      },
    );

    test('confirmed failed certification retries only certification', () async {
      chain.failCertification = true;
      final flow = writer.writeFlow(data, epochs: 1);
      await expectLater(
        flow.run(signer),
        throwsA(isA<WalrusTransactionExecutionFailed>()),
      );
      expect(flow.certifyDigest, isNull);
      await flow.run(signer);
      expect(
        signer.signed.where((t) => t.description.startsWith('Register')),
        hasLength(1),
      );
      expect(relay.writes, hasLength(1));
    });

    test(
      'wallet rejection classifier does not classify other errors',
      () async {
        final adapter = WalletTransactionSigner(
          address: _owner,
          execute: (_) async => throw StateError('declined'),
          isDefinitelyNotCommitted: (error) =>
              error is StateError && error.message == 'declined',
        );
        final flow = writer.writeFlow(data, epochs: 1);
        await expectLater(flow.run(adapter), throwsStateError);
        expect(flow.unknownOutcome, isNull);
        await flow.run(signer);
        expect(signer.signed, hasLength(2));
      },
    );

    test(
      'a broken rejection classifier still blocks an uncertain retry',
      () async {
        var submissions = 0;
        final adapter = WalletTransactionSigner(
          address: _owner,
          execute: (_) async {
            submissions++;
            throw TimeoutException('response lost');
          },
          isDefinitelyNotCommitted: (_) =>
              throw StateError('classifier failed'),
        );
        final flow = writer.writeFlow(data, epochs: 1);
        await expectLater(
          flow.run(adapter),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        await expectLater(
          flow.run(adapter),
          throwsA(isA<WalrusTransactionOutcomeUnknown>()),
        );
        expect(submissions, 1);
      },
    );
  });

  group('chain receipt validation', () {
    for (final field in [
      'id',
      'blobId',
      'size',
      'owner',
      'deletable',
      'epochs',
    ]) {
      for (final afterCertification in [false, true]) {
        test(
          '$field mismatch ${afterCertification ? 'after certification' : 'after registration'} is refused',
          () async {
            chain.transformBlob = (blob) =>
                chain.didCertify == afterCertification
                ? _changedBlob(blob, field)
                : blob;
            final flow = writer.writeFlow(data, epochs: 1);
            await expectLater(
              flow.run(signer),
              throwsA(isA<WalrusClientError>()),
            );
            expect(flow.result, isNull);
            if (!afterCertification) expect(relay.writes, isEmpty);
            final signed = signer.signed.length;
            await expectLater(
              flow.run(signer),
              throwsA(isA<WalrusClientError>()),
            );
            expect(signer.signed, hasLength(signed));
          },
        );
      }
    }
  });
}

WalrusBlobObject _changedBlob(WalrusBlobObject blob, String field) =>
    WalrusBlobObject(
      objectId: field == 'id' ? _host : blob.objectId,
      blobId: field == 'blobId' ? 'other-blob' : blob.blobId,
      size: field == 'size' ? blob.size + 1 : blob.size,
      registeredEpoch: blob.registeredEpoch,
      certifiedEpoch: blob.certifiedEpoch,
      startEpoch: blob.startEpoch,
      endEpoch: field == 'epochs' ? blob.endEpoch + 1 : blob.endEpoch,
      deletable: field == 'deletable' ? !blob.deletable : blob.deletable,
      owner: field == 'owner' ? _host : blob.owner,
    );

/// Reads the commands of a serialized transaction.
class _Tx {
  _Tx(String json) : _data = jsonDecode(json) as Map<String, dynamic>;

  final Map<String, dynamic> _data;

  List<Map<String, dynamic>> get _commands =>
      (_data['commands'] as List).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> get _inputs =>
      (_data['inputs'] as List).cast<Map<String, dynamic>>();

  int callInteger(String function, int argumentIndex) {
    final call = _commands
        .map((c) => c['MoveCall'])
        .whereType<Map<String, dynamic>>()
        .firstWhere((c) => c['function'] == function);
    final arg = (call['arguments'] as List)[argumentIndex] as Map;
    final input = _inputs[arg['Input'] as int];
    final bytes = base64Decode((input['Pure'] as Map)['bytes'] as String);
    var value = 0;
    for (var i = bytes.length - 1; i >= 0; i--) {
      value = value * 256 + bytes[i];
    }
    return value;
  }

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
  Completer<void>? gate;
  Completer<void>? started;
  Object? errorNext;
  int? errorAfter;

  @override
  Future<String> signAndExecute(WalletTransaction transaction) async {
    signed.add(transaction);
    if (started != null && !started!.isCompleted) started!.complete();
    if (gate != null) await gate!.future;
    if (errorNext != null &&
        (errorAfter == null || errorAfter == signed.length - 1)) {
      final error = errorNext!;
      errorNext = null;
      throw error;
    }
    if (declineNext || declineAfter == signed.length - 1) {
      declineNext = false;
      declineAfter = null;
      throw const WalrusTransactionNotCommitted(
        'You cancelled the request in the wallet.',
      );
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
  int closes = 0;
  final writes = <Map<String, Object?>>[];

  @override
  String get host => 'https://relay.test';

  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  void Function(Object error)? get onError => null;

  @override
  void close() => closes++;

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
      'blob': Uint8List.fromList(blob),
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
  int systemCalls = 0;
  int size = 12;
  int epochs = 1;
  String owner = _owner;
  String finalOwner = _owner;
  bool didCertify = false;
  bool failRegistration = false;
  bool failCertification = false;
  WalrusBlobObject Function(WalrusBlobObject)? transformBlob;

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
  Future<WalrusSystemSnapshot> system() async {
    systemCalls++;
    return _snapshot;
  }

  @override
  Future<WalrusWalletBalances> balances(String owner) async =>
      WalrusWalletBalances(sui: BigInt.from(10).pow(12), wal: wal);

  @override
  Future<String> serializeForWallet(Transaction tx, String sender) async {
    tx.setSender(sender);
    final json = tx.toJson();
    final commands = _Tx(json);
    if (commands.moveCalls.any((call) => call.endsWith('::register_blob'))) {
      size = commands.callInteger('register_blob', 4);
      epochs = commands.callInteger('reserve_space', 2);
      owner = sender;
      finalOwner = sender;
    } else if (commands.transferredTo.isNotEmpty) {
      finalOwner = commands.transferredTo.last;
    }
    return json;
  }

  @override
  Future<List<String>> createdObjects(
    String digest, {
    required String type,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (failRegistration) {
      failRegistration = false;
      throw WalrusTransactionExecutionFailed(digest, 'registration failed');
    }
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
  }) async {
    if (failCertification) {
      failCertification = false;
      throw WalrusTransactionExecutionFailed(digest, 'certification failed');
    }
    didCertify = true;
  }

  @override
  Future<WalrusBlobObject> blobObject(String objectId) async {
    final blob = WalrusBlobObject(
      objectId: objectId,
      blobId: _blobId,
      size: size,
      registeredEpoch: 100,
      certifiedEpoch: didCertify ? 100 : null,
      startEpoch: 100,
      endEpoch: 100 + epochs,
      deletable: true,
      owner: didCertify ? finalOwner : owner,
    );
    return transformBlob?.call(blob) ?? blob;
  }
}
