import 'package:dartus/dartus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sui/grpc/proto/google/protobuf/struct.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/object.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/owner.pb.dart' as pb;
import 'package:sui/sui.dart';

void main() {
  pb.Object blob({String? id = '0xab', pb.Owner_OwnerKind? kind}) => pb.Object(
    objectId: id,
    objectType: '0x1::blob::Blob',
    owner: pb.Owner(kind: kind, address: '0xcafe'),
    json: pb.Value()
      ..mergeFromProto3Json({
        'blob_id': '1',
        'size': '3',
        'registered_epoch': 10,
        'certified_epoch': null,
        'deletable': true,
        'storage': {'start_epoch': 10, 'end_epoch': 12},
      }),
  );

  for (final kind in pb.Owner_OwnerKind.values) {
    test('blob owner only exposes an address for ${kind.name}', () async {
      final result = await _BlobReader(blob(kind: kind)).blobObject('0xab');
      expect(
        result.owner,
        kind == pb.Owner_OwnerKind.ADDRESS ? '0xcafe' : null,
      );
    });
  }

  test('missing owner kind is not treated as address ownership', () async {
    expect((await _BlobReader(blob()).blobObject('0xab')).owner, isNull);
  });

  test('mismatched or missing object ID is refused', () async {
    for (final id in ['0xcd', null]) {
      await expectLater(
        _BlobReader(blob(id: id)).blobObject('0xab'),
        throwsA(isA<WalrusClientError>()),
      );
    }
  });

  test(
    'short and fully padded representations identify the same object',
    () async {
      final reader = _BlobReader(blob(id: normalizeSuiAddress('0xab')));
      expect((await reader.blobObject('0xab')).objectId, '0xab');
    },
  );
}

class _BlobReader extends WalrusChainReader {
  _BlobReader(pb.Object object)
    : super(
        sui: _ObjectClient(object),
        packageConfig: WalrusNetwork.testnet.packageConfig,
        walCoinType: WalrusNetwork.testnet.walCoinType,
      );

  @override
  Future<WalrusSystemSnapshot> system() async => WalrusSystemSnapshot(
    epoch: 10,
    nShards: 1000,
    committeeSize: 100,
    storagePricePerUnit: BigInt.one,
    writePricePerUnit: BigInt.one,
    packageId: '0x1',
    typeOriginPackageId: '0x1',
    maxEpochsAhead: 53,
  );
}

class _ObjectClient implements SuiGrpcClient {
  _ObjectClient(this.object);
  final pb.Object object;

  @override
  Future<pb.Object> getObject(
    String objectId, {
    List<String>? readMask,
  }) async => object;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
