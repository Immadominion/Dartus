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

  final Map<String, DateTime> _accessTimes = <String, DateTime>{};

  /// The native cache directory.
  ///
  /// Only available on platforms with a filesystem; throws on the web.
  Directory get directory => _fileManager!;

  /// Returns cached bytes for [blobId] and refreshes its access time.
  Future<Uint8List?> get(String blobId) async {
    if (!_hasFileSystem) {
      final data = _memory[blobId];
      if (data == null) {
        return null;
      }
      _accessTimes[blobId] = DateTime.now();
      return Uint8List.fromList(data);
    }

    final file = _cacheIndex[blobId];
    if (file == null) {
      return null;
    }

    try {
      final data = await file.readAsBytes();
      _accessTimes[blobId] = DateTime.now();
      return Uint8List.fromList(data);
    } on FileSystemException {
      await remove(blobId);
      return null;
    }
  }

  /// Persists [data] for [blobId], evicting the oldest entry when full.
  ///
  /// Returns the backing [File] on native, or `null` on the web (in-memory).
  Future<File?> put(String blobId, List<int> data) async {
    if (maxSize <= 0) {
      throw StateError('maxSize must be greater than zero');
    }

    final count = _hasFileSystem ? _cacheIndex.length : _memory.length;
    if (count >= maxSize) {
      await _evictOldest();
    }

    if (!_hasFileSystem) {
      _memory[blobId] = Uint8List.fromList(data);
      _accessTimes[blobId] = DateTime.now();
      return null;
    }

    final fileName = sha256Hex(blobId);
    final file = File(
      '${_fileManager!.path}${Platform.pathSeparator}$fileName',
    );

    try {
      await file.writeAsBytes(data, flush: true);
      _cacheIndex[blobId] = file;
      _accessTimes[blobId] = DateTime.now();
      return file;
    } catch (error) {
      if (file.existsSync()) {
        await file.delete();
      }
      rethrow;
    }
  }

  /// Removes any stored bytes for [blobId].
  Future<void> remove(String blobId) async {
    _accessTimes.remove(blobId);
    if (!_hasFileSystem) {
      _memory.remove(blobId);
      return;
    }
    final file = _cacheIndex.remove(blobId);
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }

  /// Deletes every cached entry and clears in-memory tracking.
  Future<void> cleanup() async {
    _accessTimes.clear();
    if (!_hasFileSystem) {
      _memory.clear();
      return;
    }
    final dir = _fileManager;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _cacheIndex.clear();
  }

  /// Cleans up temporary caches when the cache lifecycle ends.
  Future<void> dispose() async {
    if (_cleanupOnDispose) {
      await cleanup();
    }
  }

  static Directory _createTemporaryCacheDir() {
    final tempDir = Directory.systemTemp;
    final cacheDir = tempDir.createTempSync('walrus_cache_');
    return cacheDir;
  }

  Future<void> _evictOldest() async {
    if (_accessTimes.isEmpty) {
      return;
    }

    String? oldestKey;
    DateTime? oldestTime;
    _accessTimes.forEach((key, timestamp) {
      if (oldestTime == null || timestamp.isBefore(oldestTime!)) {
        oldestKey = key;
        oldestTime = timestamp;
      }
    });

    if (oldestKey != null) {
      await remove(oldestKey!);
    }
  }
}
