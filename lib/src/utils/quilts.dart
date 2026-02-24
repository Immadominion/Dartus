/// Quilt encoding for multi-file Walrus blobs.
///
/// Quilts pack multiple files into a single Walrus blob with an index
/// that allows individual file retrieval. This mirrors the TS SDK's
/// `utils/quilts.ts` implementation.
///
/// A quilt consists of:
/// 1. An index region (first N columns) containing patch metadata
/// 2. Data regions (remaining columns) containing serialized file data
///
/// Each file becomes a "patch" within the quilt, identified by its
/// column range and an identifier string.
///
/// Example:
/// ```dart
/// final result = encodeQuilt(
///   blobs: [
///     QuiltBlob(contents: utf8.encode('Hello'), identifier: 'hello.txt'),
///     QuiltBlob(contents: utf8.encode('World'), identifier: 'world.txt'),
///   ],
///   numShards: 1000,
/// );
/// // result.quilt contains the raw quilt bytes
/// // result.index contains patch metadata for retrieval
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'encoding_utils.dart';

// ---------------------------------------------------------------------------
// Constants — verified matching TS SDK `utils/quilts.ts`
// ---------------------------------------------------------------------------

/// Size of the quilt index length field (4 bytes, little-endian u32).
const int kQuiltIndexSizeBytesLength = 4;

/// Size of the quilt version field (1 byte).
const int kQuiltVersionBytesLength = 1;

/// Total prefix size before the quilt index data.
const int kQuiltIndexPrefixSize =
    kQuiltVersionBytesLength + kQuiltIndexSizeBytesLength;

/// Size of a QuiltPatchBlobHeader in BCS: version(1) + length(4) + mask(1).
const int kQuiltPatchBlobHeaderSize = 1 + 4 + 1;

/// Size of the blob identifier length field (2 bytes, little-endian u16).
const int kBlobIdentifierSizeBytesLength = 2;

/// Size of the tags length field (2 bytes, little-endian u16).
const int kTagsSizeBytesLength = 2;

/// Maximum blob identifier length (2^16 - 1 = 65535 bytes).
const int kMaxBlobIdentifierBytesLength =
    (1 << (8 * kBlobIdentifierSizeBytesLength)) - 1;

/// Maximum number of slivers (columns) the quilt index can span.
const int kMaxNumSliversForQuiltIndex = 10;

/// Bitmask: tags present in the patch.
const int kHasTagsFlag = 1 << 0;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A blob to include in a quilt.
class QuiltBlob {
  final Uint8List contents;
  final String identifier;
  final Map<String, String>? tags;

  const QuiltBlob({
    required this.contents,
    required this.identifier,
    this.tags,
  });
}

/// A patch entry in the quilt index.
class QuiltPatch {
  final int startIndex;
  final int endIndex;
  final String identifier;
  final Map<String, String> tags;

  QuiltPatch({
    required this.startIndex,
    required this.endIndex,
    required this.identifier,
    required this.tags,
  });

  @override
  String toString() =>
      'QuiltPatch(identifier: $identifier, columns: $startIndex..$endIndex)';
}

/// Quilt index containing all patch entries.
class QuiltIndex {
  final List<QuiltPatch> patches;

  const QuiltIndex({required this.patches});
}

/// Result of quilt encoding.
class EncodeQuiltResult {
  /// The raw quilt bytes (to be uploaded as a single Walrus blob).
  final Uint8List quilt;

  /// The quilt index with patch metadata.
  final QuiltIndex index;

  const EncodeQuiltResult({required this.quilt, required this.index});
}

/// A parsed quilt patch ID.
class QuiltPatchId {
  final String quiltId;
  final int version;
  final int startIndex;
  final int endIndex;

  const QuiltPatchId({
    required this.quiltId,
    required this.version,
    required this.startIndex,
    required this.endIndex,
  });

