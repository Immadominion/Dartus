import 'dart:convert';
import 'dart:typed_data';

import 'package:sui/grpc/proto/sui/rpc/v2/effects.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/object.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/owner.pb.dart' as pb;
import 'package:sui/sui.dart';
import 'package:sui/types/normalized.dart';

import '../errors/walrus_errors.dart';
import 'walrus_grpc_transaction.dart';

/// gRPC transport for the native client's existing Sui response models.
///
/// This bridge implements the chain operations used by Dartus, including
/// created-object changes (needed to identify a registered Blob). Its inherited
/// JSON-RPC endpoint is deliberately unusable: no operation may silently fall
/// back to the retired public JSON-RPC service.
class DirectGrpcClient extends SuiClient {
  DirectGrpcClient(this.grpc) : super('https://json-rpc-disabled.invalid');

  final SuiGrpcClient grpc;

  GrpcBuilderAdapter get _builder =>
      WalrusGrpcBuilderAdapter(grpc.core as GrpcCoreClient);

  @override
  Future<ResolvedGasData?> resolveGasData(TransactionBlockDataBuilder data) =>
      _builder.resolveGasData(data);

  @override
  Future<CoinBalanceBreakdown> getBalanceBreakdown(
    String owner,
    String coinType,
  ) => _builder.getBalanceBreakdown(owner, coinType);

  @override
  Future<BigInt> getReferenceGasPrice() async =>
      BigInt.parse((await grpc.getReferenceGasPrice()).toString());

  @override
  Future<dynamic> getProtocolConfig([String? version]) async => null;

  @override
  Future<SuiMoveNormalizedFunction> getNormalizedMoveFunction(
    String packageId,
    String moduleName,
    String functionName,
  ) => _builder.getNormalizedMoveFunction(packageId, moduleName, functionName);

  @override
  Future<PaginatedCoins> getCoins(
    String owner, {
    String? coinType,
    String? cursor,
    int? limit,
  }) async {
    final page = await grpc.listCoins(
      owner,
      coinType: coinType ?? '0x2::sui::SUI',
      cursor: cursor == null ? null : base64Decode(cursor),
      limit: limit,
    );
    return PaginatedCoins(
      [
        for (final coin in page.coins)
          CoinStruct(
            coin.coinType,
            coin.coinObjectId,
            coin.version.toInt(),
            coin.digest,
            coin.balance.toString(),
            '',
          ),
      ],
      page.cursor,
      page.hasNextPage,
    );
  }

  @override
  Future<SuiObjectResponse> getObject(
    String objectId, {
    SuiObjectDataOptions? options,
  }) async {
    try {
      return _objectResponse(await grpc.getObject(objectId, readMask: _mask));
    } on GrpcWebException catch (error) {
      if (error.status != 5) rethrow;
      return SuiObjectResponse.fromJson({
        'error': {'code': 'notExists', 'object_id': objectId},
      });
    }
  }

  @override
  Future<List<SuiObjectResponse>> multiGetObjects(
    List<String> objectIds, {
    SuiObjectDataOptions? options,
  }) async {
    final objects = await grpc.getObjects(objectIds, readMask: _mask);
    return [
      for (var i = 0; i < objects.length; i++)
        if (!objects[i].hasError())
          _objectResponse(objects[i].object)
        else
          throw WalrusClientError(
            'Cannot read object ${objectIds[i]}: ${objects[i].error.message}',
          ),
    ];
  }

  @override
  Future<PaginatedObjectsResponse> getOwnedObjects(
    String address, {
    SuiObjectDataOptions? options,
    int limit = 50,
    String? cursor,
    Map<dynamic, dynamic>? filter,
  }) async {
    if (filter != null &&
        (filter.length != 1 || filter['StructType'] is! String)) {
      throw ArgumentError('DirectGrpcClient supports a StructType filter');
    }
    final page = await grpc.listOwnedObjects(
      address,
      objectType: filter?['StructType'] as String?,
      pageSize: limit,
      pageToken: cursor == null ? null : base64Decode(cursor),
      readMask: _mask,
    );
    return PaginatedObjectsResponse(
      page.objects.map(_objectResponse).toList(),
      page.nextPageToken.isEmpty ? '' : base64Encode(page.nextPageToken),
      page.nextPageToken.isNotEmpty,
    );
  }

  @override
  Future<SuiObjectResponse> getDynamicFieldObject(
    String parentObjectId,
    String nameType,
    String nameValue,
  ) {
    if (nameType != 'u64') {
      throw ArgumentError('Use getDynamicFieldByBcs for non-u64 keys');
    }
    var value = BigInt.parse(nameValue);
    if (value.isNegative || value.bitLength > 64) {
      throw ArgumentError.value(nameValue, 'nameValue', 'Must fit u64');
    }
    final bytes = Uint8List(8);
    for (var i = 0; i < bytes.length; i++, value >>= 8) {
      bytes[i] = (value & BigInt.from(255)).toInt();
    }
    return getDynamicFieldByBcs(parentObjectId, nameType, bytes);
  }

