/// Blob reader for Walrus blob data with quilt support.
///
/// Mirrors the TS SDK's `files/readers/blob.ts`.
///
/// A [BlobReader] provides lazy access to blob bytes and secondary
/// slivers. It serves as the foundation for quilt reading — the
/// [QuiltReader] uses a [BlobReader] to access data.
///
/// The reader delegates actual data fetching to callback functions,
/// keeping it decoupled from the client implementation.
library;

import 'dart:typed_data';

import '../../utils/encoding_utils.dart';
import '../file.dart';
import 'quilt_reader.dart';

/// A reader that lazily fetches blob data from Walrus storage nodes.
///
/// Mirrors the TS SDK's `BlobReader` from `files/readers/blob.ts`.
///
/// Supports two modes of data access:
/// 1. Full blob read (via [getBytes])
/// 2. Secondary sliver access (via [getSecondarySliver])
///
/// These enable the [QuiltReader] to either read the entire blob
/// and extract patches, or read individual slivers for efficient
/// random access.
///
/// Usage:
/// ```dart
/// final reader = BlobReader(
///   blobId: 'abc123...',
///   numShards: 1000,
///   readBlob: (blobId) => client.readBlob(blobId),
///   readSecondarySliver: (blobId, index) =>
///       client.getSecondarySliver(blobId: blobId, index: index),
///   readMetadata: (blobId) =>
///       client.getBlobMetadata(blobId: blobId),
/// );
///
/// // Use directly as a file reader:
/// final file = WalrusFile(reader: reader);
/// final bytes = await file.bytes();
///
/// // Or use with quilt reader:
/// final quiltReader = reader.getQuiltReader();
/// final index = await quiltReader.readIndex();
/// ```
class BlobReader implements WalrusFileReader {
  /// The blob's ID (URL-safe base64).
  final String blobId;

  /// Number of shards in the Walrus committee.
  final int _numShards;

  /// Callback to read the full blob data.
  final Future<Uint8List> Function(String blobId) _readBlob;

  /// Callback to read a secondary sliver by index.
  final Future<Uint8List> Function(String blobId, int sliverIndex)
  _readSecondarySliver;

  /// Callback to read blob metadata (returns unencoded length).
  final Future<int> Function(String blobId)? _readUnencodedLength;

  /// Whether we've started loading the full blob. Used by QuiltReader
  /// to decide whether to use slivers or the full blob.
  bool hasStartedLoadingFullBlob = false;

  /// Cached full blob bytes.
  Uint8List? _cachedBytes;
  Future<Uint8List>? _bytesLoading;

  /// Cached column size.
  int? _cachedColumnSize;

  /// Cache for secondary slivers.
  final Map<int, Future<Uint8List>> _secondarySlivers = {};

  BlobReader({
    required this.blobId,
    required int numShards,
    required Future<Uint8List> Function(String blobId) readBlob,
    required Future<Uint8List> Function(String blobId, int sliverIndex)
    readSecondarySliver,
    Future<int> Function(String blobId)? readUnencodedLength,
  }) : _numShards = numShards,
       _readBlob = readBlob,
       _readSecondarySliver = readSecondarySliver,
       _readUnencodedLength = readUnencodedLength;

  @override
  Future<String?> getIdentifier() async => null;

  @override
  Future<Map<String, String>> getTags() async => const {};

  /// Get a [QuiltReader] for reading quilt-structured data from this blob.
  QuiltReader getQuiltReader() => QuiltReader(blob: this);

  @override
  Future<Uint8List> getBytes() async {
    if (_cachedBytes != null) return _cachedBytes!;

    _bytesLoading ??= _loadBytes();
    _cachedBytes = await _bytesLoading;
    return _cachedBytes!;
  }

  Future<Uint8List> _loadBytes() async {
    hasStartedLoadingFullBlob = true;
    try {
      return await _readBlob(blobId);
    } catch (e) {
      hasStartedLoadingFullBlob = false;
      rethrow;
    }
  }

  /// Get a secondary sliver by index.
  ///
  /// Results are cached: subsequent calls with the same index return the
  /// same future. If the request fails, the cache entry is removed.
  Future<Uint8List> getSecondarySliver({required int sliverIndex}) {
    if (_secondarySlivers.containsKey(sliverIndex)) {
      return _secondarySlivers[sliverIndex]!;
    }

    final future = _fetchSliver(sliverIndex);
    _secondarySlivers[sliverIndex] = future;
    return future;
  }

  Future<Uint8List> _fetchSliver(int sliverIndex) async {
    try {
      return await _readSecondarySliver(blobId, sliverIndex);
    } catch (e) {
      _secondarySlivers.remove(sliverIndex);
      rethrow;
    }
  }

  /// Get the column size for this blob.
  ///
  /// Tries to determine the column size from:
  /// 1. Any already-loaded secondary sliver (fastest)
  /// 2. The full blob data (if loading has started)
  /// 3. Blob metadata from the network
  Future<int> getColumnSize() async {
    if (_cachedColumnSize != null) return _cachedColumnSize!;

    // Try to get column size from any loaded sliver.
    for (final entry in _secondarySlivers.entries) {
      try {
        final sliver = await entry.value;
        _cachedColumnSize = sliver.length;
        return _cachedColumnSize!;
      } catch (_) {
        continue;
      }
    }

    // Try from the full blob.
    if (hasStartedLoadingFullBlob) {
      final blob = await getBytes();
      final sizes = getSizes(blob.length, _numShards);
      _cachedColumnSize = sizes.columnSize;
      return _cachedColumnSize!;
    }

    // Get from metadata.
    if (_readUnencodedLength != null) {
      final unencodedLength = await _readUnencodedLength(blobId);
      final sizes = getSizes(unencodedLength, _numShards);
      _cachedColumnSize = sizes.columnSize;
      return _cachedColumnSize!;
    }

    // Fallback: read the full blob.
    final blob = await getBytes();
    final sizes = getSizes(blob.length, _numShards);
    _cachedColumnSize = sizes.columnSize;
    return _cachedColumnSize!;
  }

  /// Get the symbol size for this blob.
  Future<int> getSymbolSize() async {
    final columnSize = await getColumnSize();
    final src = getSourceSymbols(_numShards);

    if (columnSize % src.primary != 0) {
      throw StateError(
        'Column size ($columnSize) should be divisible by primary symbols (${src.primary})',
      );
    }

    return columnSize ~/ src.primary;
  }

  /// Get the row size for this blob.
  Future<int> getRowSize() async {
    final symbolSize = await getSymbolSize();
    final src = getSourceSymbols(_numShards);
    return symbolSize * src.secondary;
  }
}
