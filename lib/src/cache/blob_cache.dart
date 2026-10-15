import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../utils/hash.dart';

/// `true` on platforms with a real filesystem (Dart VM / native), `false` on
/// the web. On web, `dart:io` `Directory`/`File` operations throw
/// `Unsupported operation` at runtime, so the cache falls back to in-memory.
const bool _hasFileSystem = bool.fromEnvironment('dart.library.io');

/// LRU cache for blob storage.
///
/// On native platforms blobs are stored as files in a directory, using
/// SHA-256 hashes of blob IDs as filenames. On the web — where `dart:io` is
/// unavailable at runtime — the cache transparently falls back to an
/// in-memory LRU store with the same API. Evicts the least recently accessed
/// entry when [maxSize] is exceeded.
/// Operations on one cache instance run in call order, including reads and
/// cleanup. Sharing a native cache directory between instances is unsupported.
///
/// ## Example
///
/// ```dart
/// final cache = BlobCache(
///   cacheDirectory: Directory('/path/to/cache'), // ignored on web
///   maxSize: 100,
/// );
///
/// // Store blob
/// await cache.put('blob-id-123', blobData);
///
/// // Retrieve blob
/// final data = await cache.get('blob-id-123');
///
/// // Clean up
/// await cache.dispose();
/// ```
///
/// When no [cacheDirectory] is provided on native, a temporary directory is
/// created and automatically cleaned up on [dispose].
class BlobCache {
  /// Creates a cache rooted at [cacheDirectory] or a temporary directory.
  ///
  /// On the web, [cacheDirectory] is ignored and storage is held in memory.
  /// The [maxSize] parameter sets the maximum number of blobs to store.
  /// When exceeded, the least recently accessed blob is evicted.
  ///
  /// Throws [ArgumentError] if [maxSize] is less than or equal to zero.
  BlobCache({Directory? cacheDirectory, this.maxSize = 100})
    : _cleanupOnDispose = cacheDirectory == null {
    if (maxSize <= 0) {
      throw ArgumentError.value(
        maxSize,
        'maxSize',
        'must be greater than zero',
      );
    }
    if (_hasFileSystem) {
      final dir = cacheDirectory ?? _createTemporaryCacheDir();
      _fileManager = dir;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    }
  }

  final int maxSize;
  final bool _cleanupOnDispose;

  /// Native cache directory; `null` on web.
  Directory? _fileManager;

  /// Native index of blob ID -> backing file.
  final Map<String, File> _cacheIndex = <String, File>{};

  /// Web in-memory store of blob ID -> bytes.
  final Map<String, Uint8List> _memory = <String, Uint8List>{};

  // Dart sets preserve insertion order, avoiding clock-resolution ties in LRU.
  final Set<String> _accessOrder = <String>{};
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  /// The native cache directory.
  ///
  /// Only available on platforms with a filesystem; throws on the web.
  Directory get directory =>
      _fileManager ?? (throw UnsupportedError('No cache directory on the web'));

  /// Returns cached bytes for [blobId] and refreshes its access time.
  Future<Uint8List?> get(String blobId) => _run(() async {
    if (!_hasFileSystem) {
      final data = _memory[blobId];
      if (data == null) {
        return null;
      }
      _touch(blobId);
      return Uint8List.fromList(data);
    }

    final file = _cacheIndex[blobId];
    if (file == null) {
      return null;
    }

    try {
      final data = await file.readAsBytes();
      _touch(blobId);
      return Uint8List.fromList(data);
    } on FileSystemException {
      await _remove(blobId);
      return null;
    }
  });

  /// Persists [data] for [blobId], evicting the oldest entry when full.
  ///
  /// Returns the backing [File] on native, or `null` on the web (in-memory).
  /// Overwrites refresh recency without evicting unrelated entries. Native
  /// writes replace the previous file only after the new bytes are complete.
  Future<File?> put(String blobId, List<int> data) => _run(() async {
    if (!_hasFileSystem) {
      _memory[blobId] = Uint8List.fromList(data);
      _touch(blobId);
      await _trimToSize();
      return null;
    }

    // cleanup() removes the directory but leaves this cache reusable.
    await _fileManager!.create(recursive: true);
    final fileName = sha256Hex(blobId);
    final file = File(
      '${_fileManager!.path}${Platform.pathSeparator}$fileName',
    );

    final pendingFile = File('${file.path}.pending');
    try {
      await pendingFile.writeAsBytes(data, flush: true);
      await pendingFile.rename(file.path);
      _cacheIndex[blobId] = file;
      _touch(blobId);
      await _trimToSize();
      return file;
    } finally {
      if (await pendingFile.exists()) {
        await pendingFile.delete();
      }
    }
  });

  /// Removes any stored bytes for [blobId].
  Future<void> remove(String blobId) => _run(() => _remove(blobId));

  Future<void> _remove(String blobId) async {
    if (!_hasFileSystem) {
      _memory.remove(blobId);
    } else {
      final file = _cacheIndex[blobId];
      if (file != null && await file.exists()) {
        await file.delete();
      }
      _cacheIndex.remove(blobId);
    }
    _accessOrder.remove(blobId);
  }

  /// Deletes every cached entry and clears in-memory tracking.
  /// The cache can be used again after cleanup completes.
  Future<void> cleanup() => _run(_cleanup);

  Future<void> _cleanup() async {
    if (!_hasFileSystem) {
      _memory.clear();
    } else {
      final dir = _fileManager;
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _cacheIndex.clear();
    }
    _accessOrder.clear();
  }

  /// Cleans up temporary caches when the cache lifecycle ends.
  /// Waits for pending operations. Later operations fail with [StateError].
  /// Calling dispose more than once is safe. User-provided directories remain.
  Future<void> dispose() => _enqueue(() async {
    if (_disposed) {
      return;
    }
    if (_cleanupOnDispose) {
      await _cleanup();
    }
    _memory.clear();
    _cacheIndex.clear();
    _accessOrder.clear();
    _disposed = true;
  });

  static Directory _createTemporaryCacheDir() {
    final tempDir = Directory.systemTemp;
    final cacheDir = tempDir.createTempSync('walrus_cache_');
    return cacheDir;
  }

  void _touch(String blobId) {
    _accessOrder.remove(blobId);
    _accessOrder.add(blobId);
  }

  Future<void> _trimToSize() async {
    while (_accessOrder.length > maxSize) {
      await _remove(_accessOrder.first);
    }
  }

  Future<T> _run<T>(FutureOr<T> Function() operation) => _enqueue(() {
    if (_disposed) {
      throw StateError('BlobCache has been disposed');
    }
    return operation();
  });

  Future<T> _enqueue<T>(FutureOr<T> Function() operation) {
    final result = _pending.then((_) => operation());
    // A failed operation must not prevent the next one from running. The
    // caller still receives the original error through result.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
