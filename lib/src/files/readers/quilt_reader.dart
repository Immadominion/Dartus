/// Quilt reader for accessing individual files within a quilt blob.
///
/// Mirrors the TS SDK's `files/readers/quilt.ts`.
///
/// A [QuiltReader] reads the quilt index from the blob and provides
/// access to individual patches (files) within the quilt. It supports
/// two read strategies:
/// 1. Reading secondary slivers directly (efficient for small reads)
/// 2. Falling back to the full blob (when slivers fail)
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../utils/quilts.dart';
import 'blob_reader.dart';
import 'quilt_file_reader.dart';

/// Header information for a blob within a quilt.
class QuiltBlobHeader {
  final String identifier;
  final Map<String, String>? tags;
  final int blobSize;
  final int contentOffset;

  const QuiltBlobHeader({
    required this.identifier,
    this.tags,
    required this.blobSize,
    required this.contentOffset,
  });
}

/// Result of reading a blob from a quilt.
class QuiltBlobReadResult {
  final String identifier;
  final Map<String, String>? tags;
  final Uint8List blobContents;

  const QuiltBlobReadResult({
    required this.identifier,
    this.tags,
    required this.blobContents,
  });
}

/// Entry in the quilt index for a patch.
class QuiltIndexEntry {
  final String identifier;
  final String patchId;
  final Map<String, String> tags;
  final QuiltFileReader reader;

  const QuiltIndexEntry({
    required this.identifier,
    required this.patchId,
    required this.tags,
    required this.reader,
  });
}

/// Reads the structure of a quilt blob and provides access to patches.
///
/// Mirrors the TS SDK's `QuiltReader` from `files/readers/quilt.ts`.
///
/// Usage:
/// ```dart
/// final quiltReader = QuiltReader(blob: blobReader);
/// final index = await quiltReader.readIndex();
/// for (final entry in index) {
///   final file = WalrusFile(reader: entry.reader);
///   final text = await file.text();
/// }
/// ```
class QuiltReader {
  final BlobReader _blob;
  final Map<int, QuiltBlobHeader> _headerCache = {};

  QuiltReader({required BlobReader blob}) : _blob = blob;

  // -------------------------------------------------------------------------
  // Reading Bytes
  // -------------------------------------------------------------------------

  /// Read [length] bytes from the quilt starting at the given [sliver] index.
  ///
  /// Attempts to read via secondary slivers first (efficient random access),
  /// falls back to reading the full blob if slivers fail.
  Future<Uint8List> _readBytes(
    int sliver,
    int length, [
    int offset = 0,
    int? columnSize,
  ]) async {
    if (_blob.hasStartedLoadingFullBlob) {
      return _readBytesFromBlob(sliver, length, offset);
    }

    try {
      return await _readBytesFromSlivers(sliver, length, offset, columnSize);
    } catch (_) {
      // Fallback to reading the full blob.
      return _readBytesFromBlob(sliver, length, offset);
    }
  }

  /// Read bytes from secondary slivers (efficient for random access).
  ///
  /// Each secondary sliver corresponds to a column in the quilt matrix.
  /// We request only the slivers we need and extract the relevant bytes.
  Future<Uint8List> _readBytesFromSlivers(
    int sliver,
    int length, [
    int offset = 0,
    int? columnSize,
  ]) async {
    if (length == 0) return Uint8List(0);

    // Start loading the first sliver eagerly.
    _blob.getSecondarySliver(sliverIndex: sliver).ignore();

    columnSize ??= await _blob.getColumnSize();
    if (columnSize <= 0) throw StateError('Invalid column size: $columnSize');

    final columnOffset = offset ~/ columnSize;
    var remainingOffset = offset % columnSize;
    final bytes = Uint8List(length);

    var bytesRead = 0;
    final nSlivers = (length + columnSize - 1) ~/ columnSize;

    // Request all needed slivers in parallel.
    final sliverFutures = List.generate(
      nSlivers,
      (i) => _blob.getSecondarySliver(sliverIndex: sliver + columnOffset + i),
    );

    for (final sliverFuture in sliverFutures) {
      final sliverData = await sliverFuture;
      var chunk = remainingOffset > 0
          ? sliverData.sublist(remainingOffset)
          : sliverData;
      remainingOffset = 0;

      if (chunk.length > length - bytesRead) {
        chunk = chunk.sublist(0, length - bytesRead);
      }

      bytes.setAll(bytesRead, chunk);
      bytesRead += chunk.length;

      if (bytesRead >= length) break;
    }

    return bytes;
  }

