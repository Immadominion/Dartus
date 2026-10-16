/// Who signs and pays for the Sui transactions of a Walrus write.
library;

import 'package:meta/meta.dart';
import 'package:sui/sui.dart';

/// A transaction ready for a wallet: everything but gas is filled in.
///
/// [json] is the serialized transaction in the format of `@mysten/sui`'s
/// `Transaction.toJSON()`, which Wallet Standard wallets (Slush and others)
/// accept as `transaction` in `sui:signAndExecuteTransaction`. Coin and WAL
/// inputs are already resolved for [sender]; the wallet picks the gas coins
/// and the budget.
@immutable
class WalletTransaction {
  const WalletTransaction({
    required this.json,
    required this.sender,
    required this.chain,
    required this.description,
  });

  final String json;

  /// The address that must sign: the wallet account.
  final String sender;

  /// Wallet Standard chain, `sui:testnet` or `sui:mainnet`.
  final String chain;

  /// What the transaction does, in a few words, for logs and UI.
  final String description;
}

/// Signs a [WalletTransaction] and executes it on Sui.
///
/// Implement it over a browser wallet with
/// [WalletTransactionSigner.new], or use [KeypairTransactionSigner] for
/// scripts, servers and tests.
abstract interface class WalrusTransactionSigner {
  /// The address that signs, pays gas and WAL, and first owns the blob.
  String get address;

  /// Sign and execute [transaction] and return its digest.
  ///
  /// Return once the transaction has executed. Throw if the person declines
  /// or execution fails; the write flow keeps its state, so the same step
  /// can be tried again.
  Future<String> signAndExecute(WalletTransaction transaction);
}

/// A [WalrusTransactionSigner] that hands transactions to a wallet through a
/// callback, typically one that calls `sui:signAndExecuteTransaction`.
class WalletTransactionSigner implements WalrusTransactionSigner {
  const WalletTransactionSigner({
    required this.address,
    required Future<String> Function(WalletTransaction transaction) execute,
  }) : _execute = execute;

  @override
  final String address;

  final Future<String> Function(WalletTransaction transaction) _execute;

  @override
  Future<String> signAndExecute(WalletTransaction transaction) =>
      _execute(transaction);
}

/// Signs with a key held in memory and executes over gRPC. For scripts,
/// servers and tests; apps should let the person's wallet sign instead.
class KeypairTransactionSigner implements WalrusTransactionSigner {
  KeypairTransactionSigner(this.account, this.sui);

  final SuiAccount account;
  final SuiGrpcClient sui;

  @override
  String get address => account.getAddress();

  @override
  Future<String> signAndExecute(WalletTransaction transaction) async {
    final executed = await sui.signAndExecuteTransaction(
      account,
      Transaction.from(transaction.json),
      readMask: const ['digest', 'effects'],
    );
    final status = executed.effects.status;
    if (!status.success) {
      throw StateError(
        '${transaction.description} failed: ${status.error.description}',
      );
    }
    return executed.digest;
  }
}