  @override
  String toString() =>
      'QuiltPatchId($quiltId, v$version, $startIndex..$endIndex)';
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Encode multiple blobs into a single quilt.
///
/// Mirrors the TS SDK's `encodeQuilt()` from `utils/quilts.ts`.
///
/// Parameters:
/// - [blobs] — the files to pack into the quilt (must be non-empty)
/// - [numShards] — number of shards in the Walrus committee
/// - [encodingType] — encoding type (default: RS2)
///
/// Returns an [EncodeQuiltResult] with the raw quilt bytes and index.
EncodeQuiltResult encodeQuilt({
  required List<QuiltBlob> blobs,
  required int numShards,
  int encodingType = kEncodingTypeRS2,
}) {
  if (blobs.isEmpty) {
    throw ArgumentError('No blobs provided');
  }

  final src = getSourceSymbols(numShards, encodingType: encodingType);
  final nRows = src.primary;
  final nCols = src.secondary;

  // Sort blobs by identifier for deterministic ordering.
  final sortedBlobs = List<QuiltBlob>.from(blobs)
    ..sort((a, b) => a.identifier.compareTo(b.identifier));

  // Check for duplicate identifiers.
  final identifiers = <String>{};
  for (final blob in sortedBlobs) {
    if (!identifiers.add(blob.identifier)) {
      throw ArgumentError('Duplicate blob identifier: ${blob.identifier}');
    }
  }

  if (sortedBlobs.length > nCols) {
    throw ArgumentError(
      'Too many blobs (${sortedBlobs.length}), '
      'the number of blobs must be less than the number of columns ($nCols)',
    );
  }

  // Pre-serialize tags.
  final serializedTags = sortedBlobs.map((blob) {
    if (blob.tags != null && blob.tags!.isNotEmpty) {
      return _serializeQuiltPatchTags(blob.tags!);
    }
    return null;
  }).toList();

  // Build initial index (startIndex will be set later).
  final patches = <QuiltPatch>[];
  for (final blob in sortedBlobs) {
    patches.add(
      QuiltPatch(
        startIndex: 0,
        endIndex: 0,
        identifier: blob.identifier,
        tags: blob.tags ?? const {},
      ),
    );
  }

  // Calculate index size.
  final indexSize =
      kQuiltIndexPrefixSize + _serializeQuiltIndex(patches).length;

  // Build per-blob metadata headers.
  final blobMetadataList = <Uint8List>[];
  for (var i = 0; i < sortedBlobs.length; i++) {
    final blob = sortedBlobs[i];
    final identifierBytes = utf8.encode(blob.identifier);

    if (identifierBytes.length > kMaxBlobIdentifierBytesLength) {
      throw ArgumentError('Blob identifier too long: ${blob.identifier}');
    }

    var metadataSize =
        kQuiltPatchBlobHeaderSize +
        kBlobIdentifierSizeBytesLength +
        identifierBytes.length;

    var mask = 0;
    if (serializedTags[i] != null) {
      metadataSize += kTagsSizeBytesLength + serializedTags[i]!.length;
      mask |= kHasTagsFlag;
    }

    final metadata = Uint8List(metadataSize);
    final view = ByteData.view(metadata.buffer);
    var offset = 0;

    // QuiltPatchBlobHeader: version(1) + length(4) + mask(1)
    metadata[offset] = 1; // version
    offset += 1;
    view.setUint32(
      offset,
      metadataSize - kQuiltPatchBlobHeaderSize + blob.contents.length,
      Endian.little,
    );
    offset += 4;
    metadata[offset] = mask;
    offset += 1;

    // Identifier length (u16 LE) + identifier bytes.
    view.setUint16(offset, identifierBytes.length, Endian.little);
    offset += kBlobIdentifierSizeBytesLength;
    metadata.setAll(offset, identifierBytes);
    offset += identifierBytes.length;

    // Tags (if present).
    if (serializedTags[i] != null) {
      view.setUint16(offset, serializedTags[i]!.length, Endian.little);
      offset += kTagsSizeBytesLength;
      metadata.setAll(offset, serializedTags[i]!);
      offset += serializedTags[i]!.length;
    }

    blobMetadataList.add(metadata);
  }

  // Calculate blob sizes: [indexSize, ...blobSizes].
  final blobSizes = <int>[
    indexSize,
    ...sortedBlobs.asMap().entries.map((e) {
      return blobMetadataList[e.key].length + e.value.contents.length;
    }),
  ];

  // Compute symbol size.
  final symbolSize = computeSymbolSize(
    blobSizes: blobSizes,
    nColumns: nCols,
    nRows: nRows,
    maxNumColumnsForQuiltIndex: kMaxNumSliversForQuiltIndex,
    encodingType: encodingType,
  );

  final rowSize = symbolSize * nCols;
  final columnSize = symbolSize * nRows;
  final indexColumnsNeeded = (indexSize + columnSize - 1) ~/ columnSize;

  if (indexColumnsNeeded > kMaxNumSliversForQuiltIndex) {
    throw StateError('Index too large');
  }

  // Allocate the quilt matrix.
  final quilt = Uint8List(rowSize * nRows);
  var currentColumn = indexColumnsNeeded;

  // Write each blob into the quilt.
  for (var i = 0; i < sortedBlobs.length; i++) {
    patches[i] = QuiltPatch(
      startIndex: currentColumn,
      endIndex: 0,
      identifier: patches[i].identifier,
      tags: patches[i].tags,
    );

    currentColumn += _writeBlobToQuilt(
      quilt: quilt,
      blob: sortedBlobs[i].contents,
      rowSize: rowSize,
      columnSize: columnSize,
      symbolSize: symbolSize,
      startColumn: currentColumn,
      prefix: blobMetadataList[i],
    );

    patches[i] = QuiltPatch(
      startIndex: patches[i].startIndex,
      endIndex: currentColumn,
      identifier: patches[i].identifier,
      tags: patches[i].tags,
    );
  }

  // Serialize the final index (with correct startIndex/endIndex).
  final indexBytes = _serializeQuiltIndex(patches);
  final quiltIndex = Uint8List(kQuiltIndexPrefixSize + indexBytes.length);
  final indexView = ByteData.view(quiltIndex.buffer);
  quiltIndex[0] = 1; // version
  indexView.setUint32(1, indexBytes.length, Endian.little);
  quiltIndex.setAll(kQuiltIndexPrefixSize, indexBytes);

  // Write the index into the quilt.
  _writeBlobToQuilt(
    quilt: quilt,
    blob: quiltIndex,
    rowSize: rowSize,
    columnSize: columnSize,
    symbolSize: symbolSize,
    startColumn: 0,
  );

  return EncodeQuiltResult(
    quilt: quilt,
    index: QuiltIndex(patches: patches),
  );
}

// ---------------------------------------------------------------------------
// Quilt Patch ID Encoding
// ---------------------------------------------------------------------------

/// Encode a quilt patch ID to URL-safe base64.
///
/// The patch ID encodes the quilt blob ID and the column range.
/// Format: quiltId(32 bytes) + version(1) + startIndex(2 LE) + endIndex(2 LE)
String encodeQuiltPatchId({
  required String quiltBlobId,
  required int version,
  required int startIndex,
  required int endIndex,
}) {
  final quiltIdBytes = blobIdFromUrlSafeBase64(quiltBlobId);
  final bytes = Uint8List(32 + 1 + 2 + 2);
  bytes.setAll(0, quiltIdBytes);
  bytes[32] = version;
  final view = ByteData.view(bytes.buffer);
  view.setUint16(33, startIndex, Endian.little);
  view.setUint16(35, endIndex, Endian.little);
  return blobIdToUrlSafeBase64(bytes);
}

/// Parse a quilt patch ID from URL-safe base64.
///
/// Inverse of [encodeQuiltPatchId]. Returns a [QuiltPatchId] with the
/// quilt blob ID, version, and column range.
///
/// Mirrors the TS SDK's `parseQuiltPatchId(id)` from `utils/quilts.ts`.
QuiltPatchId parseQuiltPatchId(String id) {
  final bytes = blobIdFromUrlSafeBase64(id);
  if (bytes.length < 37) {
    throw ArgumentError(
      'Invalid quilt patch ID: expected at least 37 bytes, got ${bytes.length}',
    );
  }
  final quiltIdBytes = bytes.sublist(0, 32);
  final quiltId = blobIdToUrlSafeBase64(quiltIdBytes);
  final version = bytes[32];
  final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
  final startIndex = view.getUint16(33, Endian.little);
  final endIndex = view.getUint16(35, Endian.little);
  return QuiltPatchId(
    quiltId: quiltId,
    version: version,
    startIndex: startIndex,
    endIndex: endIndex,
  );
}

/// Parsed Walrus ID — either a plain blob ID or a quilt patch ID.
///
/// Mirrors the TS SDK's `parseWalrusId(id)` from `utils/quilts.ts`.
class ParsedWalrusId {
  /// 'blob' for a plain blob, 'quiltPatch' for a quilt patch.
  final String kind;