  /// Read bytes from the full blob (fallback when secondary slivers fail).
  ///
  /// Reads the blob contents and extracts bytes from the quilt matrix
  /// by navigating the column-major layout.
  Future<Uint8List> _readBytesFromBlob(
    int startColumn,
    int length, [
    int offset = 0,
  ]) async {
    final result = Uint8List(length);
    if (length == 0) return result;

    final blob = await _blob.getBytes();
    final rowSize = await _blob.getRowSize();
    final symbolSize = await _blob.getSymbolSize();

    final nRows = blob.length ~/ rowSize;
    final symbolsToSkip = offset ~/ symbolSize;
    var remainingOffset = offset % symbolSize;
    var currentCol = startColumn + symbolsToSkip ~/ nRows;
    var currentRow = symbolsToSkip % nRows;

    var bytesRead = 0;

    while (bytesRead < length) {
      final baseIndex = currentRow * rowSize + currentCol * symbolSize;
      final startIndex = baseIndex + remainingOffset;
      final endIndex = [
        baseIndex + symbolSize,
        startIndex + length - bytesRead,
        blob.length,
      ].reduce((a, b) => a < b ? a : b);

      if (startIndex >= blob.length) {
        throw StateError('Index out of bounds');
      }

      final size = endIndex - startIndex;
      for (var i = 0; i < size; i++) {
        result[bytesRead + i] = blob[startIndex + i];
      }
      bytesRead += size;

      remainingOffset = 0;
      currentRow = (currentRow + 1) % nRows;
      if (currentRow == 0) {
        currentCol++;
      }
    }

    return result;
  }

  // -------------------------------------------------------------------------
  // Blob Header Parsing
  // -------------------------------------------------------------------------

  /// Read the blob header for a patch at the given sliver index.
  ///
  /// The header contains the identifier, tags, blob size, and content offset.
  /// Results are cached by sliver index.
  ///
  /// Mirrors the TS SDK's `QuiltReader.getBlobHeader(sliverIndex)`.
  Future<QuiltBlobHeader> getBlobHeader(int sliverIndex) async {
    if (_headerCache.containsKey(sliverIndex)) {
      return _headerCache[sliverIndex]!;
    }

    // Read QuiltPatchBlobHeader: version(1) + length(4) + mask(1) = 6 bytes.
    final headerBytes = await _readBytes(
      sliverIndex,
      kQuiltPatchBlobHeaderSize,
    );
    final headerView = ByteData.view(
      headerBytes.buffer,
      headerBytes.offsetInBytes,
    );

    // Parse header fields.
    // final version = headerBytes[0]; // version (unused currently)
    final blobLength = headerView.getUint32(1, Endian.little);
    final mask = headerBytes[5];

    var offset = kQuiltPatchBlobHeaderSize;
    var blobSize = blobLength;

    // Read identifier length (u16 LE).
    final identifierLenBytes = await _readBytes(sliverIndex, 2, offset);
    final identifierLength = ByteData.view(
      identifierLenBytes.buffer,
      identifierLenBytes.offsetInBytes,
    ).getUint16(0, Endian.little);
    blobSize -= 2 + identifierLength;
    offset += 2;

    // Read identifier bytes.
    final identifierBytes = await _readBytes(
      sliverIndex,
      identifierLength,
      offset,
    );
    final identifier = utf8.decode(identifierBytes);
    offset += identifierLength;

    // Read tags if present.
    Map<String, String>? tags;
    if (mask & kHasTagsFlag != 0) {
      final tagsSizeBytes = await _readBytes(sliverIndex, 2, offset);
      final tagsSize = ByteData.view(
        tagsSizeBytes.buffer,
        tagsSizeBytes.offsetInBytes,
      ).getUint16(0, Endian.little);
      offset += 2;

      final tagsBytes = await _readBytes(sliverIndex, tagsSize, offset);
      tags = _deserializeQuiltPatchTags(tagsBytes);
      blobSize -= tagsSize + 2;
      offset += tagsSize;
    }

    final header = QuiltBlobHeader(
      identifier: identifier,
      tags: tags,
      blobSize: blobSize,
      contentOffset: offset,
    );

    _headerCache[sliverIndex] = header;
    return header;
  }

  // -------------------------------------------------------------------------
  // Blob Reading
  // -------------------------------------------------------------------------

  /// Read a blob (patch) from the quilt at the given sliver index.
  ///
  /// Returns the identifier, tags, and raw content bytes.
  ///
  /// Mirrors the TS SDK's `QuiltReader.readBlob(sliverIndex)`.
  Future<QuiltBlobReadResult> readBlob(int sliverIndex) async {
    final header = await getBlobHeader(sliverIndex);
    final blobContents = await _readBytes(
      sliverIndex,
      header.blobSize,
      header.contentOffset,
    );

    return QuiltBlobReadResult(
      identifier: header.identifier,
      tags: header.tags,
      blobContents: blobContents,
    );
  }

  /// Get a reader for a specific patch ID.
  ///
  /// Mirrors the TS SDK's `QuiltReader.readerForPatchId(id)`.
  QuiltFileReader readerForPatchId(String id) {
    final parsed = parseQuiltPatchId(id);

    if (parsed.quiltId != _blob.blobId) {
      throw ArgumentError(
        'The requested patch is not part of quilt ${_blob.blobId}',
      );
    }

    return QuiltFileReader(quilt: this, sliverIndex: parsed.startIndex);
  }

  // -------------------------------------------------------------------------
  // Index Reading
  // -------------------------------------------------------------------------

