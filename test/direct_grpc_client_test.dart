@TestOn('vm')
@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/direct.dart';
import 'package:dartus/src/chain/direct_grpc_client.dart';
import 'package:dartus/src/chain/write_flow_verification.dart';
import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/object.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/state_service.pb.dart' as pb;
import 'package:sui/sui.dart';
import 'package:test/test.dart';

const _type = '0xaa::blob::Blob';
final _blobId = base64UrlEncode(Uint8List(32)).replaceAll('=', '');

class _Grpc extends SuiGrpcClient {
  _Grpc() : super(network: SuiNetwork.testnet, endpoint: 'http://127.0.0.1:1');
  Map<String, dynamic> fields = {
    'blob_id': '0',
    'size': '10',
    'deletable': true,
    'certified_epoch': 7,
  };
  String objectType = _type;
  String owner = '0x1';
  Object? failure;
  List<int>? key;
  String? keyType;
  Uint8List? pageToken;
  Map<String, dynamic> status = {'success': true};
  @override
  Future<pb.Object> getObject(String objectId, {List<String>? readMask}) async {
    if (failure != null) throw failure!;
    return pb.Object()..mergeFromProto3Json({
      'objectId': objectId,
      'version': '10',
      'digest': 'fixture',
      'objectType': objectType,
      'owner': {'kind': 'ADDRESS', 'address': owner},
      'json': fields,
    });
  }

  @override
  Future<pb.Object> getDynamicFieldObject(
    String parentId,
    String nameType,
    Uint8List nameBcs, {
    List<String>? readMask,
  }) {
    key = nameBcs;
    keyType = nameType;
    return getObject('0x9', readMask: readMask);
  }

  @override
  Future<pb.ListOwnedObjectsResponse> listOwnedObjects(
    String owner, {
    int? pageSize,
    Uint8List? pageToken,
    String? objectType,
    List<String>? readMask,
  }) async {
    this.pageToken = pageToken;
    return pb.ListOwnedObjectsResponse(
      objects: [await getObject('0xb')],
      nextPageToken: [3, 4],
    );
  }

  @override
  Future<pb.ExecutedTransaction> waitForTransaction(
    String digest, {
    Duration timeout = const Duration(seconds: 60),
    Duration pollInterval = const Duration(milliseconds: 500),
    List<String>? readMask,
  }) async => pb.ExecutedTransaction()
    ..mergeFromProto3Json({
      'digest': digest,
      'effects': {
        'status': status,
        'changedObjects': [
          {
            'objectId': '0xc',
            'objectType': '0x2::coin::Coin<0x2::sui::SUI>',
            'idOperation': 'CREATED',
          },
          {'objectId': '0xb', 'objectType': _type, 'idOperation': 'CREATED'},
        ],
      },
    });
}

class _Reader extends SystemStateReader {
  _Reader(SuiClient client)
    : super(suiClient: client, config: testnetWalrusPackageConfig);
  @override
  Future<String> getPackageId() async => '0xaa';
  @override
  Future<WalrusSystemState> systemState() async => WalrusSystemState(
    nShards: 4,
    epoch: 7,
    committeeSize: 4,
    storagePricePerUnitSize: BigInt.one,
    writePricePerUnitSize: BigInt.one,
    totalCapacitySize: BigInt.one,
    usedCapacitySize: BigInt.zero,
  );
}

class _Relay extends UploadRelayClient {
  _Relay() : super(host: 'http://127.0.0.1:1');
  int uploads = 0;
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
    uploads++;
    return UploadRelayWriteResult(
      blobId: blobId,
      certificate: ProtocolMessageCertificate(
        signers: [0, 1, 2],
        serializedMessage: Uint8List(1),
        signature: Uint8List(96),
      ),
    );
  }
}

BlobMetadata _metadata(int size) => BlobMetadata(
  blobId: _blobId,
  rootHash: Uint8List(32),
  unencodedLength: size,
  encodingType: 1,
  nonce: Uint8List(32),
  blobDigest: Uint8List(32),
);

class _Encoder extends BlobEncoder {
  _Encoder(this.grpc);
  final _Grpc grpc;
  @override
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards) async {
    grpc.fields['size'] = data.length.toString();
    return _metadata(data.length);
  }
}

class _DirectEncoder extends WalrusBlobEncoder {
  @override
  EncodedBlob encodeBlob(Uint8List data, int numShards) => EncodedBlob(
    blobId: _blobId,
    blobIdBytes: Uint8List(32),
    metadataBytes: Uint8List(1),
    rootHash: Uint8List(32),
    unencodedLength: data.length,
    primarySlivers: const [],
    secondarySlivers: const [],
  );
  @override
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards) async =>
      _metadata(data.length);
}

