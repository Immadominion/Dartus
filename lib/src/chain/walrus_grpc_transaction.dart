import 'dart:convert';
import 'dart:typed_data';

import 'package:sui/grpc/grpc_transaction_mapper.dart';
import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/transaction.pb.dart' as pb;
import 'package:sui/sui.dart';

/// Keeps the gas payment and replay protection resolved together by Sui.
///
/// An empty payment can spend the sender's SUI address balance with a positive
/// gas budget. sui 0.5.1 discards that result and falls back to coin objects.
class WalrusGrpcBuilderAdapter extends GrpcBuilderAdapter {
  WalrusGrpcBuilderAdapter(super.core);

  @override
  Future<ResolvedGasData> resolveGasData(
    TransactionBlockDataBuilder data,
  ) async {
    final originalExpiration = _canonicalExpiration(data.expiration);
    final simulated = await core.simulateStructured(
      transactionDataToGrpcTransaction(data),
      doGasSelection: true,
      checksEnabled: true,
      readMask: const [
        'transaction.transaction.gas_payment',
        'transaction.transaction.expiration',
        'transaction.effects.status',
      ],
    );
    final executed = simulated.transaction;
    if (!simulated.hasTransaction() ||
        !executed.hasEffects() ||
        !executed.effects.hasStatus() ||
        !executed.effects.status.hasSuccess()) {
      throw StateError('Gas simulation returned no confirmed execution status');
    }
    if (!executed.effects.status.success) {
      throw StateError(
        'Gas simulation failed: ${executed.effects.status.error.description}',
      );
    }
    if (!executed.hasTransaction() || !executed.transaction.hasGasPayment()) {
      throw StateError('Gas simulation returned no gas payment');
    }
    final resolved = executed.transaction;
    final gas = resolved.gasPayment;
    if (!gas.hasBudget() || !gas.hasPrice()) {
      throw StateError('Gas simulation omitted its budget or price');
    }
    final original = data.expiration;
    final hasExplicitExpiration =
        original?.epoch != null || original?.validDuring != null;
    final expiration = resolved.hasExpiration()
        ? _expiration(resolved.expiration)
        : null;
    if (hasExplicitExpiration) {
      if (expiration != null &&
          _canonicalExpiration(expiration) != originalExpiration) {
        throw StateError('Gas simulation changed the requested expiration');
      }
    } else if (expiration != null) {
      data.expiration = expiration;
    }
    final payment =
        data.gasData.payment ??
        [
          for (final object in gas.objects)
            SuiObjectRef(
              object.digest,
              object.objectId,
              object.version.toInt(),
            ),
        ];
    if (payment.isEmpty && data.expiration?.validDuring == null) {
      throw StateError(
        'Address-balance gas requires a resolved ValidDuring expiration',
      );
    }
    return ResolvedGasData(
      budget: data.gasData.budget ?? BigInt.parse(gas.budget.toString()),
      price: data.gasData.price ?? BigInt.parse(gas.price.toString()),
      payment: payment,
    );
  }

  TransactionExpiration _expiration(pb.TransactionExpiration value) {
    switch (value.kind) {
      case pb.TransactionExpiration_TransactionExpirationKind.NONE:
        return TransactionExpiration();
      case pb.TransactionExpiration_TransactionExpirationKind.EPOCH:
        if (!value.hasEpoch()) {
          throw StateError('Gas simulation omitted its expiration epoch');
        }
        return TransactionExpiration(epoch: value.epoch.toInt());
      case pb.TransactionExpiration_TransactionExpirationKind.VALID_DURING:
        // Current address-balance transactions require an epoch window;
        // timestamps are not supported by the deployed protocol or the
        // upstream structured-transaction mapper. Never silently drop them.
        if (value.hasMinTimestamp() || value.hasMaxTimestamp()) {
          throw UnsupportedError('Timestamp expiration is not supported');
        }
        if (!value.hasMinEpoch() ||
            !value.hasEpoch() ||
            !value.hasChain() ||
            value.chain.isEmpty ||
            !value.hasNonce() ||
            value.epoch < value.minEpoch ||
            value.epoch - value.minEpoch > 1) {
          throw StateError('Gas simulation returned an invalid ValidDuring');
        }
        return TransactionExpiration(
          validDuring: {
            'minEpoch': value.minEpoch.toInt(),
            'maxEpoch': value.epoch.toInt(),
            'minTimestamp': null,
            'maxTimestamp': null,
            'chain': value.chain,
            'nonce': value.nonce,
          },
        );
      default:
        throw UnsupportedError('Unsupported resolved transaction expiration');
    }
  }
}

