/// Explicit opt-in: flutter test live_test/http_live_read_test.dart --tags integration
@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartus/dartus.dart';
import 'package:test/test.dart';

void main() {
  test('configured live aggregator returns the expected blob bytes', () async {
    final aggregator = Platform.environment['DARTUS_LIVE_AGGREGATOR'];
    final blobId = Platform.environment['DARTUS_LIVE_BLOB_ID'];
    final expectedText = Platform.environment['DARTUS_LIVE_EXPECTED_TEXT'];
    expect(aggregator, isNotNull, reason: 'Set DARTUS_LIVE_AGGREGATOR');
    expect(blobId, isNotNull, reason: 'Set DARTUS_LIVE_BLOB_ID');
    expect(expectedText, isNotNull, reason: 'Set DARTUS_LIVE_EXPECTED_TEXT');
    final client = WalrusClient(
      publisherBaseUrl: Uri.parse(aggregator!),
      aggregatorBaseUrl: Uri.parse(aggregator),
    );
    addTearDown(client.close);
    expect(await client.getBlob(blobId!), utf8.encode(expectedText!));
  });
}