class _UninitializedBls implements BlsProvider {
  @override
  bool verify(Uint8List signature, Uint8List publicKey, Uint8List message) =>
      throw StateError('BLS runtime is not initialized');
  @override
  Uint8List aggregate(List<Uint8List> signatures) =>
      throw StateError('not initialized');
  @override
  bool verifyAggregate(
    List<Uint8List> publicKeys,
    Uint8List message,
    Uint8List aggregateSignature,
  ) => throw StateError('not initialized');
}

void main() {
  late _Grpc grpc;
  late DirectGrpcClient client;
  setUp(() {
    grpc = _Grpc();
    client = DirectGrpcClient(grpc);
  });
  Future<void> verify({bool certified = true}) => verifyFlowBlob(
    client: client,
    objectId: '0xb',
    blobId: _blobId,
    blobType: _type,
    size: 10,
    deletable: true,
    owner: '0x1',
    certified: certified,
    digest: 'fixture',
  );

  test('native preset uses the gRPC bridge', () {
    final native = WalrusDirectClient.fromNetwork(
      network: WalrusNetwork.testnet,
      grpcClient: grpc,
    );
    addTearDown(native.close);
    expect(native.suiClient, isA<DirectGrpcClient>());
  });
  test(
    'normalizes protobuf nested integral numbers and object owner',
    () async {
      grpc.fields = {
        'value': {
          'epoch': 7,
          'members': [0, 3],
        },
        'large': '18446744073709551615',
      };
      final object = (await client.getObject('0xb')).data!;
      expect((object.content!.fields as Map)['value'], {
        'epoch': 7,
        'members': [0, 3],
      });
      expect(
        ((object.content!.fields as Map)['value'] as Map)['epoch'],
        isA<int>(),
      );
      expect(object.owner!.addressOwner, '0x1');
    },
  );
  test('dynamic u64 key is exact little endian BCS', () async {
    await client.getDynamicFieldObject('0x1', 'u64', '258');
    expect(grpc.key, [2, 1, 0, 0, 0, 0, 0, 0]);
    expect(
      () => client.getDynamicFieldObject('0x1', 'u64', '-1'),
      throwsArgumentError,
    );
  });
  test(
    'metadata vector key and owned-object cursor survive translation',
    () async {
      await client.getDynamicFieldByBcs(
        '0x1',
        'vector<u8>',
        Uint8List.fromList([8, ...'metadata'.codeUnits]),
      );
      expect(grpc.key, [8, ...'metadata'.codeUnits]);
      final page = await client.getOwnedObjects(
        '0x1',
        cursor: base64Encode([1, 2]),
        filter: {'StructType': _type},
      );
      expect(grpc.pageToken, [1, 2]);
      expect(page.nextCursor, base64Encode([3, 4]));
      expect(page.hasNextPage, isTrue);
    },
  );
  test(
    'transaction keeps all typed created objects without inventing gas refs',
    () async {
      final tx = await client.waitForTransaction('digest');
      expect(tx.objectChanges!.map((c) => c['objectId']), ['0xc', '0xb']);
      expect(tx.effects, isNull);
      expect(tx.confirmedLocalExecution, isTrue);
    },
  );
  for (final status in [
    <String, dynamic>{},
    {'success': false},
  ]) {
    test(
      'missing or failed execution status cannot look successful: $status',
      () async {
        grpc.status = status;
        await expectLater(
          client.waitForTransaction('digest'),
          throwsA(isA<WalrusClientError>()),
        );
      },
    );
  }
  test('read errors propagate rather than becoming missing blobs', () async {
    grpc.failure = StateError('transport unavailable');
    final native = WalrusDirectClient.fromNetwork(
      network: WalrusNetwork.testnet,
      grpcClient: grpc,
    );
    addTearDown(native.close);
    await expectLater(
      native.getBlobObjectInfo(objectId: '0xb'),
      throwsStateError,
    );
  });
  test('valid certified chain object passes exact flow verification', () async {
    await verify();
  });
  test(
    'uncertified scalar and legacy empty Option fail finalization',
    () async {
      for (final epoch in [
        null,
        {'vec': <int>[]},
        {
          'fields': {'vec': <int>[]},
        },
      ]) {
        grpc.fields['certified_epoch'] = epoch;
        await verify(certified: false);
        await expectLater(verify(), throwsA(isA<WalrusClientError>()));
      }
      grpc.fields['certified_epoch'] = {
        'fields': {
          'vec': [7],
        },
      };
      await verify();
    },
  );
  test('same Blob suffix from another package is rejected', () async {
    grpc.objectType = '0xbb::blob::Blob';
    await expectLater(verify(), throwsA(isA<WalrusClientError>()));
  });
  test('wrong blob ID, length, persistence or owner is rejected', () async {
    for (final entry in {
      'blob_id': '1',
      'size': '11',
      'deletable': false,
    }.entries) {
      final old = grpc.fields[entry.key];
      grpc.fields[entry.key] = entry.value;
      await expectLater(verify(), throwsA(isA<WalrusClientError>()));
      grpc.fields[entry.key] = old;
    }
    grpc.owner = '0x2';
    await expectLater(verify(), throwsA(isA<WalrusClientError>()));
  });
  for (final filesMode in [false, true]) {
    test(
      'actual ${filesMode ? 'files' : 'blob'} flow verifies registration and executed certification',
      () async {
        final relay = _Relay();
        addTearDown(relay.close);
        final builder = WalrusTransactionBuilder(
          packageConfig: testnetWalrusPackageConfig,
          walrusPackageId: '0xaa',
        );
        final reader = _Reader(client);
        grpc.fields['certified_epoch'] = null;
        final dynamic flow = filesMode
            ? WriteFilesFlow(
                files: [
                  WalrusFile.from(contents: Uint8List(10), identifier: 'file'),
                ],
                txBuilder: builder,
                relayClient: relay,
                encoder: _Encoder(grpc),
                stateReader: reader,
                suiClient: client,
              )
            : WriteBlobFlow(
                blob: Uint8List(10),
                txBuilder: builder,
                relayClient: relay,
                precomputedMetadata: _metadata(10),
                stateReader: reader,
                suiClient: client,
              );
        await flow.encode();
        if (filesMode) {
          await flow.register(
            WriteFilesFlowRegisterOptions(
              epochs: 1,
              owner: '0x1',
              deletable: true,
              walCoinObjectId: '0x2',
              walType: '0xaa::wal::WAL',
              storageCost: BigInt.one,
              writeCost: BigInt.one,
              encodedSize: 100,
            ),
          );
        } else {
          await flow.register(
            WriteBlobFlowRegisterOptions(
              epochs: 1,
              owner: '0x1',
              deletable: true,
              walCoinObjectId: '0x2',
              walType: '0xaa::wal::WAL',
              storageCost: BigInt.one,
              writeCost: BigInt.one,
              encodedSize: 100,
            ),
          );
        }
        grpc.fields['blob_id'] = '1';
        await expectLater(
          flow.upload(
            const WriteBlobFlowUploadOptions(
              digest: 'registered',
              blobObjectId: '0xb',
            ),
          ),
          throwsA(isA<WalrusClientError>()),
        );
        expect(relay.uploads, 0);
        grpc.fields['blob_id'] = '0';
        await flow.upload(
          const WriteBlobFlowUploadOptions(
            digest: 'registered',
            blobObjectId: '0xb',
          ),
        );
        expect(relay.uploads, 1);
        flow.certify(); // Building this unsigned transaction cannot prove storage.
        await expectLater(
          filesMode ? flow.listFiles() : flow.getBlob(),
          throwsA(isA<WalrusClientError>()),
        );
        grpc.fields['certified_epoch'] = 7;
        final result = filesMode
            ? await flow.listFiles(certifyDigest: 'certified')
            : await flow.getBlob(certifyDigest: 'certified');
        if (filesMode) {
          expect((result as List).single.blobId, _blobId);
        } else {
          expect((result as WriteBlobResult).certifyDigest, 'certified');
        }
      },
    );
  }
  for (final filesMode in [false, true]) {
    for (final provider in <BlsProvider?>[null, _UninitializedBls()]) {
      test(
        'standalone ${filesMode ? 'files' : 'blob'} register rejects ${provider == null ? 'missing' : 'uninitialized'} BLS before chain I/O',
        () async {
          grpc.failure = StateError('unexpected chain I/O');
          final native = WalrusDirectClient(
            network: WalrusNetwork.testnet,
            grpcClient: grpc,
            blsProvider: provider,
          );
          addTearDown(native.close);
          final builder = WalrusTransactionBuilder(
            packageConfig: testnetWalrusPackageConfig,
            walrusPackageId: '0xaa',
          );
          final dynamic flow = filesMode
              ? WriteFilesFlow(
                  files: [
                    WalrusFile.from(
                      contents: Uint8List(10),
                      identifier: 'file',
                    ),
                  ],
                  txBuilder: builder,
                  encoder: _DirectEncoder(),
                  directClient: native,
                  suiClient: client,
                )
              : WriteBlobFlow(
                  blob: Uint8List(10),
                  txBuilder: builder,
                  encoder: _DirectEncoder(),
                  directClient: native,
                  suiClient: client,
                );
          await flow.encode();
          final options = filesMode
              ? WriteFilesFlowRegisterOptions(
                  epochs: 1,
                  owner: '0x1',
                  deletable: true,
                )
              : WriteBlobFlowRegisterOptions(
                  epochs: 1,
                  owner: '0x1',
                  deletable: true,
                );
          await expectLater(
            flow.register(options),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'readiness error',
                anyOf(
                  contains('initialized BlsProvider'),
                  contains('BLS runtime is not initialized'),
                ),
              ),
            ),
          );
        },
      );
    }
  }
}
