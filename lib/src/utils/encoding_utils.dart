/// Encoding and shard math utilities for direct-mode Walrus operations.
///
/// Port of the TypeScript SDK's `utils/index.ts` — shard/sliver mapping,
/// symbol count calculations, quorum checks, and blob-ID encoding.
///
/// These are pure functions with no I/O; they translate between shard
/// indices, sliver pair indices, and node assignments using the same
/// deterministic rotation the Walrus protocol defines.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sui/utils/sha.dart' as sui_hash;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Length of a SHA-256 digest in bytes.
const int kDigestLen = 32;

/// Length of a Walrus Blob ID in bytes.
const int kBlobIdLen = 32;

/// RS2 encoding type identifier used in on-chain registration.
const int kEncodingTypeRS2 = 1;

/// RedStuff encoding type identifier.
const int kEncodingTypeRedStuff = 0;

/// Required symbol alignment by encoding type.
const Map<int, int> kRequiredAlignment = {
  kEncodingTypeRS2: 2,
  kEncodingTypeRedStuff: 2,
};

/// Maximum symbol size by encoding type.
const Map<int, int> kMaxSymbolSize = {
  kEncodingTypeRS2: (1 << 16) - 1, // 65535
  kEncodingTypeRedStuff: (1 << 16) - 1,
};

/// Bytes per storage unit for on-chain pricing.
const int kBytesPerStorageUnit = 1024 * 1024; // 1 MiB

// ---------------------------------------------------------------------------
// Source Symbol Calculations
// ---------------------------------------------------------------------------

/// Number of primary and secondary source symbols for a given shard count.
///
/// Mirrors TS SDK `getSourceSymbols(nShards, encodingType)`.
({int primary, int secondary}) getSourceSymbols(
  int nShards, {
  int encodingType = kEncodingTypeRS2,
}) {
  final safetyLimit = _decodingSafetyLimit(nShards, encodingType);
  final maxFaulty = getMaxFaultyNodes(nShards);
  final minCorrect = nShards - maxFaulty;

  return (
    primary: minCorrect - maxFaulty - safetyLimit,
    secondary: minCorrect - safetyLimit,
  );
}

/// Maximum number of faulty nodes the protocol tolerates.
///
/// `f = floor((n - 1) / 3)` — standard BFT threshold.
int getMaxFaultyNodes(int nShards) => (nShards - 1) ~/ 3;

/// Internal safety limit for decoding.
int _decodingSafetyLimit(int nShards, int encodingType) {
  switch (encodingType) {
    case kEncodingTypeRedStuff:
      final f = getMaxFaultyNodes(nShards);
      final fDiv5 = f ~/ 5;
      return fDiv5 < 5 ? fDiv5 : 5; // min(5, floor(f/5))
    case kEncodingTypeRS2:
      return 0;
    default:
      throw ArgumentError('Unknown encoding type: $encodingType');
  }
}

// ---------------------------------------------------------------------------
// Size Calculations
// ---------------------------------------------------------------------------

/// Compute the symbol size, row size, and column size for a blob.
///
/// Mirrors TS SDK `getSizes(blobSize, numShards)`.
({int symbolSize, int rowSize, int columnSize}) getSizes(
  int blobSize,
  int numShards, {
  int encodingType = kEncodingTypeRS2,
}) {
  final src = getSourceSymbols(numShards, encodingType: encodingType);
  final totalSymbols = (src.primary + src.secondary) * numShards;

  var symbolSize =
      ((blobSize < 1 ? 1 : blobSize) - 1) ~/ (src.primary * src.secondary) + 1;

  // RS2 requires even symbol size.
  if (encodingType == kEncodingTypeRS2 && symbolSize % 2 == 1) {
    symbolSize += 1;
  }

  final encodedSize = totalSymbols * symbolSize;
  if (encodedSize % totalSymbols != 0) {
    throw StateError('Encoded blob size must be divisible by total symbols');
  }

  return (
    symbolSize: symbolSize,
    rowSize: symbolSize * src.secondary,
    columnSize: symbolSize * src.primary,
  );
}

