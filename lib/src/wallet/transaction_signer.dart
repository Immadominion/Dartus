/// Who signs and pays for the Sui transactions of a Walrus write.
library;

import 'package:meta/meta.dart';
import 'package:sui/sui.dart';

import '../errors/walrus_errors.dart';
import '../chain/walrus_grpc_transaction.dart';

/// The wallet explicitly declined, or execution is known to have failed.
///
/// Only use this when no successful transaction can still arrive. Timeouts,
/// lost responses and generic transport errors do not establish that fact.
/// A failed on-chain transaction may still have charged gas.
class WalrusTransactionNotCommitted extends WalrusClientError {
  const WalrusTransactionNotCommitted(super.message, {this.cause});

  final Object? cause;
}

/// An executed transaction's effects confirm failure.
class WalrusTransactionExecutionFailed extends WalrusTransactionNotCommitted {
  const WalrusTransactionExecutionFailed(this.digest, super.message);

  final String digest;
}

/// Submission may have succeeded, but no digest was returned.
///
/// A write flow blocks another submission until the caller supplies the
/// original digest through `registered` / `certified`, or explicitly confirms
/// that the original request cannot succeed with `confirmNotCommitted`.
class WalrusTransactionOutcomeUnknown extends WalrusClientError {
  WalrusTransactionOutcomeUnknown(this.transaction, this.cause)
    : super(
        '${transaction.description} may have succeeded. Check the wallet and '
        'chain before trying again; another submission could charge again.',
      );

  final WalletTransaction transaction;
  final Object cause;
}

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
  /// Return once the transaction has executed. Throw
  /// [WalrusTransactionNotCommitted] for a definite rejection or failed
  /// execution. Other errors are treated as an unknown outcome, and the flow
  /// will not submit another transaction until that outcome is resolved.
  Future<String> signAndExecute(WalletTransaction transaction);
}

/// A [WalrusTransactionSigner] that hands transactions to a wallet through a
/// callback, typically one that calls `sui:signAndExecuteTransaction`.
class WalletTransactionSigner implements WalrusTransactionSigner {
  const WalletTransactionSigner({
    required this.address,
    required Future<String> Function(WalletTransaction transaction) execute,
    this.isDefinitelyNotCommitted,
  }) : _execute = execute;

  @override
  final String address;

  final Future<String> Function(WalletTransaction transaction) _execute;

  /// Identifies an explicit rejection / confirmed execution failure for the
  /// write flow. The original exception is preserved for the app's UI.
  /// Never classify a timeout or unknown transport error here.
  final bool Function(Object error)? isDefinitelyNotCommitted;

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
    final executed = await signAndExecuteWalrusTransaction(
      sui,
      account,
      Transaction.from(transaction.json),
    );
    // Protobuf defaults absent booleans to false. Missing evidence must not
    // be treated as a failed payment that is safe to submit again.
    if (!executed.hasEffects() ||
        !executed.effects.hasStatus() ||
        !executed.effects.status.hasSuccess()) {
      throw WalrusClientError(
        '${transaction.description} returned no confirmed execution status'
        '${executed.digest.isEmpty ? '' : ' for ${executed.digest}'}. '
        'Check the transaction before submitting again.',
      );
    }
    final status = executed.effects.status;
    if (!status.success) {
      throw WalrusTransactionExecutionFailed(
        executed.digest,
        '${transaction.description} failed: ${status.error.description}',
      );
    }
    return executed.digest;
  }
}
