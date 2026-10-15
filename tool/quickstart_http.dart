// Checked HTTP examples used in README.md. No network calls run on import.
import 'dart:typed_data';

import 'package:dartus/dartus.dart';

WalrusClient createHttpClient() => WalrusClient(
  publisherBaseUrl: Uri.parse('https://publisher.walrus-testnet.walrus.space'),
  aggregatorBaseUrl: Uri.parse(
    'https://aggregator.walrus-testnet.walrus.space',
  ),
);

Future<Uint8List> uploadAndRead(WalrusClient client, Uint8List bytes) async {
  final response = await client.putBlob(data: bytes, deletable: true);
  final created = response['newlyCreated'] as Map<String, dynamic>?;
  final object = created?['blobObject'] as Map<String, dynamic>?;
  final certified = response['alreadyCertified'] as Map<String, dynamic>?;
  final blobId = object?['blobId'] ?? certified?['blobId'];
  if (blobId is! String || blobId.isEmpty) {
    throw const FormatException('Publisher did not return a blob ID');
  }
  return client.getBlob(blobId);
}