/// Total encoded sliver size across all shards.
///
/// Mirrors TS SDK `encodedSliverSize(unencodedLength, nShards, encodingType)`.
int encodedSliverSize(
  int unencodedLength,
  int nShards, {
  int encodingType = kEncodingTypeRS2,
}) {
  final src = getSourceSymbols(nShards, encodingType: encodingType);

  var symbolSize =
      (((unencodedLength < 1 ? 1 : unencodedLength) - 1) ~/
          (src.primary * src.secondary)) +
      1;

  if (encodingType == kEncodingTypeRS2 && symbolSize % 2 == 1) {
    symbolSize += 1;
  }

  final singleShardSize = (src.primary + src.secondary) * symbolSize;
  return singleShardSize * nShards;
}

/// Total encoded blob length including metadata overhead.
///
/// Mirrors TS SDK `encodedBlobLength(unencodedLength, nShards, encodingType)`.
int encodedBlobLength(
  int unencodedLength,
  int nShards, {
  int encodingType = kEncodingTypeRS2,
}) {
  final sliverSize = encodedSliverSize(
    unencodedLength,
    nShards,
    encodingType: encodingType,
  );
  final metadata = nShards * kDigestLen * 2 + kBlobIdLen;
  return nShards * metadata + sliverSize;
}

/// Convert encoded blob size to on-chain storage units (1 MiB each).
///
/// Mirrors TS SDK `storageUnitsFromSize(size)`.
int storageUnitsFromSize(int size) =>
    (size + kBytesPerStorageUnit - 1) ~/ kBytesPerStorageUnit;

// ---------------------------------------------------------------------------
// Quorum / Validity
// ---------------------------------------------------------------------------

/// Whether [size] nodes form a quorum (> 2f).
///
/// Mirrors TS SDK `isQuorum(size, nShards)`.
bool isQuorum(int size, int nShards) {
  return size > 2 * getMaxFaultyNodes(nShards);
}

/// Whether [size] failures exceed the validity threshold (> f).
///
/// When true the operation should be aborted because too many nodes
/// have failed.
///
/// Mirrors TS SDK `isAboveValidity(size, nShards)`.
bool isAboveValidity(int size, int nShards) {
  return size > getMaxFaultyNodes(nShards);
}

// ---------------------------------------------------------------------------
// Shard ↔ Sliver-Pair Index Mapping
// ---------------------------------------------------------------------------

/// Deterministic rotation offset derived from the blob ID.
///
/// The Walrus protocol rotates shard assignments by a blob-specific
/// offset so that different blobs map to different nodes.
int _rotationOffset(Uint8List blobIdBytes, int modulus) {
  var offset = 0;
  for (final byte in blobIdBytes) {
    offset = (offset * 256 + byte) % modulus;
  }
  return offset;
}

/// Map a sliver pair index to the shard index responsible for it.
///
/// `shardIndex = (sliverPairIndex + offset) % numShards`
///
/// Mirrors TS SDK `toShardIndex(sliverPairIndex, blobId, numShards)`.
int toShardIndex(int sliverPairIndex, Uint8List blobIdBytes, int numShards) {
  final offset = _rotationOffset(blobIdBytes, numShards);
  return (sliverPairIndex + offset) % numShards;
}

/// Inverse of [toShardIndex]: map a shard index back to a sliver pair index.
///
/// `pairIndex = (numShards + shardIndex - offset) % numShards`
///
/// Mirrors TS SDK `toPairIndex(shardIndex, blobId, numShards)`.
int toPairIndex(int shardIndex, Uint8List blobIdBytes, int numShards) {
  final offset = _rotationOffset(blobIdBytes, numShards);
  return (numShards + shardIndex - offset) % numShards;
}

/// Convert a secondary sliver index to its sliver pair index.
///
/// Mirrors TS SDK `sliverPairIndexFromSecondarySliverIndex`.
int sliverPairIndexFromSecondarySliverIndex(int sliverIndex, int numShards) {
  return numShards - sliverIndex - 1;
}

