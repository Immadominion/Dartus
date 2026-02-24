/// Tests for SuiObjectDataLoader batching and caching logic.
///
/// These tests verify the caching, batch deduplication, and error
/// handling of the SuiObjectDataLoader without requiring a real
/// Sui network connection.
library;

import 'dart:async';

import 'package:dartus/src/utils/object_data_loader.dart';
import 'package:sui/sui.dart';
import 'package:test/test.dart';

/// A minimal mock SuiClient that records multiGetObjects calls.
///
/// We extend SuiClient with a testnet URL but override multiGetObjects
/// to return synthetic responses without actual network calls.
class MockSuiClient extends SuiClient {
  final List<List<String>> multiGetCalls = [];
  final Map<String, SuiObjectResponse> mockResponses = {};
  bool throwOnFetch = false;

  MockSuiClient() : super(SuiUrls.testnet);

  @override
  Future<List<SuiObjectResponse>> multiGetObjects(
    List<String> objectIds, {
    SuiObjectDataOptions? options,
  }) async {
    multiGetCalls.add(List.of(objectIds));

    if (throwOnFetch) {
      throw Exception('Mock network error');
    }

    return objectIds.map((id) {
      return mockResponses[id] ?? _emptyResponse(id);
    }).toList();
  }

  static SuiObjectResponse _emptyResponse(String objectId) {
    return SuiObjectResponse.fromJson({
      'data': {
        'objectId': objectId,
        'version': '1',
        'digest': 'mock_digest_$objectId',
        'type': 'mock::type::Type',
        'content': {
          'dataType': 'moveObject',
          'type': 'mock::type::Type',
          'fields': <String, dynamic>{},
        },
      },
    });
  }

  void setMockResponse(String objectId, SuiObjectResponse response) {
    mockResponses[objectId] = response;
  }
}

void main() {
  group('SuiObjectDataLoader', () {
    late MockSuiClient mockClient;
    late SuiObjectDataLoader loader;

    setUp(() {
      mockClient = MockSuiClient();
      loader = SuiObjectDataLoader(suiClient: mockClient);
    });

    group('load()', () {
      test('fetches object from network on first call', () async {
        final result = await loader.load('0xabc');

        expect(result.data?.objectId, equals('0xabc'));
        expect(mockClient.multiGetCalls.length, equals(1));
        expect(mockClient.multiGetCalls.first, contains('0xabc'));
      });

      test('returns cached object on subsequent calls', () async {
        // First call — network fetch.
        await loader.load('0xabc');
        expect(mockClient.multiGetCalls.length, equals(1));

        // Second call — should use cache.
        final cached = await loader.load('0xabc');
        expect(cached.data?.objectId, equals('0xabc'));
        // No additional network call.
        expect(mockClient.multiGetCalls.length, equals(1));
      });

      test('batches concurrent loads into single RPC call', () async {
        // Launch two loads in the same microtask cycle.
        final results = await Future.wait([
          loader.load('0x111'),
          loader.load('0x222'),
        ]);

        // Both should be resolved.
        expect(results[0].data?.objectId, equals('0x111'));
        expect(results[1].data?.objectId, equals('0x222'));

        // Should have been fetched in a single multiget call.
        expect(mockClient.multiGetCalls.length, equals(1));
        expect(mockClient.multiGetCalls.first, contains('0x111'));
        expect(mockClient.multiGetCalls.first, contains('0x222'));
      });

      test('deduplicates same ID in concurrent loads', () async {
        final results = await Future.wait([
          loader.load('0xsame'),
          loader.load('0xsame'),
          loader.load('0xsame'),
        ]);

        // All three should resolve to the same object.
        for (final r in results) {
          expect(r.data?.objectId, equals('0xsame'));
        }

        // Only one RPC call with one ID.
        expect(mockClient.multiGetCalls.length, equals(1));
        expect(mockClient.multiGetCalls.first.length, equals(1));
      });
    });

    group('loadMany()', () {
      test('fetches multiple objects in single RPC call', () async {
        final results = await loader.loadMany(['0xa', '0xb', '0xc']);

        expect(results.length, equals(3));
        expect(results[0].data?.objectId, equals('0xa'));
        expect(results[1].data?.objectId, equals('0xb'));
        expect(results[2].data?.objectId, equals('0xc'));
        expect(mockClient.multiGetCalls.length, equals(1));
      });

      test('uses cache for already-loaded objects', () async {
        // Pre-load one object.
        await loader.load('0xb');
        expect(mockClient.multiGetCalls.length, equals(1));

        // Now load three, one already cached.
        final results = await loader.loadMany(['0xa', '0xb', '0xc']);

        expect(results.length, equals(3));
        // Should only fetch the two uncached objects.
        expect(mockClient.multiGetCalls.length, equals(2));
        expect(mockClient.multiGetCalls[1], isNot(contains('0xb')));
      });

      test('returns immediately if all objects are cached', () async {
        await loader.loadMany(['0xa', '0xb']);
        expect(mockClient.multiGetCalls.length, equals(1));

        final results = await loader.loadMany(['0xa', '0xb']);
        expect(results.length, equals(2));
        // No additional RPC call.
        expect(mockClient.multiGetCalls.length, equals(1));
      });
    });

    group('loadManyOrThrow()', () {
      test('throws on missing objects', () async {
        mockClient.setMockResponse(
          '0xmissing',
          SuiObjectResponse.fromJson({
            'error': {'code': 'notExists', 'object_id': '0xmissing'},
          }),
        );

        expect(() => loader.loadManyOrThrow(['0xmissing']), throwsStateError);
      });

      test('succeeds when all objects exist', () async {
        final results = await loader.loadManyOrThrow(['0xa', '0xb']);
        expect(results.length, equals(2));
      });
    });

    group('clearAll()', () {
      test('clears cache forcing re-fetch', () async {
        await loader.load('0xabc');
        expect(mockClient.multiGetCalls.length, equals(1));

        loader.clearAll();
        expect(loader.cacheSize, equals(0));

        await loader.load('0xabc');
        // Should have re-fetched.
        expect(mockClient.multiGetCalls.length, equals(2));
      });
    });

    group('clear()', () {
      test('clears single object from cache', () async {
        await loader.loadMany(['0xa', '0xb']);
        expect(loader.cacheSize, equals(2));

        loader.clear('0xa');
        expect(loader.cacheSize, equals(1));

        // Re-load — only 0xa should trigger new fetch.
        await loader.loadMany(['0xa', '0xb']);
        expect(mockClient.multiGetCalls.length, equals(2));
        expect(mockClient.multiGetCalls[1], equals(['0xa']));
      });
    });

    group('error handling', () {
      test('propagates network errors to all pending loads', () async {
        mockClient.throwOnFetch = true;

        expect(() => loader.load('0xerror'), throwsException);
      });

      test('allows retry after error', () async {
        mockClient.throwOnFetch = true;

        try {
          await loader.load('0xretry');
        } catch (_) {
          // Expected.
        }

        // Re-enable and retry.
        mockClient.throwOnFetch = false;
        final result = await loader.load('0xretry');
        expect(result.data?.objectId, equals('0xretry'));
      });
    });
  });
}
