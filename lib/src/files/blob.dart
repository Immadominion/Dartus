/// Walrus blob abstraction, mirroring the TS SDK's `files/blob.ts`.
///
/// [WalrusBlob] represents a stored blob on Walrus. It provides access
/// to the blob as a [WalrusFile] and can query its on-chain status.
/// For quilt-encoded blobs, use [WalrusBlob.files] to access individual files.
///
/// Example:
/// ```dart
/// // Via WalrusDirectClient
/// final blob = await client.getBlob(blobId: 'abc123...');
///
/// // As a single file
/// final file = blob.asFile();
/// final text = await file.text();
///
/// // As quilt files
/// final files = await blob.files();
/// for (final file in files) {
///   print(await file.text());
/// }
/// ```
library;

import 'dart:typed_data';

import '../files/readers/blob_reader.dart';
import '../models/storage_node_types.dart';
import 'file.dart';

/// A reader that wraps raw blob bytes.
///
/// Used by legacy [WalrusBlob] API to present a blob as a [WalrusFile].
class BlobFileReader implements WalrusFileReader {
  final String _blobId;
  final Future<Uint8List> Function() _bytesProvider;

  BlobFileReader({
    required String blobId,
    required Future<Uint8List> Function() bytesProvider,
  }) : _blobId = blobId,
       _bytesProvider = bytesProvider;

  @override
  Future<String?> getIdentifier() async => _blobId;

  @override
  Future<Map<String, String>> getTags() async => const {};

  @override
  Future<Uint8List> getBytes() => _bytesProvider();
}

/// Filter options for [WalrusBlob.files].
///
/// All filters are optional. When multiple filters are provided, a file
/// must match ALL specified criteria.
class WalrusBlobFilesFilter {
  /// Only include files whose patch ID is in this list.
  final List<String>? ids;

  /// Only include files matching at least one of these tag sets.
  /// A tag set matches if ALL its entries are present in the file's tags.
  final List<Map<String, String>>? tags;

  /// Only include files whose identifier is in this list.
  final List<String>? identifiers;

  const WalrusBlobFilesFilter({this.ids, this.tags, this.identifiers});
}

/// Represents a stored blob on Walrus with lazy content access.
///
/// Mirrors the TS SDK's `WalrusBlob` class from `files/blob.ts`.
///
/// Two construction modes:
/// - [WalrusBlob.fromReader] — backed by a [BlobReader] for full quilt
///   support (used by `WalrusDirectClient.getBlob`)
/// - [WalrusBlob] — legacy mode with a simple bytes provider (used
///   by existing Phase 1 callers)
class WalrusBlob {
  /// The blob's ID (URL-safe base64).
  final String blobId;

  /// Provider function to fetch the blob bytes (legacy mode).
  final Future<Uint8List> Function()? _bytesProvider;

  /// BlobReader for full quilt support (reader mode).
  final BlobReader? _reader;

  /// Reference to the direct client for status queries.
  final dynamic _client;

  /// Cached blob status.
  BlobStatus? _cachedStatus;

  /// Legacy constructor: creates a blob backed by a simple bytes provider.
  WalrusBlob({
    required this.blobId,
    required Future<Uint8List> Function() bytesProvider,
  }) : _bytesProvider = bytesProvider,
       _reader = null,
       _client = null;

  /// Reader constructor: creates a blob backed by a [BlobReader].
  ///
  /// Enables full quilt support via [files] method.
  /// [client] is the `WalrusDirectClient` for status queries.
  WalrusBlob.fromReader({required BlobReader reader, dynamic client})
    : blobId = reader.blobId,
      _reader = reader,
      _bytesProvider = null,
      _client = client;

  /// Get the blob as a [WalrusFile] (i.e. do not use Quilt encoding).
  ///
  /// Mirrors TS SDK `WalrusBlob.asFile()`.
  WalrusFile asFile() {
    if (_reader != null) {
      return WalrusFile(reader: _reader);
    }
    return WalrusFile(
      reader: BlobFileReader(blobId: blobId, bytesProvider: _bytesProvider!),
    );
  }

  /// Get quilt-based files from this blob.
  ///
  /// Reads the quilt index and returns [WalrusFile] instances for each
  /// file within the quilt. Supports filtering by IDs, tags, and
  /// identifiers.
  ///
  /// Requires the blob to have been created with [WalrusBlob.fromReader].
  ///
  /// Mirrors the TS SDK's `WalrusBlob.files()` with filter support.
  Future<List<WalrusFile>> files([WalrusBlobFilesFilter? filters]) async {
    if (_reader == null) {
      throw StateError(
        'files() requires a BlobReader-backed WalrusBlob. '
        'Use WalrusDirectClient.getBlob() to create one.',
      );
    }

    final quiltReader = _reader.getQuiltReader();
    final index = await quiltReader.readIndex();

    final result = <WalrusFile>[];

    for (final patch in index) {
      // Apply filters.
      if (filters != null) {
        if (filters.ids != null && !filters.ids!.contains(patch.patchId)) {
          continue;
        }

        if (filters.identifiers != null &&
            !filters.identifiers!.contains(patch.identifier)) {
          continue;
        }

        if (filters.tags != null) {
          final matchesAnyTagSet = filters.tags!.any((tagSet) {
            return tagSet.entries.every(
              (entry) => patch.tags[entry.key] == entry.value,
            );
          });
          if (!matchesAnyTagSet) continue;
        }
      }

      result.add(
        WalrusFile(reader: quiltReader.readerForPatchId(patch.patchId)),
      );
    }

    return result;
  }

  /// Check whether this blob is stored on Walrus.
  ///
  /// Accepts a status query function, or uses the client if available.
  /// Returns `true` if the blob is `permanent` or `deletable`.
  ///
  /// Mirrors TS SDK `WalrusBlob.exists()`.
  Future<bool> exists([
    Future<BlobStatus> Function(String blobId)? getVerifiedStatus,
  ]) async {
    final status = await _getStatus(getVerifiedStatus);
    return status is BlobStatusPermanent || status is BlobStatusDeletable;
  }

  /// Get the epoch until which the blob is stored, or `null` if not stored.
  ///
  /// Returns the `endEpoch` for `permanent` and `deletable` statuses.
  ///
  /// Mirrors TS SDK `WalrusBlob.storedUntil()`.
  Future<int?> storedUntil([
    Future<BlobStatus> Function(String blobId)? getVerifiedStatus,
  ]) async {
    final status = await _getStatus(getVerifiedStatus);
    if (status is BlobStatusPermanent) {
      return status.endEpoch;
    }
    return null;
  }

  /// Internal: resolve and cache blob status.
  Future<BlobStatus> _getStatus(
    Future<BlobStatus> Function(String blobId)? getVerifiedStatus,
  ) async {
    if (_cachedStatus != null) return _cachedStatus!;

    if (getVerifiedStatus != null) {
      _cachedStatus = await getVerifiedStatus(blobId);
    } else if (_client != null) {
      // Use the direct client's getVerifiedBlobStatus.
      final result = await _client.getVerifiedBlobStatus(blobId: blobId);
      _cachedStatus = result as BlobStatus;
    } else {
      throw StateError(
        'No status query function or client available. '
        'Pass a getVerifiedStatus function or create the blob '
        'via WalrusDirectClient.getBlob().',
      );
    }

    return _cachedStatus!;
  }
}
