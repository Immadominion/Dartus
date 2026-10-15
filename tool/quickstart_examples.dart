// Checked native API examples used in README.md. These functions are analyzed,
// not executed against a wallet or live network as part of documentation checks.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/direct.dart';
import 'package:sui/sui.dart';

WalrusDirectClient createNativeClient() => WalrusDirectClient.fromNetwork(
  network: WalrusNetwork.testnet,
  encoder: WalrusBlobEncoder(),
);

Future<Uint8List> readDirect(WalrusDirectClient client, String blobId) =>
    client.readBlob(blobId: blobId);

Future<WriteBlobResult> writeDirect(
  WalrusDirectClient client,
  SuiAccount signer,
) => client.writeBlob(
  blob: utf8.encode('Hello Walrus!'),
  epochs: 3,
  signer: signer,
  deletable: true,
);

Future<void> writeWithWallet(
  WalrusDirectClient client,
  String owner,
  Future<Map<String, dynamic>> Function(Transaction) signAndExecute,
) async {
  final flow = await client.writeBlobFlow(blob: utf8.encode('Hello Walrus!'));
  await flow.encode();
  final registerTx = await flow.register(
    WriteBlobFlowRegisterOptions(epochs: 3, owner: owner, deletable: true),
  );
  final txResult = await signAndExecute(registerTx);
  final digest = txResult['digest'];
  if (digest is! String) {
    throw const FormatException('Wallet did not return a transaction digest');
  }
  await flow.upload(
    WriteBlobFlowUploadOptions(digest: digest, txResult: txResult),
  );
  await signAndExecute(flow.certify());
}

WalrusFile createTextFile() => WalrusFile.from(
  contents: utf8.encode('Hello, World!'),
  identifier: 'hello.txt',
  tags: {'type': 'text'},
);

Future<void> downloadToFile(
  WalrusClient client,
  String blobId,
  File destination,
) => client.getBlobAsFileStreaming(blobId: blobId, destination: destination);
