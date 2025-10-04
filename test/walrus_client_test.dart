import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/walrus_client.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  late WalrusClient client;
  File? downloadFile;

  setUp(() async {
    client = WalrusClient(
      publisherBaseUrl: TestConfig.mockPublisherUri,
      aggregatorBaseUrl: TestConfig.mockAggregatorUri,
      timeout: const Duration(seconds: 20),
    );

    final file = await TestConfig.prepareTestFile();
    expect(await file.exists(), isTrue);
  });

  tearDown(() async {
    if (downloadFile != null && await downloadFile!.exists()) {
      await downloadFile!.delete();
    }
    await TestConfig.cleanup();
    await client.close();
  });

  test(
    'uploads a file and fetches by object id',
    () async {
      final response = await client.putBlobFromFile(file: TestConfig.testFile);
      expect(response, isNotEmpty);

      final blobId = _findBlobId(response);
      expect(blobId, isNotNull, reason: 'Response should contain a blobId');

      final data = await client.getBlobByObjectId(blobId!);
      expect(data, isA<Uint8List>());
      expect(data, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('downloads a file to disk', () async {
    final destination = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}walrus-download-${DateTime.now().microsecondsSinceEpoch}.data',
    );
    downloadFile = destination;

    if (await destination.exists()) {
      await destination.delete();
    }

    await client.getBlobAsFile(
      blobId: TestConfig.testBlobId,
      destination: destination,
    );

    expect(await destination.exists(), isTrue);
    expect(await destination.length(), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String? _findBlobId(dynamic json) {
  if (json is Map<String, dynamic>) {
    for (final entry in json.entries) {
      if (entry.key == 'blobId') {
        final value = entry.value;
        if (value is String && value.isNotEmpty) {
          return value;
        }
      }
      final nested = _findBlobId(entry.value);
      if (nested != null) {
        return nested;
      }
    }
  } else if (json is Iterable) {
    for (final element in json) {
      final nested = _findBlobId(element);
      if (nested != null) {
        return nested;
      }
    }
  }
  return null;
}
