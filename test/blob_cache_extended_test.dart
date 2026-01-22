library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/cache/blob_cache.dart';
import 'package:test/test.dart';

void main() {
  group('BlobCache - File Operations', () {
    late Directory tempDir;
    late BlobCache cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('file_ops_test_');
      cache = BlobCache(cacheDirectory: tempDir, maxSize: 10);
    });

    tearDown(() async {
      await cache.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles concurrent put operations', () async {
      final futures = <Future<File>>[];

      for (var i = 0; i < 5; i++) {
        futures.add(cache.put('blob-$i', Uint8List.fromList([i])));
      }

      await Future.wait(futures);

      // Verify all blobs were stored
      for (var i = 0; i < 5; i++) {
        final data = await cache.get('blob-$i');
        expect(data, isNotNull);
        expect(data!.first, equals(i));
      }
    });

    test('handles concurrent get operations', () async {
      // Pre-populate cache
      await cache.put('shared-blob', Uint8List.fromList([1, 2, 3]));

      // Concurrent reads
      final futures = <Future<Uint8List?>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(cache.get('shared-blob'));
      }

      final results = await Future.wait(futures);

      for (final result in results) {
        expect(result, equals(Uint8List.fromList([1, 2, 3])));
      }
    });

    test('handles put followed by immediate get', () async {
      final data = Uint8List.fromList([10, 20, 30, 40, 50]);

      await cache.put('immediate-blob', data);
      final retrieved = await cache.get('immediate-blob');

      expect(retrieved, equals(data));
    });

    test('handles overwriting existing blob', () async {
      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6, 7, 8]);

      await cache.put('overwrite-blob', data1);
      await cache.put('overwrite-blob', data2);

      final retrieved = await cache.get('overwrite-blob');
      expect(retrieved, equals(data2));
    });

    test('handles special characters in blob ID', () async {
      final blobId = 'blob/with:special@chars#and%percent';
      final data = Uint8List.fromList([1, 2, 3]);

      await cache.put(blobId, data);
      final retrieved = await cache.get(blobId);

      expect(retrieved, equals(data));
    });

    test('handles very long blob ID', () async {
      final blobId = 'a' * 1000; // 1000 character blob ID
      final data = Uint8List.fromList([1, 2, 3]);

      await cache.put(blobId, data);
      final retrieved = await cache.get(blobId);

      expect(retrieved, equals(data));
    });

    test('handles empty blob ID', () async {
      final data = Uint8List.fromList([1, 2, 3]);

      // Empty string is a valid key (gets hashed to a valid filename)
      await cache.put('', data);
      final retrieved = await cache.get('');

      expect(retrieved, equals(data));
    });

    test('handles Unicode blob ID', () async {
      final blobId = 'blob-日本語-🎉-αβγ';
      final data = Uint8List.fromList([1, 2, 3]);

      await cache.put(blobId, data);
      final retrieved = await cache.get(blobId);

      expect(retrieved, equals(data));
    });
  });

  group('BlobCache - Data Edge Cases', () {
    late Directory tempDir;
    late BlobCache cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('data_edge_test_');
      cache = BlobCache(cacheDirectory: tempDir, maxSize: 10);
    });

    tearDown(() async {
      await cache.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles empty data', () async {
      final data = Uint8List(0);

      await cache.put('empty-data', data);
      final retrieved = await cache.get('empty-data');

      expect(retrieved, isNotNull);
      expect(retrieved, isEmpty);
    });

    test('handles single byte data', () async {
      final data = Uint8List.fromList([42]);

      await cache.put('single-byte', data);
      final retrieved = await cache.get('single-byte');

      expect(retrieved, equals(data));
    });

    test('handles data with null bytes', () async {
      final data = Uint8List.fromList([0, 0, 0, 1, 0, 0, 0]);

      await cache.put('null-bytes', data);
      final retrieved = await cache.get('null-bytes');

      expect(retrieved, equals(data));
    });

    test('handles data with all possible byte values', () async {
      final data = Uint8List.fromList(List.generate(256, (i) => i));

      await cache.put('all-bytes', data);
      final retrieved = await cache.get('all-bytes');

      expect(retrieved, equals(data));
    });

    test('handles moderately large data (1MB)', () async {
      final data = Uint8List(1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      await cache.put('large-blob', data);
      final retrieved = await cache.get('large-blob');

      expect(retrieved, equals(data));
    });
  });

  group('BlobCache - Eviction Behavior', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('eviction_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('evicts oldest blob when cache is full', () async {
      final cache = BlobCache(cacheDirectory: tempDir, maxSize: 3);

      await cache.put('blob-1', Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put('blob-2', Uint8List.fromList([2]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put('blob-3', Uint8List.fromList([3]));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // This should evict blob-1
      await cache.put('blob-4', Uint8List.fromList([4]));

      expect(await cache.get('blob-1'), isNull);
      expect(await cache.get('blob-2'), isNotNull);
      expect(await cache.get('blob-3'), isNotNull);
      expect(await cache.get('blob-4'), isNotNull);

      await cache.dispose();
    });

    test('LRU updates on access', () async {
      final cache = BlobCache(cacheDirectory: tempDir, maxSize: 3);

      await cache.put('blob-1', Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put('blob-2', Uint8List.fromList([2]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put('blob-3', Uint8List.fromList([3]));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Access blob-1 to make it recently used
      await cache.get('blob-1');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // This should evict blob-2 (now oldest)
      await cache.put('blob-4', Uint8List.fromList([4]));

      expect(await cache.get('blob-1'), isNotNull);
      expect(await cache.get('blob-2'), isNull);
      expect(await cache.get('blob-3'), isNotNull);
      expect(await cache.get('blob-4'), isNotNull);

      await cache.dispose();
    });

    test('handles maxSize of 1', () async {
      final cache = BlobCache(cacheDirectory: tempDir, maxSize: 1);

      await cache.put('blob-1', Uint8List.fromList([1]));
      expect(await cache.get('blob-1'), isNotNull);

      await cache.put('blob-2', Uint8List.fromList([2]));
      expect(await cache.get('blob-1'), isNull);
      expect(await cache.get('blob-2'), isNotNull);

      await cache.dispose();
    });

    test('handles rapid sequential evictions', () async {
      final cache = BlobCache(cacheDirectory: tempDir, maxSize: 2);

      for (var i = 0; i < 10; i++) {
        await cache.put('blob-$i', Uint8List.fromList([i]));
      }

      // Only the last 2 should remain
      for (var i = 0; i < 8; i++) {
        expect(await cache.get('blob-$i'), isNull);
      }
      expect(await cache.get('blob-8'), isNotNull);
      expect(await cache.get('blob-9'), isNotNull);

      await cache.dispose();
    });
  });

  group('BlobCache - Error Recovery', () {
    late Directory tempDir;
    late BlobCache cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('recovery_test_');
      cache = BlobCache(cacheDirectory: tempDir, maxSize: 10);
    });

    tearDown(() async {
      await cache.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles missing file gracefully', () async {
      await cache.put('missing-file-blob', Uint8List.fromList([1, 2, 3]));

      // Manually delete the file
      final files = tempDir.listSync().whereType<File>();
      for (final file in files) {
        await file.delete();
      }

      // Should return null without throwing
      final result = await cache.get('missing-file-blob');
      expect(result, isNull);
    });

    test('cleanup removes all files', () async {
      await cache.put('blob-1', Uint8List.fromList([1]));
      await cache.put('blob-2', Uint8List.fromList([2]));
      await cache.put('blob-3', Uint8List.fromList([3]));

      await cache.cleanup();

      expect(await tempDir.exists(), isFalse);
    });

    test('remove deletes specific blob', () async {
      await cache.put('keep-blob', Uint8List.fromList([1]));
      await cache.put('remove-blob', Uint8List.fromList([2]));

      await cache.remove('remove-blob');

      expect(await cache.get('keep-blob'), isNotNull);
      expect(await cache.get('remove-blob'), isNull);
    });

    test('remove handles non-existent blob', () async {
      // Should not throw
      await expectLater(cache.remove('does-not-exist'), completes);
    });
  });

  group('BlobCache - Initialization', () {
    test('creates temporary directory when none provided', () {
      final cache = BlobCache(maxSize: 5);

      expect(cache.directory.existsSync(), isTrue);
      expect(cache.directory.path, contains('walrus_cache_'));

      cache.dispose();
    });

    test('uses provided directory', () async {
      final customDir = await Directory.systemTemp.createTemp('custom_cache_');

      final cache = BlobCache(cacheDirectory: customDir, maxSize: 5);

      expect(cache.directory.path, equals(customDir.path));

      await cache.dispose();
      if (await customDir.exists()) {
        await customDir.delete(recursive: true);
      }
    });

    test('throws ArgumentError for maxSize <= 0', () {
      expect(() => BlobCache(maxSize: 0), throwsArgumentError);

      expect(() => BlobCache(maxSize: -1), throwsArgumentError);
    });

    test('exposes maxSize property', () {
      final cache = BlobCache(maxSize: 42);

      expect(cache.maxSize, equals(42));

      cache.dispose();
    });
  });
}
