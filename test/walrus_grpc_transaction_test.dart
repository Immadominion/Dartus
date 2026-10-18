import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:dartus/src/chain/direct_grpc_client.dart';
import 'package:dartus/src/chain/walrus_grpc_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/transaction.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/transaction_execution_service.pb.dart'
    as pb;
import 'package:sui/sui.dart';

const _chain = '11111111111111111111111111111111';
final _window = {
  'minEpoch': BigInt.from(7),
  'maxEpoch': BigInt.from(8),
  'minTimestamp': null,
  'maxTimestamp': null,
  'chain': _chain,
  'nonce': 42,
};

class _Core extends GrpcCoreClient {
  _Core() : super(network: SuiNetwork.testnet, endpoint: 'http://127.0.0.1:1');

  final response = pb.SimulateTransactionResponse()
    ..mergeFromProto3Json({
      'transaction': {
        'transaction': {
          'gasPayment': {'budget': '3000000', 'price': '1000'},
          'expiration': {
            'kind': 'VALID_DURING',
            'minEpoch': '7',
            'epoch': '8',
            'chain': _chain,
            'nonce': 42,
          },
        },
        'effects': {
          'status': {'success': true},
        },
      },
    });
  pb.Transaction? requested;
  List<String>? mask;

  @override
  Future<pb.SimulateTransactionResponse> simulateStructured(
    pb.Transaction transaction, {
    List<String>? readMask,
    bool doGasSelection = true,
    bool checksEnabled = true,
  }) async {
    expect(doGasSelection, isTrue);
    expect(checksEnabled, isTrue);
    requested = transaction;
    mask = readMask;
    return response;
  }
}

class _Client extends SuiGrpcClient {
  _Client()
    : super(network: SuiNetwork.testnet, endpoint: 'http://127.0.0.1:1');

  final _Core testCore = _Core();
  @override
  _Core get core => testCore;
  Uint8List? submitted;
  int submissions = 0;

  @override
  Future<pb.ExecutedTransaction> executeTransaction(
    Uint8List bytes,
    List<Uint8List> signatures, {
    List<String>? readMask,
  }) async {
    submissions++;
    submitted = bytes;
    expect(signatures, hasLength(1));
    return pb.ExecutedTransaction()..mergeFromProto3Json({
      'digest': 'offline-digest',
      'effects': {
        'status': {'success': true},
      },
    });
  }
}

Transaction _transaction() => Transaction()..setGasPrice(BigInt.from(1000));

