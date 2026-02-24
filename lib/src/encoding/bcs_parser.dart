/// BCS (Binary Canonical Serialization) parsing utilities for Walrus types.
///
/// Provides deserialization of BCS-encoded responses from Walrus storage
/// nodes, including sliver data and blob metadata.
///
/// BCS is the same serialization format used by the Sui blockchain and the
/// TS SDK's `@mysten/sui/bcs` package. These parsers are compatible with
/// the structures defined in the TS SDK's `utils/bcs.ts`.
library;

import 'dart:typed_data';

import '../models/storage_node_types.dart';

// ---------------------------------------------------------------------------
// Parsed Metadata
// ---------------------------------------------------------------------------

/// Parsed blob metadata from a `BlobMetadataWithId` BCS response.
///
/// Only the fields needed for blob reconstruction are extracted.
/// Mirrors the essential fields from the TS SDK's `BlobMetadataWithId`.
class ParsedBlobMetadata {
  /// The blob ID as raw 32 bytes (u256 LE).
  final Uint8List blobIdBytes;

  /// Encoding type (0 = RedStuff, 1 = RS2).
  final int encodingType;

  /// Original unencoded blob length in bytes.
  final int unencodedLength;

  const ParsedBlobMetadata({
    required this.blobIdBytes,
    required this.encodingType,
    required this.unencodedLength,
  });
}

// ---------------------------------------------------------------------------
// Sliver Response Parsing
// ---------------------------------------------------------------------------

/// Parse a BCS-encoded `Sliver` response from a storage node GET endpoint.
///
/// The BCS layout of `Sliver` is an enum:
/// ```
/// variant: u8 (0 = Primary, 1 = Secondary)
/// SliverData:
///   symbols:
///     data: ULEB128(length) || raw bytes
///     symbol_size: u16 LE
///   index: u16 LE
/// ```
///
/// Returns a [SliverData] with the parsed fields.
SliverData parseSliverResponse(Uint8List bcsBytes) {
  var offset = 0;

  // Variant byte (0 = Primary, 1 = Secondary) — skip.
  if (offset >= bcsBytes.length) {
    throw FormatException('Sliver BCS too short: missing variant byte');
  }
  offset += 1;

  // Symbols.data: byteVector = ULEB128(length) + raw bytes
  final (dataLength, uleb128Size) = _readUleb128(bcsBytes, offset);
  offset += uleb128Size;

  if (offset + dataLength > bcsBytes.length) {
    throw FormatException(
      'Sliver BCS too short: expected $dataLength data bytes at offset $offset, '
      'but only ${bcsBytes.length - offset} available',
    );
  }
  final data = Uint8List.sublistView(bcsBytes, offset, offset + dataLength);
  offset += dataLength;

  // Symbols.symbol_size: u16 LE
  if (offset + 2 > bcsBytes.length) {
    throw FormatException('Sliver BCS too short: missing symbol_size');
  }
  final symbolSize = bcsBytes[offset] | (bcsBytes[offset + 1] << 8);
  offset += 2;

  // index: u16 LE
  if (offset + 2 > bcsBytes.length) {
    throw FormatException('Sliver BCS too short: missing index');
  }
  final index = bcsBytes[offset] | (bcsBytes[offset + 1] << 8);
  // offset += 2; // end

  return SliverData(data: data, symbolSize: symbolSize, index: index);
}

/// Parse a BCS-encoded `BlobMetadataWithId` response.
///
/// BCS layout:
/// ```
/// blobId: 32 bytes (u256 LE)
/// metadata: enum { V1: BlobMetadataV1 }
///   variant: u8 (0 = V1)
///   BlobMetadataV1:
///     encoding_type: u8 (0 = RedStuff, 1 = RS2)
///     unencoded_length: u64 LE
///     hashes: vector<SliverPairMetadata> (not parsed here)
/// ```
///
/// Returns a [ParsedBlobMetadata] with the essential fields extracted.
ParsedBlobMetadata parseBlobMetadataResponse(Uint8List bcsBytes) {
  if (bcsBytes.length < 42) {
    throw FormatException(
      'BlobMetadataWithId BCS too short: expected at least 42 bytes, '
      'got ${bcsBytes.length}',
    );
  }

  // blobId: 32 bytes (u256 LE)
  final blobIdBytes = Uint8List.sublistView(bcsBytes, 0, 32);

  // metadata variant: 1 byte (0 = V1)
  final metadataVariant = bcsBytes[32];
  if (metadataVariant != 0) {
    throw FormatException(
      'Unsupported BlobMetadata variant: $metadataVariant (expected V1 = 0)',
    );
  }

  // encoding_type: 1 byte
  final encodingType = bcsBytes[33];

  // unencoded_length: u64 LE (8 bytes)
  var unencodedLength = 0;
  for (var i = 0; i < 8; i++) {
    unencodedLength |= bcsBytes[34 + i] << (i * 8);
  }

  return ParsedBlobMetadata(
    blobIdBytes: blobIdBytes,
    encodingType: encodingType,
    unencodedLength: unencodedLength,
  );
}

/// BCS-encode a [SliverData] as a `Sliver` enum for storage node PUT.
///
/// Wraps the sliver in the BCS `Sliver` enum with the specified variant.
/// This is different from `WalrusBlobEncoder.bcsSliverData()` which
/// encodes only the inner `SliverData` struct.
Uint8List encodeSliverForUpload(SliverData sliver, SliverType type) {
  final builder = BytesBuilder(copy: false);

  // Sliver enum variant
  builder.addByte(type == SliverType.primary ? 0 : 1);

  // Symbols.data: byteVector
  _writeUleb128(builder, sliver.data.length);
  builder.add(sliver.data);

  // Symbols.symbol_size: u16 LE
  builder.addByte(sliver.symbolSize & 0xFF);
  builder.addByte((sliver.symbolSize >> 8) & 0xFF);

  // index: u16 LE
  builder.addByte(sliver.index & 0xFF);
  builder.addByte((sliver.index >> 8) & 0xFF);

  return builder.toBytes();
}

// ---------------------------------------------------------------------------
// BCS Primitives
// ---------------------------------------------------------------------------

/// Read a ULEB128-encoded unsigned integer from [data] at [offset].
///
/// Returns a record of `(value, bytesConsumed)`.
(int, int) _readUleb128(Uint8List data, int offset) {
  var result = 0;
  var shift = 0;
  var bytesRead = 0;

  while (true) {
    if (offset + bytesRead >= data.length) {
      throw FormatException(
        'Unexpected end of ULEB128 at offset ${offset + bytesRead}',
      );
    }
    final byte = data[offset + bytesRead];
    result |= (byte & 0x7F) << shift;
    bytesRead++;
    if ((byte & 0x80) == 0) break;
    shift += 7;
  }

  return (result, bytesRead);
}

void _writeUleb128(BytesBuilder builder, int value) {
  var v = value;
  do {
    var byte = v & 0x7F;
    v >>= 7;
    if (v > 0) byte |= 0x80;
    builder.addByte(byte);
  } while (v > 0);
}
