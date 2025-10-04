import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../utils/hash.dart';

/// Stores blobs on disk using SHA-256 filenames, mirroring the Swift cache.
class BlobCache {
  /// Creates a cache rooted at [cacheDirectory] or a temporary directory.
  BlobCache({Directory? cacheDirectory, this.maxSize = 100})
    : _fileManager = cacheDirectory ?? _createTemporaryCacheDir(),
      _cleanupOnDispose = cacheDirectory == null {
    if (!_fileManager.existsSync()) {
      _fileManager.createSync(recursive: true);
    }
  }

  final Directory _fileManager;
  final int maxSize;
  final bool _cleanupOnDispose;
  final Map<String, File> _cacheIndex = <String, File>{};
  final Map<String, DateTime> _accessTimes = <String, DateTime>{};

  Directory get directory => _fileManager;

  /// Returns cached bytes for [blobId] and refreshes its access time.
  Future<Uint8List?> get(String blobId) async {
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
  Future<File> put(String blobId, List<int> data) async {
    if (maxSize <= 0) {
      throw StateError('maxSize must be greater than zero');
    }

    if (_cacheIndex.length >= maxSize) {
      await _evictOldest();
    }

    final fileName = sha256Hex(blobId);
    final file = File('${_fileManager.path}${Platform.pathSeparator}$fileName');

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
    final file = _cacheIndex.remove(blobId);
    _accessTimes.remove(blobId);
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }

  /// Deletes every cached file and clears in-memory tracking.
  Future<void> cleanup() async {
    if (await _fileManager.exists()) {
      await _fileManager.delete(recursive: true);
    }
    _cacheIndex.clear();
    _accessTimes.clear();
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
    if (_cacheIndex.isEmpty) {
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
