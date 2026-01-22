import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class TestConfig {
  // Official Walrus Testnet endpoints (from https://docs.wal.app/docs/usage/web-api)
  static final Uri mockPublisherUri = Uri.parse(
    'https://publisher.walrus-testnet.walrus.space',
  );
  static final Uri mockAggregatorUri = Uri.parse(
    'https://aggregator.walrus-testnet.walrus.space',
  );

  // Real blob stored on testnet: "Hello from Dartus SDK test"
  // Uploaded 2026-01-22, expires epoch 295
  static const String testBlobId =
      'E8MF7jAL5t5s_MAwxexHWYtMUcTCnIxcFPC72shOUfY';
  static final Uint8List testBlobData = Uint8List.fromList(
    utf8.encode('Hello from Dartus SDK test\n'),
  );

  static File get testFile => File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}walrus-test-file.data',
  );

  static Future<File> prepareTestFile() async {
    await testFile.writeAsBytes(testBlobData, flush: true);
    return testFile;
  }

  static Future<void> cleanup() async {
    if (await testFile.exists()) {
      await testFile.delete();
    }
  }
}
