@TestOn('vm')
@Tags(['unit'])
library;

import 'dart:convert';

import 'package:dartus/direct.dart';
import 'package:sui/sui.dart';
import 'package:test/test.dart';

const _owner =
    '0x0000000000000000000000000000000000000000000000000000000000000099';
const _exchangePackage = '0xaa';

class _Signer implements SuiAccount {
  @override
  String getAddress() => _owner;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('This test must not sign');
}

class _CapturingClient extends SuiClient {
  _CapturingClient() : super('http://127.0.0.1:1');

  Transaction? transaction;

  @override
  Future<SuiObjectResponse> getObject(
    String objectId, {
    SuiObjectDataOptions? options,
  }) async => SuiObjectResponse.fromJson({
    'data': {
      'objectId': objectId,
      'version': '1',
      'digest': 'exchange-fixture',
      'type': '$_exchangePackage::wal_exchange::Exchange',
    },
  });

  @override
  Future<SuiTransactionBlockResponse> signAndExecuteTransactionBlock(
    SuiAccount signer,
    Transaction transaction, {
    BuildOptions? options,
    SuiTransactionBlockResponseOptions? responseOptions,
    ExecuteTransaction requestType = ExecuteTransaction.WaitForEffectsCert,
  }) async {
    this.transaction = transaction;
    return SuiTransactionBlockResponse.fromJson({
      'digest': 'exchange-digest',
      'effects': {
        'status': {'status': 'success'},
        'transactionDigest': 'exchange-digest',
        'gasUsed': {
          'computationCost': '0',
          'storageCost': '0',
          'storageRebate': '0',
          'nonRefundableStorageFee': '0',
        },
        'gasObject': {
          'owner': {'AddressOwner': _owner},
          'reference': {
            'objectId': '0x10',
            'version': '1',
            'digest': 'gas-fixture',
          },
        },
      },
    });
  }
}

void main() {
  for (final function in [
    'exchange_for_wal',
    'exchange_for_sui',
    'exchange_all_for_wal',
    'exchange_all_for_sui',
  ]) {
    test('$function transfers its returned coin to the signer', () async {
      final rpc = _CapturingClient();
      final client = WalrusDirectClient(
        network: WalrusNetwork.testnet,
        walrusPackageId: '0xbb',
        suiClient: rpc,
      );
      addTearDown(client.close);
      final signer = _Signer();

      final digest = await switch (function) {
        'exchange_for_wal' => client.exchangeForWal(
          suiCoinObjectId: '0x11',
          amountSui: BigInt.from(25),
          signer: signer,
        ),
        'exchange_for_sui' => client.exchangeForSui(
          walCoinObjectId: '0x11',
          amountWal: BigInt.from(25),
          signer: signer,
        ),
        'exchange_all_for_wal' => client.exchangeAllForWal(
          suiCoinObjectId: '0x11',
          signer: signer,
        ),
        _ => client.exchangeAllForSui(walCoinObjectId: '0x11', signer: signer),
      };

      expect(digest, 'exchange-digest');
      final data = rpc.transaction!.getData();
      expect(data.sender, _owner);
      final commands = data.commands!;
      expect(commands, hasLength(2));
      final moveCall = commands.first['MoveCall'] as Map;
      expect(moveCall['package'], _exchangePackage);
      expect(moveCall['module'], 'wal_exchange');
      expect(moveCall['function'], function);

      // Coin has no drop ability: leaving this Move result unused aborts the
      // entire exchange. Transfer exactly that result, not the input coin.
      final transfer = commands.last['TransferObjects'] as Map;
      final objects = transfer['objects'] as List;
      expect(objects, hasLength(1));
      final result = objects.single;
      expect(result is TransactionResult ? result.toJson() : result, {
        r'$kind': 'Result',
        'Result': 0,
      });

      final address = transfer['address'] as Map;
      final input = data.inputs![address['Input'] as int];
      final bytes = base64Decode((input['Pure'] as Map)['bytes'] as String);
      final recipient =
          '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      expect(recipient, _owner);
    });
  }
}
