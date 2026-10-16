import 'package:dartus/dartus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sui/grpc/proto/sui/rpc/v2/effects.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/execution_status.pb.dart' as pb;
import 'package:sui/sui.dart';

void main() {
  final account = SuiAccount.ed25519Account();
  final transaction = WalletTransaction(
    json: Transaction().toJson(),
    sender: account.getAddress(),
    chain: 'sui:testnet',
    description: 'Register the blob',
  );
  final incompleteReceipts = <String, pb.ExecutedTransaction>{
    'effects': pb.ExecutedTransaction(digest: 'receipt-digest'),
    'status': pb.ExecutedTransaction(
      digest: 'receipt-digest',
      effects: pb.TransactionEffects(),
    ),
    'success': pb.ExecutedTransaction(
      digest: 'receipt-digest',
      effects: pb.TransactionEffects(status: pb.ExecutionStatus()),
    ),
  };

  for (final entry in incompleteReceipts.entries) {
    test('keypair signer cannot retry on missing ${entry.key}', () async {
      final signer = KeypairTransactionSigner(
        account,
        _ReceiptClient(entry.value),
      );
      await expectLater(
        signer.signAndExecute(transaction),
        throwsA(
          allOf(
            isA<WalrusClientError>(),
            isNot(isA<WalrusTransactionNotCommitted>()),
          ),
        ),
      );
    });

    test('chain lookup cannot retry payment on missing ${entry.key}', () async {
      final reader = WalrusChainReader.forNetwork(
        WalrusNetwork.testnet,
        sui: _ReceiptClient(entry.value),
      );
      final unknown = throwsA(
        allOf(
          isA<WalrusClientError>(),
          isNot(isA<WalrusTransactionNotCommitted>()),
        ),
      );
      await expectLater(reader.waitForSuccess('receipt-digest'), unknown);
      await expectLater(
        reader.createdObjects('receipt-digest', type: 'blob-type'),
        unknown,
      );
    });
  }

  test(
    'an explicit failed receipt permits retry and retains its digest',
    () async {
      final client = _ReceiptClient(
        pb.ExecutedTransaction(
          digest: 'receipt-digest',
          effects: pb.TransactionEffects(
            status: pb.ExecutionStatus(success: false),
          ),
        ),
      );
      final failed = throwsA(
        isA<WalrusTransactionExecutionFailed>().having(
          (error) => error.digest,
          'digest',
          'receipt-digest',
        ),
      );
      await expectLater(
        KeypairTransactionSigner(account, client).signAndExecute(transaction),
        failed,
      );
      await expectLater(
        WalrusChainReader.forNetwork(
          WalrusNetwork.testnet,
          sui: client,
        ).waitForSuccess('receipt-digest'),
        failed,
      );
    },
  );

  test('an explicit successful receipt is accepted', () async {
    final client = _ReceiptClient(
      pb.ExecutedTransaction(
        digest: 'receipt-digest',
        effects: pb.TransactionEffects(
          status: pb.ExecutionStatus(success: true),
        ),
      ),
    );
    expect(
      await KeypairTransactionSigner(
        account,
        client,
      ).signAndExecute(transaction),
      'receipt-digest',
    );
    await WalrusChainReader.forNetwork(
      WalrusNetwork.testnet,
      sui: client,
    ).waitForSuccess('receipt-digest');
  });
}

/// No network or real signing: only exercises interpretation of receipts.
class _ReceiptClient implements SuiGrpcClient {
  _ReceiptClient(this.receipt);

  final pb.ExecutedTransaction receipt;

  @override
  Future<pb.ExecutedTransaction> signAndExecuteTransaction(
    SuiAccount signer,
    Transaction tx, {
    BigInt? gasBudget,
    List<String>? readMask,
  }) async => receipt;

  @override
  Future<pb.ExecutedTransaction> waitForTransaction(
    String digest, {
    Duration timeout = const Duration(seconds: 60),
    Duration pollInterval = const Duration(milliseconds: 500),
    List<String>? readMask,
  }) async => receipt;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
