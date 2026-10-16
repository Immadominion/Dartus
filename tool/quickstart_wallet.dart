// README examples for wallet writes. Analyzed in CI; the flow they call is
// covered by test/walrus_writer_test.dart and live_test/.
import 'dart:typed_data';

import 'package:dartus/dartus.dart';

/// Store [bytes] for 5 epochs, paid for by a browser wallet.
///
/// [execute] hands a serialized transaction to the wallet
/// (`sui:signAndExecuteTransaction`) and returns its digest. With
/// `sui_wallet_web`:
/// `(json) async => (await wallet.signAndExecuteTransaction(json)).digest`.
Future<WalrusWriteResult> storeWithWallet(
  Uint8List bytes, {
  required String address,
  required Future<String> Function(String transactionJson) execute,
}) async {
  final writer = WalrusWriter(network: WalrusNetwork.testnet);
  try {
    final estimate = await writer.estimate(size: bytes.length, epochs: 5);
    print('Costs ${estimate.cost.total} FROST of WAL, plus gas');

    return await writer.write(
      bytes,
      epochs: 5,
      signer: WalletTransactionSigner(
        address: address,
        execute: (tx) => execute(tx.json),
      ),
      onStage: (stage) => print(stage.name),
    );
  } finally {
    writer.close();
  }
}

/// Store several files as one quilt (two approvals for the whole batch),
/// then read one back on its own.
Future<Uint8List> storeBatch(
  List<QuiltBlob> files,
  WalrusTransactionSigner signer,
  WalrusClient reader,
) async {
  final writer = WalrusWriter(network: WalrusNetwork.testnet);
  try {
    final result = await writer.writeFiles(files, signer: signer, epochs: 5);
    return reader.getQuiltPatch(result.files.first.patchId);
  } finally {
    writer.close();
  }
}

/// Keep a flow to retry: `run` continues after a declined approval or a
/// failed upload, without registering or paying twice.
Future<WalrusWriteResult> storeWithRetry(
  Uint8List bytes,
  WalrusTransactionSigner signer,
  WalrusWriter writer,
) async {
  final flow = writer.writeFlow(bytes, epochs: 5);
  for (var attempt = 1; ; attempt++) {
    try {
      return await flow.run(signer);
    } on WalrusTransactionOutcomeUnknown {
      rethrow; // Check wallet history; the original submission may still succeed.
    } on InsufficientWalBalanceError {
      rethrow; // Retrying will not help until the wallet holds more WAL.
    } on Object {
      if (attempt == 3) rethrow;
    }
  }
}
