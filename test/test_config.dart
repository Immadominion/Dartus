import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class TestConfig {
  static final Uri mockPublisherUri = Uri.parse(
    'https://walrus-testnet-publisher.starduststaking.com',
  );
  static final Uri mockAggregatorUri = Uri.parse(
    'https://agg.test.walrus.eosusa.io',
  );

  static const String testBlobId =
      'Dk0h8UqEpinUZjsmkwE8T135b3z7W8tSxHD6W58xkTQ';
  static final Uint8List testBlobData = Uint8List.fromList(
    utf8.encode('Test blob content'),
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