  /// The plain blob ID (for kind == 'blob').
  final String? blobId;

  /// The parsed quilt patch ID (for kind == 'quiltPatch').
  final QuiltPatchId? patchId;

  const ParsedWalrusId._blob(this.blobId) : kind = 'blob', patchId = null;

  const ParsedWalrusId._quiltPatch(this.patchId)
    : kind = 'quiltPatch',
      blobId = null;

  @override
  String toString() => kind == 'blob'
      ? 'ParsedWalrusId(blob: $blobId)'
      : 'ParsedWalrusId(quiltPatch: $patchId)';
}

/// Parse a Walrus ID from URL-safe base64.
///
/// If the decoded bytes are exactly 32 bytes, it's a plain blob ID.
/// Otherwise, it's a quilt patch ID (37 bytes).
///
/// Mirrors the TS SDK's `parseWalrusId(id)` from `utils/quilts.ts`.
ParsedWalrusId parseWalrusId(String id) {
  final bytes = blobIdFromUrlSafeBase64(id);

  if (bytes.length == 32) {
    return ParsedWalrusId._blob(id);
  }

  return ParsedWalrusId._quiltPatch(parseQuiltPatchId(id));
}

// ---------------------------------------------------------------------------
// Symbol Size Computation
// ---------------------------------------------------------------------------

/// Find the minimum symbol size needed to store blobs in a fixed number
/// of columns. Each blob must be stored in consecutive columns exclusively.
///
/// Mirrors the TS SDK's `computeSymbolSize()` from `utils/quilts.ts`.
int computeSymbolSize({
  required List<int> blobSizes,
  required int nColumns,
  required int nRows,
  required int maxNumColumnsForQuiltIndex,
  int encodingType = kEncodingTypeRS2,
}) {
  if (blobSizes.length > nColumns) {
    throw ArgumentError(
      'Too many blobs, the number of blobs must be less than the number of columns',
    );
  }

  if (blobSizes.isEmpty) {
    throw ArgumentError('No blobs provided');
  }

  final totalSize = blobSizes.fold<int>(0, (a, b) => a + b);
  final maxSize = blobSizes.reduce((a, b) => a > b ? a : b);

  var minVal = [
    totalSize ~/ (nColumns * nRows),
    blobSizes[0] ~/ (nRows * maxNumColumnsForQuiltIndex),
    (kQuiltIndexPrefixSize + nRows - 1) ~/ nRows,
  ].reduce((a, b) => a > b ? a : b);

  var maxVal = ((maxSize / (nColumns / blobSizes.length)) * nRows).ceil();

  final alignment = kRequiredAlignment[encodingType] ?? 2;

  while (minVal < maxVal) {
    final mid = (minVal + maxVal) ~/ 2;
    if (_canBlobsFitIntoMatrix(blobSizes, nColumns, mid * nRows)) {
      maxVal = mid;
    } else {
      minVal = mid + 1;
    }
  }

  var symbolSize = ((minVal + alignment - 1) ~/ alignment) * alignment;

  if (!_canBlobsFitIntoMatrix(blobSizes, nColumns, symbolSize * nRows)) {
    throw StateError('Quilt oversize');
  }

  final maxSymbolSize = kMaxSymbolSize[encodingType] ?? 65535;
  if (symbolSize > maxSymbolSize) {
    throw StateError(
      'Quilt oversize: the resulting symbol size $symbolSize is larger '
      'than the maximum symbol size $maxSymbolSize; remove some blobs',
    );
  }

  return symbolSize;
}

bool _canBlobsFitIntoMatrix(List<int> blobSizes, int nColumns, int columnSize) {
  if (columnSize <= 0) return false;
  final columnsNeeded = blobSizes.fold<int>(
    0,
    (acc, size) => acc + ((size + columnSize - 1) ~/ columnSize),
  );
  return columnsNeeded <= nColumns;
}

// ---------------------------------------------------------------------------
// Internal: Write blob data into quilt matrix
// ---------------------------------------------------------------------------

/// Write blob data (with optional prefix) into the quilt matrix,
/// starting at the given column.
///
/// Returns the number of columns consumed.
///
/// Mirrors the TS SDK's `writeBlobToQuilt()` from `utils/quilts.ts`.
int _writeBlobToQuilt({
  required Uint8List quilt,
  required Uint8List blob,
  required int rowSize,
  required int columnSize,
  required int symbolSize,
  required int startColumn,
  Uint8List? prefix,
}) {
  final nRows = columnSize ~/ symbolSize;
  var bytesWritten = 0;

  if (rowSize % symbolSize != 0) {
    throw StateError('Row size must be divisible by symbol size');
  }

  if (columnSize % symbolSize != 0) {
    throw StateError('Column size must be divisible by symbol size');
  }

  void writeBytes(Uint8List bytes) {
    final offset = bytesWritten;
    final symbolsToSkip = offset ~/ symbolSize;
    var remainingOffset = offset % symbolSize;
    var currentCol = startColumn + symbolsToSkip ~/ nRows;
    var currentRow = symbolsToSkip % nRows;

    var index = 0;
    while (index < bytes.length) {
      final baseIndex = currentRow * rowSize + currentCol * symbolSize;
      final startIndex = baseIndex + remainingOffset;
      final len = [
        symbolSize - remainingOffset,
        bytes.length - index,
      ].reduce((a, b) => a < b ? a : b);

      for (var i = 0; i < len; i++) {
        quilt[startIndex + i] = bytes[index + i];
      }

      index += len;
      remainingOffset = 0;
      currentRow = (currentRow + 1) % nRows;
      if (currentRow == 0) {
        currentCol++;
      }
    }

    bytesWritten += bytes.length;
  }

  if (prefix != null) {
    writeBytes(prefix);
  }

  writeBytes(blob);

  return (bytesWritten + columnSize - 1) ~/ columnSize;
}

// ---------------------------------------------------------------------------
// Internal: Serialization helpers
// ---------------------------------------------------------------------------

/// Serialize quilt patch tags as a sorted BCS-style map.
///
/// Format: u32 count, then for each entry:
///   u32 key_len, key_bytes, u32 value_len, value_bytes
/// Sorted by key for deterministic serialization.
Uint8List _serializeQuiltPatchTags(Map<String, String> tags) {
  final sortedKeys = tags.keys.toList()..sort();
  final builder = BytesBuilder(copy: false);

  // BCS vector length (ULEB128-encoded, simplified for small counts).
  _writeUleb128(builder, sortedKeys.length);

  for (final key in sortedKeys) {
    final keyBytes = utf8.encode(key);
    final valueBytes = utf8.encode(tags[key]!);

    _writeUleb128(builder, keyBytes.length);
    builder.add(keyBytes);
    _writeUleb128(builder, valueBytes.length);
    builder.add(valueBytes);
  }

  return builder.toBytes();
}

/// Serialize the quilt index as BCS.
///
/// The index is a vector of patches, each containing:
///   endIndex(u16), identifier(string), tags(map)
Uint8List _serializeQuiltIndex(List<QuiltPatch> patches) {
  final builder = BytesBuilder(copy: false);

  // Vector length.
  _writeUleb128(builder, patches.length);

  for (final patch in patches) {
    // endIndex as u16 LE.
    final endBytes = Uint8List(2);
    ByteData.view(endBytes.buffer).setUint16(0, patch.endIndex, Endian.little);
    builder.add(endBytes);

    // identifier as BCS string (length-prefixed).
    final identifierBytes = utf8.encode(patch.identifier);
    _writeUleb128(builder, identifierBytes.length);
    builder.add(identifierBytes);

    // tags as BCS map.
    builder.add(_serializeQuiltPatchTags(patch.tags));
  }

  return builder.toBytes();
}

/// Write a ULEB128-encoded unsigned integer.
void _writeUleb128(BytesBuilder builder, int value) {
  var v = value;
  do {
    var byte = v & 0x7F;
    v >>= 7;
    if (v != 0) {
      byte |= 0x80;
    }
    builder.addByte(byte);
  } while (v != 0);
}
