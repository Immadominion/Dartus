library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/cache/blob_cache.dart';
import 'package:dartus/src/utils/hash.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late BlobCache cache;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cache_test_');
    cache = BlobCache(cacheDirectory: tempDir, maxSize: 3);
  });

  tearDown(() async {
    await cache.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('BlobCache', () {
    test('stores and retrieves blobs', () async {
      final blobId = 'test-blob-1';
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      await cache.put(blobId, data);
      final retrieved = await cache.get(blobId);

      expect(retrieved, equals(data));
    });

    test('returns null for non-existent blobs', () async {
      final retrieved = await cache.get('non-existent');
      expect(retrieved, isNull);
    });

    test('uses SHA-256 hash for filenames', () async {
      final blobId = 'test-blob-sha256';
      final data = Uint8List.fromList([1, 2, 3]);

      await cache.put(blobId, data);

      final expectedFilename = sha256Hex(blobId);
      final expectedFile = File(
        '${tempDir.path}${Platform.pathSeparator}$expectedFilename',
      );

      expect(await expectedFile.exists(), isTrue);
    });

    test('evicts oldest entry when maxSize exceeded', () async {
      final blob1 = 'blob-1';
      final blob2 = 'blob-2';
      final blob3 = 'blob-3';
      final blob4 = 'blob-4';

      await cache.put(blob1, Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put(blob2, Uint8List.fromList([2]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put(blob3, Uint8List.fromList([3]));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Cache now full (maxSize=3), adding blob4 should evict blob1
      await cache.put(blob4, Uint8List.fromList([4]));

      expect(await cache.get(blob1), isNull);
      expect(await cache.get(blob2), isNotNull);
      expect(await cache.get(blob3), isNotNull);
      expect(await cache.get(blob4), isNotNull);
    });

    test('updates access time on get', () async {
      final blob1 = 'blob-1';
      final blob2 = 'blob-2';
      final blob3 = 'blob-3';
      final blob4 = 'blob-4';

      await cache.put(blob1, Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put(blob2, Uint8List.fromList([2]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.put(blob3, Uint8List.fromList([3]));

      // Access blob1 to refresh its timestamp
      await cache.get(blob1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Adding blob4 should now evict blob2 (oldest), not blob1
      await cache.put(blob4, Uint8List.fromList([4]));

      expect(await cache.get(blob1), isNotNull);
      expect(await cache.get(blob2), isNull);
      expect(await cache.get(blob3), isNotNull);
      expect(await cache.get(blob4), isNotNull);
    });

    test('remove deletes blob from cache', () async {
      final blobId = 'test-blob';
      final data = Uint8List.fromList([1, 2, 3]);

      await cache.put(blobId, data);
      expect(await cache.get(blobId), isNotNull);

      await cache.remove(blobId);
      expect(await cache.get(blobId), isNull);
    });

    test('cleanup removes all cached files', () async {
      await cache.put('blob-1', Uint8List.fromList([1]));
      await cache.put('blob-2', Uint8List.fromList([2]));

      expect(await tempDir.exists(), isTrue);
      expect(tempDir.listSync().isNotEmpty, isTrue);

      await cache.cleanup();

      expect(await tempDir.exists(), isFalse);
    });

    test('handles corrupted cache files gracefully', () async {
      final blobId = 'corrupted-blob';
      final data = Uint8List.fromList([1, 2, 3]);

      final file = await cache.put(blobId, data);
      expect(await cache.get(blobId), isNotNull);

      // Corrupt the file by deleting it manually
      await file.delete();

      // Should return null and clean up index
      expect(await cache.get(blobId), isNull);
    });

    test('throws ArgumentError when maxSize is zero', () {
      expect(() {
        BlobCache(cacheDirectory: tempDir, maxSize: 0);
      }, throwsArgumentError);
    });

    test('creates temporary directory when none provided', () {
      final autoCache = BlobCache(maxSize: 5);
      expect(autoCache.directory.existsSync(), isTrue);
      expect(autoCache.directory.path, contains('walrus_cache_'));
    });
  });
}
