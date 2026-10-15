/// Explicit opt-in only. Requires a test publisher that you control/authorize.
@TestOn('vm')
@Tags(['integration', 'live-write'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartus/dartus.dart';
import 'package:test/test.dart';

void main() {
  test(
    'configured live publisher stores and returns the uploaded bytes',
    () async {
      expect(
        Platform.environment['DARTUS_RUN_LIVE_WRITES'],
        'true',
        reason:
            'Explicitly set DARTUS_RUN_LIVE_WRITES=true to authorize a write',
      );
      final publisher = Platform.environment['DARTUS_LIVE_PUBLISHER'];
      final aggregator = Platform.environment['DARTUS_LIVE_AGGREGATOR'];
      expect(publisher, isNotNull, reason: 'Set DARTUS_LIVE_PUBLISHER');
      expect(aggregator, isNotNull, reason: 'Set DARTUS_LIVE_AGGREGATOR');
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse(publisher!),
        aggregatorBaseUrl: Uri.parse(aggregator!),
      );
      addTearDown(client.close);
      final bytes = utf8.encode('Dartus explicit live integration fixture');
      final response = await client.putBlob(
        data: bytes,
        deletable: true,
        epochs: 1,
      );
      final created = response['newlyCreated'] as Map<String, dynamic>?;
      final object = created?['blobObject'] as Map<String, dynamic>?;
      final certified = response['alreadyCertified'] as Map<String, dynamic>?;
      final blobId = (object?['blobId'] ?? certified?['blobId']) as String?;
      expect(
        blobId,
        isNotNull,
        reason: 'Publisher response must contain blobId',
      );
      expect(await client.getBlob(blobId!), bytes);
    },
  );
}