/// Map a secondary sliver index to the shard responsible for it.
///
/// Mirrors TS SDK `shardIndexFromSecondarySliverIndex`.
int shardIndexFromSecondarySliverIndex(
  int sliverIndex,
  Uint8List blobIdBytes,
  int numShards,
) {
  final pairIndex = sliverPairIndexFromSecondarySliverIndex(
    sliverIndex,
    numShards,
  );
  return toShardIndex(pairIndex, blobIdBytes, numShards);
}

// ---------------------------------------------------------------------------
// Signers Bitmap
// ---------------------------------------------------------------------------

/// Convert a list of signer indices to a compact bitmap.
///
/// Used in `certifyBlobTransaction` to indicate which committee
/// members signed the storage confirmation.
///
/// Mirrors TS SDK `signersToBitmap(signers, committeeSize)`.
Uint8List signersToBitmap(List<int> signers, int committeeSize) {
  final bitmapSize = (committeeSize + 7) ~/ 8;
  final bitmap = Uint8List(bitmapSize);

  for (final signer in signers) {
    final byteIndex = signer ~/ 8;
    final bitIndex = signer % 8;
    bitmap[byteIndex] |= 1 << bitIndex;
  }

  return bitmap;
}

// ---------------------------------------------------------------------------
// Blob ID Encoding / Decoding
// ---------------------------------------------------------------------------

/// Encode a 32-byte blob ID as URL-safe base64 (no padding).
///
/// Mirrors TS SDK `urlSafeBase64(bytes)`.
String blobIdToUrlSafeBase64(Uint8List bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Decode a URL-safe base64 blob ID to 32 bytes.
///
/// Mirrors TS SDK `fromUrlSafeBase64(base64)`.
Uint8List blobIdFromUrlSafeBase64(String encoded) {
  // Restore padding.
  var padded = encoded.replaceAll('-', '+').replaceAll('_', '/');
  while (padded.length % 4 != 0) {
    padded += '=';
  }
  return base64Decode(padded);
}

/// Convert a 32-byte blob ID to a BigInt (u256) for on-chain representation.
Uint8List bigIntToBytes32(BigInt value) {
  final bytes = Uint8List(32);
  var v = value;
  for (var i = 31; i >= 0; i--) {
    bytes[i] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  return bytes;
}

/// Convert 32 bytes to BigInt (big-endian).
BigInt bytes32ToBigInt(Uint8List bytes) {
  if (bytes.length != 32) {
    throw ArgumentError('Expected 32 bytes, got ${bytes.length}');
  }
  var result = BigInt.zero;
  for (var i = 0; i < 32; i++) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Blob ID Computation
// ---------------------------------------------------------------------------

/// Compute the Walrus blob ID from encoding parameters.
///
/// The blob ID is the Blake2b-256 hash of the BCS-serialized
/// `BlobIdDerivation { encoding_type: u8, size: u64, root_hash: u256 }`.
///
/// This matches the on-chain Move contract:
/// ```move
/// let serialized = bcs::to_bytes(&blob_id_struct);
/// let encoded = hash::blake2b256(&serialized);
/// ```
Uint8List computeBlobId({
  required int encodingType,
  required int unencodedLength,
  required Uint8List rootHash,
}) {
  if (rootHash.length != 32) {
    throw ArgumentError('rootHash must be 32 bytes');
  }

  final buffer = BytesBuilder(copy: false);
  // Encoding type as single byte (BCS u8).
  buffer.addByte(encodingType);
  // Unencoded length as 8-byte little-endian (BCS u64).
  final lenBytes = Uint8List(8);
  var len = unencodedLength;
  for (var i = 0; i < 8; i++) {
    lenBytes[i] = len & 0xFF;
    len >>= 8;
  }
  buffer.add(lenBytes);
  // Root hash as 32-byte little-endian (BCS u256).
  buffer.add(rootHash);

  // Blake2b-256 — matches the Walrus Move contract's hash::blake2b256.
  return sui_hash.blake2b(buffer.toBytes());
}