String _canonicalExpiration(TransactionExpiration? expiration) {
  final window = expiration?.validDuring;
  if (window == null) {
    return jsonEncode({'epoch': expiration?.epoch});
  }
  if (window['minTimestamp'] != null || window['maxTimestamp'] != null) {
    throw UnsupportedError('Timestamp expiration is not supported');
  }
  final min = BigInt.tryParse('${window['minEpoch']}');
  final max = BigInt.tryParse('${window['maxEpoch']}');
  final nonce = BigInt.tryParse('${window['nonce']}');
  if (min == null ||
      max == null ||
      min.isNegative ||
      max < min ||
      max - min > BigInt.one ||
      nonce == null ||
      nonce.isNegative ||
      nonce > BigInt.from(0xffffffff) ||
      window['chain'] is! String ||
      (window['chain'] as String).isEmpty) {
    throw StateError('Invalid ValidDuring expiration');
  }
  // BCS/JSON callers may represent u64 epochs as BigInt, int or decimal text.
  return jsonEncode({
    'minEpoch': min.toString(),
    'maxEpoch': max.toString(),
    'chain': window['chain'],
    'nonce': nonce.toString(),
  });
}

/// Builds through Dartus's gas resolver for both native and keypair uploads.
Future<Uint8List> prepareWalrusTransaction(
  SuiGrpcClient client,
  Transaction transaction, {
  required String sender,
  BigInt? gasBudget,
  BuildOptions? options,
}) async {
  if (options?.onlyTransactionKind ?? false) {
    throw ArgumentError('Cannot sign transaction-kind bytes');
  }
  _canonicalExpiration(transaction.getData().expiration);
  final core = client.core as GrpcCoreClient;
  await transaction.resolveNames(
    resolvePackage: core.resolvePackage,
    resolveType: core.resolveType,
  );
  transaction.setSenderIfNotSet(sender);
  if (gasBudget != null) transaction.setGasBudget(gasBudget);
  final bytes = await transaction.build(
    BuildOptions(
      client: options?.client ?? WalrusGrpcBuilderAdapter(core),
      protocolConfig: options?.protocolConfig,
      limits: options?.limits ?? <String, dynamic>{},
    ),
  );
  // Fully supplied gas skips resolveGasData in the upstream builder. Check
  // the final bytes as well so that path cannot bypass replay protection.
  final prepared = Transaction.fromBytes(bytes).getData();
  _canonicalExpiration(prepared.expiration);
  if (prepared.gasData.payment!.isEmpty &&
      prepared.expiration?.validDuring == null) {
    throw StateError('Address-balance gas requires a ValidDuring expiration');
  }
  return bytes;
}

Future<pb.ExecutedTransaction> signAndExecuteWalrusTransaction(
  SuiGrpcClient client,
  SuiAccount signer,
  Transaction transaction, {
  BuildOptions? options,
}) async {
  final bytes = await prepareWalrusTransaction(
    client,
    transaction,
    sender: signer.getAddress(),
    options: options,
  );
  final signed = signer.keyPair.signTransactionBlock(bytes);
  return client.executeTransaction(
    bytes,
    [Uint8List.fromList(base64Decode(signed.signature))],
    readMask: const ['digest', 'effects'],
  );
}
