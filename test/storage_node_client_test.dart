/// Tests for [StorageNodeClient] — connection pooling, retry logic,
/// and response parsing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/storage_node/storage_node_client.dart';
import 'package:dartus/src/errors/walrus_errors.dart';
import 'package:dartus/src/models/storage_node_types.dart';
import 'package:test/test.dart';

void main() {
  group('StorageNodeClient construction', () {
    test('uses default timeout and retry values', () {
      final client = StorageNodeClient(baseUrl: 'https://example.com');
      expect(client.baseUrl, 'https://example.com');
      expect(client.timeout, const Duration(seconds: 30));
      expect(client.maxRetries, 3);
      expect(client.retryDelay, const Duration(milliseconds: 500));
      client.close();
    });

    test('accepts custom timeout and retry', () {
      final client = StorageNodeClient(
        baseUrl: 'https://node.test',
        timeout: const Duration(seconds: 10),
        maxRetries: 5,
        retryDelay: const Duration(seconds: 1),
      );
      expect(client.timeout, const Duration(seconds: 10));
      expect(client.maxRetries, 5);
      expect(client.retryDelay, const Duration(seconds: 1));
      client.close();
    });

    test('toString includes baseUrl', () {
      final client = StorageNodeClient(baseUrl: 'https://n.test');
      expect(client.toString(), contains('https://n.test'));
      client.close();
    });
  });

  group('StorageNodeClient response parsing', () {
    // These tests use a local HTTP server to simulate storage node responses.

    late HttpServer server;
    late StorageNodeClient client;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      client = StorageNodeClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        timeout: const Duration(seconds: 5),
        maxRetries: 0,
      );
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    test(
      'getPermanentBlobConfirmation navigates success.data.signed',
      () async {
        server.listen((request) {
          final response = {
            'success': {
              'code': 0,
              'data': {
                'signed': {
                  'serializedMessage': base64Encode([0xDE, 0xAD]),
                  'signature': 'c2lnbmF0dXJl', // base64("signature")
                },
              },
            },
          };
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(response))
            ..close();
        });

        final conf = await client.getPermanentBlobConfirmation(blobId: 'test');
        expect(conf.serializedMessage, equals([0xDE, 0xAD]));
        expect(conf.signature, 'c2lnbmF0dXJl');
      },
    );

    test(
      'getDeletableBlobConfirmation navigates success.data.signed',
      () async {
        server.listen((request) {
          final response = {
            'success': {
              'code': 0,
              'data': {
                'signed': {
                  'serializedMessage': base64Encode([1, 2, 3]),
                  'signature': 'dGVzdA==', // base64("test")
                },
              },
            },
          };
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(response))
            ..close();
        });

        final conf = await client.getDeletableBlobConfirmation(
          blobId: 'test',
          objectId: '0xobj',
        );
        expect(conf.serializedMessage, equals([1, 2, 3]));
      },
    );

    test('getBlobStatus parses nonexistent from success.data', () async {
      server.listen((request) {
        final response = {
          'success': {'data': 'nonexistent'},
        };
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(response))
          ..close();
      });

      final status = await client.getBlobStatus(blobId: 'test');
      expect(status, isA<BlobStatusNonexistent>());
    });

    test('getBlobStatus parses permanent from success.data', () async {
      server.listen((request) {
        final response = {
          'success': {
            'data': {
              'permanent': {
                'endEpoch': 42,
                'isCertified': true,
                'initialCertifiedEpoch': 10,
                'deletableCounts': {
                  'count_deletable_total': 0,
                  'count_deletable_certified': 0,
                },
                'statusEvent': {'eventSeq': '1', 'txDigest': '0xabc'},
              },
            },
          },
        };
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(response))
          ..close();
      });

      final status = await client.getBlobStatus(blobId: 'test');
      expect(status, isA<BlobStatusPermanent>());
      expect((status as BlobStatusPermanent).endEpoch, 42);
    });

    test('getBlobStatus parses deletable from success.data', () async {
      server.listen((request) {
        final response = {
          'success': {
            'data': {
              'deletable': {
                'initialCertifiedEpoch': 100,
                'deletableCounts': {
                  'count_deletable_total': 2,
                  'count_deletable_certified': 1,
                },
              },
            },
          },
        };
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(response))
          ..close();
      });

      final status = await client.getBlobStatus(blobId: 'test');
      expect(status, isA<BlobStatusDeletable>());
      final d = status as BlobStatusDeletable;
      expect(d.initialCertifiedEpoch, 100);
    });

    test('throws StorageNodeApiError on 500 response', () async {
      server.listen((request) {
        request.response
          ..statusCode = 500
          ..write('Internal Server Error')
          ..close();
      });

      expect(
        () => client.getBlobMetadata(blobId: 'test'),
        throwsA(isA<InternalServerError>()),
      );
    });

    test('storeBlobMetadata sends PUT with body', () async {
      String? capturedMethod;
      List<int>? capturedBody;

      server.listen((request) async {
        capturedMethod = request.method;
        capturedBody = await request.fold<List<int>>(
          [],
          (prev, chunk) => prev..addAll(chunk),
        );
        request.response
          ..statusCode = 200
          ..close();
      });

      final metadata = [0x01, 0x02, 0x03];
      await client.storeBlobMetadata(
        blobId: 'test',
        metadata: Uint8List.fromList(metadata),
      );
      expect(capturedMethod, 'PUT');
      expect(capturedBody, equals(metadata));
    });
  });

  group('StorageNodeClient retry logic', () {
    late HttpServer server;
    int requestCount = 0;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      requestCount = 0;
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('rethrows API errors immediately without retrying', () async {
      final client = StorageNodeClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        timeout: const Duration(seconds: 5),
        maxRetries: 3,
        retryDelay: const Duration(milliseconds: 50),
      );

      server.listen((request) {
        requestCount++;
        request.response
          ..statusCode = 500
          ..write('fail')
          ..close();
      });

      // API errors (like 500) are deterministic — they rethrow immediately
      // without using the retry budget. Only connection-level errors retry.
      expect(
        () => client.getBlobStatus(blobId: 'test'),
        throwsA(isA<InternalServerError>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requestCount, 1);

      client.close();
    });

    test('gives up after max retries', () async {
      final client = StorageNodeClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        timeout: const Duration(seconds: 5),
        maxRetries: 2,
        retryDelay: const Duration(milliseconds: 10),
      );

      server.listen((request) {
        requestCount++;
        request.response
          ..statusCode = 500
          ..write('always fail')
          ..close();
      });

      // StorageNodeApiError (500) now rethrows immediately without retrying,
      // since API errors are deterministic — only connection errors are retried.
      expect(
        () => client.getBlobMetadata(blobId: 'test'),
        throwsA(isA<InternalServerError>()),
      );

      // API error rethrows on first attempt — no retries.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requestCount, 1);

      client.close();
    });

    test('no retry when maxRetries is 0', () async {
      final client = StorageNodeClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        timeout: const Duration(seconds: 5),
        maxRetries: 0,
      );

      server.listen((request) {
        requestCount++;
        request.response
          ..statusCode = 500
          ..write('fail')
          ..close();
      });

      expect(
        () => client.getBlobMetadata(blobId: 'test'),
        throwsA(isA<InternalServerError>()),
      );

      client.close();
    });
  });
}