  /// Read the quilt index and return entries for each patch.
  ///
  /// The index is stored in the first N columns of the quilt, starting at
  /// column 0. Each entry contains the identifier, patch ID, tags, and
  /// a reader for that file.
  ///
  /// Mirrors the TS SDK's `QuiltReader.readIndex()`.
  Future<List<QuiltIndexEntry>> readIndex() async {
    // Read the 5-byte prefix: version(1) + indexSize(4).
    final headerBytes = await _readBytes(0, kQuiltIndexPrefixSize);
    final headerView = ByteData.view(
      headerBytes.buffer,
      headerBytes.offsetInBytes,
    );
    final version = headerView.getUint8(0);

    if (version != 1) {
      throw StateError('Unsupported quilt version $version');
    }

    final indexSize = headerView.getUint32(1, Endian.little);
    final indexBytes = await _readBytes(0, indexSize, kQuiltIndexPrefixSize);

    final columnSize = await _blob.getColumnSize();
    final indexSlivers = (indexSize + columnSize - 1) ~/ columnSize;

    // Parse the BCS-encoded index.
    final patches = _deserializeQuiltIndex(indexBytes);

    final entries = <QuiltIndexEntry>[];
    for (var i = 0; i < patches.length; i++) {
      final patch = patches[i];
      final startIndex = i == 0 ? indexSlivers : patches[i - 1].endIndex;

      final reader = QuiltFileReader(
        quilt: this,
        sliverIndex: startIndex,
        identifier: patch.identifier,
        tags: patch.tags,
      );

      entries.add(
        QuiltIndexEntry(
          identifier: patch.identifier,
          patchId: encodeQuiltPatchId(
            quiltBlobId: _blob.blobId,
            version: 1,
            startIndex: startIndex,
            endIndex: patch.endIndex,
          ),
          tags: patch.tags,
          reader: reader,
        ),
      );
    }

    return entries;
  }
}

// ---------------------------------------------------------------------------
// Internal: Tag Deserialization
// ---------------------------------------------------------------------------

/// Deserialize quilt patch tags from BCS format.
///
/// BCS format: ULEB128 count, then for each entry:
///   ULEB128 key_len, key bytes, ULEB128 value_len, value bytes
Map<String, String> _deserializeQuiltPatchTags(Uint8List data) {
  final result = <String, String>{};
  var offset = 0;

  final (count, countBytes) = _readUleb128(data, offset);
  offset += countBytes;

  for (var i = 0; i < count; i++) {
    final (keyLen, keyLenBytes) = _readUleb128(data, offset);
    offset += keyLenBytes;
    final key = utf8.decode(data.sublist(offset, offset + keyLen));
    offset += keyLen;

    final (valueLen, valueLenBytes) = _readUleb128(data, offset);
    offset += valueLenBytes;
    final value = utf8.decode(data.sublist(offset, offset + valueLen));
    offset += valueLen;

    result[key] = value;
  }

  return result;
}

/// Deserialize the quilt index from BCS format.
///
/// BCS format: ULEB128 vector length, then for each patch:
///   endIndex(u16 LE), identifier(BCS string), tags(BCS map)
List<QuiltPatch> _deserializeQuiltIndex(Uint8List data) {
  final patches = <QuiltPatch>[];
  var offset = 0;

  final (count, countBytes) = _readUleb128(data, offset);
  offset += countBytes;

  for (var i = 0; i < count; i++) {
    // endIndex as u16 LE.
    final endIndex = ByteData.view(
      data.buffer,
      data.offsetInBytes + offset,
    ).getUint16(0, Endian.little);
    offset += 2;

    // identifier as BCS string (ULEB128 length + bytes).
    final (idLen, idLenBytes) = _readUleb128(data, offset);
    offset += idLenBytes;
    final identifier = utf8.decode(data.sublist(offset, offset + idLen));
    offset += idLen;

    // tags as BCS map.
    final (tagCount, tagCountBytes) = _readUleb128(data, offset);
    offset += tagCountBytes;

    final tags = <String, String>{};
    for (var j = 0; j < tagCount; j++) {
      final (kLen, kLenBytes) = _readUleb128(data, offset);
      offset += kLenBytes;
      final key = utf8.decode(data.sublist(offset, offset + kLen));
      offset += kLen;

      final (vLen, vLenBytes) = _readUleb128(data, offset);
      offset += vLenBytes;
      final value = utf8.decode(data.sublist(offset, offset + vLen));
      offset += vLen;

      tags[key] = value;
    }

    patches.add(
      QuiltPatch(
        startIndex:
            0, // startIndex is computed from the previous patch's endIndex
        endIndex: endIndex,
        identifier: identifier,
        tags: tags,
      ),
    );
  }

  return patches;
}

/// Read a ULEB128-encoded unsigned integer from [data] at [offset].
///
/// Returns (value, bytesConsumed).
(int, int) _readUleb128(Uint8List data, int offset) {
  var value = 0;
  var shift = 0;
  var bytesRead = 0;

  while (true) {
    if (offset + bytesRead >= data.length) {
      throw StateError('Unexpected end of ULEB128 data');
    }
    final byte = data[offset + bytesRead];
    value |= (byte & 0x7F) << shift;
    bytesRead++;

    if ((byte & 0x80) == 0) break;
    shift += 7;
  }

  return (value, bytesRead);
}
