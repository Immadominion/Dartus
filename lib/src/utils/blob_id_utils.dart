/// Blob ID conversion utilities for Walrus.
///
/// Provides conversions between blob ID representations:
/// - URL-safe base64 strings (the canonical human-readable format)
/// - BigInt (u256, for on-chain representation in Move calls)
/// - Raw 32-byte Uint8List
///
/// Mirrors the TS SDK's `blobIdFromInt` / `blobIdToInt` from `utils/bcs.ts`.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Convert a BigInt (u256) blob ID to URL-safe base64 (no padding).
///
/// Mirrors TS SDK `blobIdFromInt(blobId)`.
///
/// The blob ID is stored as a u256 on-chain. This function converts it
/// to the standard URL-safe base64 representation used in HTTP APIs.
String blobIdFromInt(BigInt blobId) {
  final bytes = _bigIntToBytes32LE(blobId);
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Convert a URL-safe base64 blob ID to BigInt (u256).
///
/// Mirrors TS SDK `blobIdToInt(blobId)`.
///
/// Inverse of [blobIdFromInt].
BigInt blobIdToInt(String blobId) {
  final padded = _addBase64Padding(
    blobId.replaceAll('-', '+').replaceAll('_', '/'),
  );
  final bytes = base64Decode(padded);
  return _bytes32LEtoBigInt(bytes);
}

/// Convert raw 32-byte blob ID to URL-safe base64 (no padding).
///
/// Mirrors TS SDK `blobIdFromBytes(blobId)`.
String blobIdFromBytes(Uint8List blobId) {
  if (blobId.length != 32) {
    throw ArgumentError(
      'Blob ID must be exactly 32 bytes, got ${blobId.length}',
    );
  }
  return blobIdFromInt(_bytes32LEtoBigInt(blobId));
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Convert BigInt to 32-byte little-endian representation.
///
/// The TS SDK uses BCS u256 serialization, which is little-endian.
Uint8List _bigIntToBytes32LE(BigInt value) {
  final bytes = Uint8List(32);
  var v = value;
  for (var i = 0; i < 32; i++) {
    bytes[i] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  return bytes;
}

/// Convert 32 bytes (little-endian) to BigInt.
BigInt _bytes32LEtoBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

/// Restore base64 padding.
String _addBase64Padding(String s) {
  switch (s.length % 4) {
    case 2:
      return '$s==';
    case 3:
      return '$s=';
    default:
      return s;
  }
}