  Future<SuiObjectResponse> getDynamicFieldByBcs(
    String parentId,
    String nameType,
    Uint8List nameBcs,
  ) async => _objectResponse(
    await grpc.getDynamicFieldObject(
      parentId,
      nameType,
      nameBcs,
      readMask: _mask,
    ),
  );

  @override
  Future<SuiTransactionBlockResponse> signAndExecuteTransactionBlock(
    SuiAccount signer,
    Transaction transaction, {
    BuildOptions? options,
    SuiTransactionBlockResponseOptions? responseOptions,
    ExecuteTransaction requestType = ExecuteTransaction.WaitForEffectsCert,
  }) async {
    final executed = await signAndExecuteWalrusTransaction(
      grpc,
      signer,
      transaction,
      options: options,
    );
    return _transactionResponse(executed);
  }

  @override
  Future<SuiTransactionBlockResponse> waitForTransaction(
    String digest, {
    SuiTransactionBlockResponseOptions? options,
    int timeout = 60000,
    int pollInterval = 2000,
  }) async => _transactionResponse(
    await grpc.waitForTransaction(
      digest,
      timeout: Duration(milliseconds: timeout),
      pollInterval: Duration(milliseconds: pollInterval),
      readMask: const ['digest', 'effects'],
    ),
  );

  static const _mask = [
    'object_id',
    'version',
    'digest',
    'object_type',
    'owner',
    'json',
  ];

  static SuiObjectResponse _objectResponse(pb.Object object) =>
      SuiObjectResponse.fromJson({
        'data': {
          'objectId': object.objectId,
          'version': object.version.toString(),
          'digest': object.digest,
          'type': object.objectType,
          'owner': _owner(object.owner),
          if (object.hasJson())
            'content': {
              'dataType': 'moveObject',
              'type': object.objectType,
              'fields': _legacyJson(object.json.toProto3Json()),
            },
        },
      });

  static Object? _legacyJson(Object? value) => switch (value) {
    final Map<String, dynamic> fields => {
      for (final entry in fields.entries) entry.key: _legacyJson(entry.value),
    },
    final List<dynamic> values => values.map(_legacyJson).toList(),
    final double number
        when number.isFinite && number == number.truncateToDouble() =>
      number.toInt(),
    _ => value,
  };

  static Object _owner(pb.Owner owner) {
    final parsed = SuiOwner.fromProto(owner);
    return switch (parsed.kind) {
      SuiOwnerKind.address => {'AddressOwner': parsed.address},
      SuiOwnerKind.object => {'ObjectOwner': parsed.address},
      SuiOwnerKind.shared => {
        'Shared': {'initial_shared_version': parsed.initialSharedVersion},
      },
      SuiOwnerKind.immutable => 'Immutable',
      _ => throw StateError('Unsupported Sui owner kind: ${parsed.kind}'),
    };
  }

  static Map<String, Object> _reference(pb.ChangedObject object) => {
    'objectId': object.objectId,
    'version': object.outputVersion.toString(),
    'digest': object.outputDigest,
  };

  static SuiTransactionBlockResponse _transactionResponse(
    pb.ExecutedTransaction transaction,
  ) {
    final effects = transaction.effects;
    if (!transaction.hasEffects() ||
        !effects.hasStatus() ||
        !effects.status.hasSuccess() ||
        !effects.status.success) {
      throw WalrusClientError(
        'Transaction ${transaction.digest} failed: '
        '${effects.status.error.description}',
      );
    }
    final changes = effects.changedObjects;
    final gas = effects.gasUsed;
    return SuiTransactionBlockResponse.fromJson({
      'digest': transaction.digest,
      'confirmedLocalExecution': true,
      'objectChanges': [
        for (final change in changes)
          {
            'type': change.idOperation == pb.ChangedObject_IdOperation.CREATED
                ? 'created'
                : change.idOperation == pb.ChangedObject_IdOperation.DELETED
                ? 'deleted'
                : 'mutated',
            'objectId': change.objectId,
            'objectType': change.objectType,
          },
      ],
      // Some transactions (e.g. sponsored/gasless transactions) may omit a
      // gas object. Preserve created-object changes without inventing refs.
      if (effects.hasGasObject())
        'effects': {
          'status': {'status': 'success'},
          'transactionDigest': transaction.digest,
          'gasUsed': {
            'computationCost': gas.computationCost.toString(),
            'storageCost': gas.storageCost.toString(),
            'storageRebate': gas.storageRebate.toString(),
            'nonRefundableStorageFee': gas.nonRefundableStorageFee.toString(),
          },
          'gasObject': {
            'owner': _owner(effects.gasObject.outputOwner),
            'reference': _reference(effects.gasObject),
          },
          'created': [
            for (final change in changes)
              if (change.idOperation == pb.ChangedObject_IdOperation.CREATED)
                {
                  'owner': _owner(change.outputOwner),
                  'reference': _reference(change),
                },
          ],
        },
    });
  }
}
