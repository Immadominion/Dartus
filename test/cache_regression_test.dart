import 'dart:io';

import 'package:dartus/src/cache/blob_cache.dart';
import 'package:dartus/src/utils/hash.dart';
import 'package:test/test.dart';

const _hasFileSystem = bool.fromEnvironment('dart.library.io');

void main() {
  late BlobCache cache;

  setUp(() {
    cache = BlobCache(maxSize: 2);
  });

  tearDown(() async {
    await cache.dispose();
  });

  test('overwriting a full cache keeps the unrelated entry', () async {
    await cache.put('a', [1]);
    await cache.put('b', [2]);
    await cache.put('b', [3]);

    expect(await cache.get('a'), [1]);
    expect(await cache.get('b'), [3]);
  });

  test('overwriting refreshes recency before the next eviction', () async {
    await cache.put('a', [1]);
    await cache.put('b', [2]);
    await cache.put('a', [3]);
    await cache.put('c', [4]);

    expect(await cache.get('b'), isNull);
    expect(await cache.get('a'), [3]);
    expect(await cache.get('c'), [4]);
  });

  test('reading refreshes recency without relying on clock delays', () async {
    await cache.put('a', [1]);
    await cache.put('b', [2]);
    expect(await cache.get('a'), [1]);
    await cache.put('c', [3]);

    expect(await cache.get('b'), isNull);
    expect(await cache.get('a'), [1]);
    expect(await cache.get('c'), [3]);
  });

  test('concurrent writes respect capacity and keep readable data', () async {
    await cache.dispose();
    cache = BlobCache(maxSize: 1);
    await Future.wait([
      for (var i = 0; i < 5; i++) cache.put('blob-$i', [i]),
    ]);

    if (_hasFileSystem) {
      expect(await cache.directory.list().length, 1);
    }
    for (var i = 0; i < 4; i++) {
      expect(await cache.get('blob-$i'), isNull);
    }
    expect(await cache.get('blob-4'), [4]);
  });

  test(
    'concurrent same-key writes finish with the last complete value',
    () async {
      final payloads = [
        for (var i = 0; i < 5; i++) List<int>.filled(8192 + i, i),
      ];
      await Future.wait([
        for (final payload in payloads) cache.put('shared', payload),
      ]);

      expect(await cache.get('shared'), payloads.last);
      if (_hasFileSystem) {
        expect(await cache.directory.list().length, 1);
      }
    },
  );

  test('a read waits for a previously queued write', () async {
    final write = cache.put('a', [1, 2, 3]);
    final read = cache.get('a');

    await write;
    expect(await read, [1, 2, 3]);
  });

  test('cleanup waits for pending writes and allows cache reuse', () async {
    final write = cache.put('a', [1]);
    final cleanup = cache.cleanup();
    await write;
    await cleanup;

    expect(await cache.get('a'), isNull);
    if (_hasFileSystem) {
      expect(await cache.directory.exists(), isFalse);
    }
    await cache.put('b', [2]);
    expect(await cache.get('b'), [2]);
  });

  test(
    'dispose waits for pending writes and removes temporary storage',
    () async {
      final write = cache.put('a', [1]);
      final dispose = cache.dispose();
      await write;
      await dispose;

      if (_hasFileSystem) {
        expect(await cache.directory.exists(), isFalse);
      }
    },
  );

  test('dispose is idempotent and rejects later operations', () async {
    await cache.dispose();
    await cache.dispose();

    await expectLater(cache.put('late', [1]), throwsStateError);
    await expectLater(cache.get('late'), throwsStateError);
    await expectLater(cache.remove('late'), throwsStateError);
    await expectLater(cache.cleanup(), throwsStateError);
    if (_hasFileSystem) {
      expect(await cache.directory.exists(), isFalse);
    }
  });

  if (_hasFileSystem) {
    test(
      'a failed overwrite leaves the previously cached bytes intact',
      () async {
        await cache.put('keep', [1, 2, 3]);
        final blockedPendingFile = Directory(
          '${cache.directory.path}${Platform.pathSeparator}'
          '${sha256Hex('keep')}.pending',
        );
        await blockedPendingFile.create();

        await expectLater(
          cache.put('keep', [9]),
          throwsA(isA<FileSystemException>()),
        );
        expect(await cache.get('keep'), [1, 2, 3]);

        await blockedPendingFile.delete();
        await cache.put('keep', [4]);
        expect(await cache.get('keep'), [4]);
      },
    );

    test(
      'a failed write preserves entries and releases the operation queue',
      () async {
        await cache.dispose();
        cache = BlobCache(maxSize: 1);
        await cache.put('keep', [1]);
        final blockedPath = Directory(
          '${cache.directory.path}${Platform.pathSeparator}${sha256Hex('blocked')}',
        );
        await blockedPath.create();

        final failedWrite = expectLater(
          cache.put('blocked', [9]),
          throwsA(isA<FileSystemException>()),
        );
        final queuedRead = cache.get('keep');
        await failedWrite;
        expect(await queuedRead, [1]);

        await cache.put('next', [2]);
        expect(await cache.get('keep'), isNull);
        expect(await cache.get('next'), [2]);
        expect(
          await cache.directory.list().where((entry) => entry is File).length,
          1,
        );
      },
    );
  }
}