void main() {
  test(
    'address-balance gas retains price, positive budget and replay window',
    () async {
      final client = _Client();
      final bytes = await prepareWalrusTransaction(
        client,
        _transaction(),
        sender: '0x1',
      );
      final decoded = Transaction.fromBytes(bytes).getData();
      expect(decoded.gasData.payment, isEmpty);
      expect(decoded.gasData.budget, BigInt.from(3000000));
      expect(decoded.gasData.price, BigInt.from(1000));
      expect(decoded.expiration!.validDuring, _window);
      expect(client.core.mask, contains('transaction.transaction.expiration'));
      expect(client.submissions, 0);
    },
  );

  test('caller budget and expiration reach simulation unchanged', () async {
    final client = _Client();
    final tx = _transaction()
      ..setValidDuringExpiration(
        minEpoch: 7,
        maxEpoch: 8,
        chain: _chain,
        nonce: 42,
      );
    await prepareWalrusTransaction(
      client,
      tx,
      sender: '0x1',
      gasBudget: BigInt.from(3000000),
    );
    expect(client.core.requested!.gasPayment.budget.toString(), '3000000');
    expect(client.core.requested!.expiration.nonce, 42);
  });

  test('coin-object gas remains supported without ValidDuring', () async {
    final client = _Client();
    final resolved = client.core.response.transaction.transaction;
    resolved.clearExpiration();
    resolved.gasPayment.mergeFromProto3Json({
      'objects': [
        {'objectId': '0xa', 'version': '2', 'digest': _chain},
      ],
    });
    final bytes = await prepareWalrusTransaction(
      client,
      _transaction(),
      sender: '0x1',
    );
    expect(
      Transaction.fromBytes(bytes).getData().gasData.payment,
      hasLength(1),
    );
  });

  test(
    'decimal-string JSON expiration compares by value, not map order',
    () async {
      final client = _Client();
      final json = jsonDecode(_transaction().toJson()) as Map<String, dynamic>;
      json['expiration'] = {
        'ValidDuring': {
          'nonce': 42,
          'chain': _chain,
          'maxEpoch': '8',
          'minEpoch': '7',
        },
      };
      final bytes = await prepareWalrusTransaction(
        client,
        Transaction.from(jsonEncode(json)),
        sender: '0x1',
      );
      expect(
        Transaction.fromBytes(bytes).getData().expiration!.validDuring,
        _window,
      );
      final roundtrip = Transaction.fromBytes(bytes);
      final data = TransactionBlockDataBuilder(roundtrip.getData());
      await WalrusGrpcBuilderAdapter(client.core).resolveGasData(data);
      expect(data.expiration!.validDuring, _window);
    },
  );

  test('explicit gas budget, price and payment are preserved', () async {
    final core = _Core();
    final data = TransactionBlockDataBuilder()
      ..sender = '0x1'
      ..expiration = TransactionExpiration(validDuring: Map.of(_window))
      ..gasData = GasConfig(
        budget: BigInt.from(2000000),
        price: BigInt.from(900),
        payment: [],
      );
    final result = await WalrusGrpcBuilderAdapter(core).resolveGasData(data);
    expect(result.budget, BigInt.from(2000000));
    expect(result.price, BigInt.from(900));
    expect(result.payment, isEmpty);
    expect(core.requested!.gasPayment.budget.toString(), '2000000');
    expect(core.requested!.gasPayment.price.toString(), '900');
  });

  test('preset empty gas cannot bypass ValidDuring validation', () async {
    final client = _Client();
    final tx = _transaction()
      ..setGasBudget(BigInt.from(3000000))
      ..setGasPayment([]);
    await expectLater(
      signAndExecuteWalrusTransaction(client, SuiAccount.ed25519Account(), tx),
      throwsStateError,
    );
    expect(client.core.requested, isNull);
    expect(client.submissions, 0);
  });

  test(
    'timestamp restrictions are rejected before the mapper can drop them',
    () async {
      final client = _Client();
      final tx = _transaction()
        ..setValidDuringExpiration(
          minEpoch: 7,
          maxEpoch: 8,
          minTimestamp: 1000,
          chain: _chain,
          nonce: 42,
        );
      await expectLater(
        prepareWalrusTransaction(client, tx, sender: '0x1'),
        throwsUnsupportedError,
      );
      expect(client.core.requested, isNull);
      expect(client.submissions, 0);
    },
  );

  test(
    'unsupported server timestamp restrictions are never stripped',
    () async {
      final client = _Client();
      client.core.response.transaction.transaction.expiration
          .mergeFromProto3Json({'minTimestamp': '2026-10-18T00:00:00Z'});
      await expectLater(
        prepareWalrusTransaction(client, _transaction(), sender: '0x1'),
        throwsUnsupportedError,
      );
      expect(client.submissions, 0);
    },
  );

  for (final failure in [
    'effects',
    'status',
    'success',
    'failed',
    'gas',
    'budget',
    'price',
    'expiration',
    'chain',
    'nonce',
    'epoch',
    'unknown kind',
  ]) {
    test('rejects $failure before signing or execution', () async {
      final client = _Client();
      final executed = client.core.response.transaction;
      final resolved = executed.transaction;
      switch (failure) {
        case 'effects':
          executed.clearEffects();
        case 'status':
          executed.effects.clearStatus();
        case 'success':
          executed.effects.status.clearSuccess();
        case 'failed':
          executed.effects.status.success = false;
        case 'gas':
          resolved.clearGasPayment();
        case 'budget':
          resolved.gasPayment.clearBudget();
        case 'price':
          resolved.gasPayment.clearPrice();
        case 'expiration':
          resolved.clearExpiration();
        case 'chain':
          resolved.expiration.clearChain();
        case 'nonce':
          resolved.expiration.clearNonce();
        case 'epoch':
          resolved.expiration.clearEpoch();
        case 'unknown kind':
          resolved.expiration.clearKind();
      }
      await expectLater(
        signAndExecuteWalrusTransaction(
          client,
          SuiAccount.ed25519Account(),
          _transaction(),
        ),
        throwsA(anyOf(isA<StateError>(), isA<UnsupportedError>())),
      );
      expect(client.submissions, 0);
    });
  }

  test('does not silently change an explicit expiration', () async {
    final client = _Client();
    final tx = _transaction()..setExpiration(1);
    await expectLater(
      prepareWalrusTransaction(client, tx, sender: '0x1'),
      throwsStateError,
    );
    expect(client.submissions, 0);
  });

  test(
    'default native signing uses corrected address-balance adapter',
    () async {
      final client = _Client();
      final result = await DirectGrpcClient(client)
          .signAndExecuteTransactionBlock(
            SuiAccount.ed25519Account(),
            _transaction(),
          );
      expect(result.digest, 'offline-digest');
      expect(
        Transaction.fromBytes(
          client.submitted!,
        ).getData().expiration!.validDuring,
        _window,
      );
    },
  );

  test(
    'keypair wallet signing uses corrected address-balance adapter',
    () async {
      final client = _Client();
      final signer = KeypairTransactionSigner(
        SuiAccount.ed25519Account(),
        client,
      );
      expect(
        await signer.signAndExecute(
          WalletTransaction(
            json: _transaction().toJson(),
            sender: signer.address,
            chain: 'sui:testnet',
            description: 'Offline address-balance fixture',
          ),
        ),
        'offline-digest',
      );
      expect(
        Transaction.fromBytes(
          client.submitted!,
        ).getData().expiration!.validDuring,
        _window,
      );
    },
  );
}
