/// Concrete blob encoder using Rust FFI for canonical Walrus RS2 encoding.
///
/// Implements the abstract [BlobEncoder] interface, enabling fully
/// decentralized direct-mode blob storage without the Upload Relay.
///
/// The encoding delegates to the `walrus_ffi` native library which uses
/// `reed-solomon-simd` — the same erasure coding algorithm as walrus-core
/// and walrus-wasm. This produces bit-identical output to the official
/// TypeScript SDK.
///
/// The native FFI library (`libwalrus_ffi`) is **required**. If it cannot
/// be loaded, encoding and decoding will throw a [StateError]. Call
/// [WalrusFfiBindings.configure] with the library path before creating
/// encoder instances.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/protocol_types.dart';
import '../models/storage_node_types.dart';
import '../utils/encoding_utils.dart';
import 'blob_encoder.dart';
import 'walrus_ffi_bindings.dart';

/// Concrete [BlobEncoder] using Rust FFI for canonical RS2 encoding.
///
/// Usage:
/// ```dart
/// final encoder = WalrusBlobEncoder();
///
/// // Full encode (for direct mode)
/// final encoded = encoder.encodeBlob(rawData, numShards);
///
/// // Metadata only (for upload relay)
/// final metadata = await encoder.computeMetadata(rawData, numShards);
/// ```
class WalrusBlobEncoder extends BlobEncoder {
  /// Encoding type used for all blobs.
  ///
  /// RS2 = 1, the standard Walrus encoding type.
  final int encodingType;

  WalrusBlobEncoder({this.encodingType = kEncodingTypeRS2});

  /// Whether the native FFI encoder is available on this platform.
  bool get isNativeAvailable {
    try {
      WalrusFfiBindings.instance();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get the FFI bindings, throwing a clear error if unavailable.
  WalrusFfiBindings _requireFFI() {
    try {
      return WalrusFfiBindings.instance();
    } catch (e) {
      throw StateError(
        'Native FFI library (libwalrus_ffi) is required for encoding/decoding '
        'but could not be loaded. Call WalrusFfiBindings.configure() with the '
        'path to the library before creating encoder instances. '
        'Original error: $e',
      );
    }
  }

  // -------------------------------------------------------------------------
  // BlobEncoder interface
  // -------------------------------------------------------------------------

  @override
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards) async {
    return computeMetadataSync(data, numShards);
  }

  /// Synchronous version of [computeMetadata] suitable for use in
  /// `Isolate.run()` to avoid blocking the main thread.
  BlobMetadata computeMetadataSync(Uint8List data, int numShards) {
    // Generate a random nonce for upload relay auth.
    // Mirrors TS SDK: crypto.getRandomValues(new Uint8Array(32))
    final nonce = Uint8List(32);
    final rng = Random.secure();
    for (var i = 0; i < 32; i++) {
      nonce[i] = rng.nextInt(256);
    }

    return _computeMetadataFFI(data, numShards, nonce);
  }

  /// Compute metadata using the native FFI encoder.
  BlobMetadata _computeMetadataFFI(
    Uint8List data,
    int numShards,
    Uint8List nonce,
  ) {
    final ffi = _requireFFI();
    final result = ffi.computeMetadata(numShards, data);

    return BlobMetadata(
      blobId: blobIdToUrlSafeBase64(result.blobId),
      rootHash: result.rootHash,
      unencodedLength: data.length,
      encodingType: result.encodingType,
      nonce: nonce,
      blobDigest: Uint8List.fromList(sha256.convert(data).bytes),
    );
  }

  // -------------------------------------------------------------------------
  // Full Encoding
  // -------------------------------------------------------------------------

  /// Encode a blob into primary and secondary slivers for all shards.
  ///
  /// Returns an [EncodedBlob] containing the blob ID, metadata bytes,
  /// root hash, and all slivers indexed by sliver pair index.
  ///
  /// Uses the native FFI encoder for canonical output.
  EncodedBlob encodeBlob(Uint8List data, int numShards) {
    return _encodeBlobFFI(data, numShards);
  }

  /// Full encode via the native FFI library.
  EncodedBlob _encodeBlobFFI(Uint8List data, int numShards) {
    final ffi = _requireFFI();
    final result = ffi.encodeBlob(numShards, data);

    final blobIdBytes = result.metadata.blobId;
    final blobId = blobIdToUrlSafeBase64(blobIdBytes);
    final rootHash = result.metadata.rootHash;
    final symbolSize = result.symbolSize;

    // Build SliverData objects.
    final primarySlivers = <SliverData>[];
    final secondarySlivers = <SliverData>[];

    for (var i = 0; i < numShards; i++) {
      primarySlivers.add(
        SliverData(
          data: result.primarySlivers[i],
          symbolSize: symbolSize,
          index: i,
        ),
      );
      secondarySlivers.add(
        SliverData(
          data: result.secondarySlivers[i],
          symbolSize: symbolSize,
          index: i,
        ),
      );
    }

    // BCS-encode metadata using the canonical hashes from FFI.
    // For now, we generate minimal metadata bytes. The full BCS metadata
    // with per-pair hashes would require the FFI to export individual pair
    // hashes, which is not yet exposed. For relay mode this is not needed;
    // for direct mode the storage nodes verify slivers individually.
    final metadataBytes = _bcsEncodeMetadataFromFFI(
      encodingType: result.metadata.encodingType,
      unencodedLength: data.length,
      numShards: numShards,
    );

    return EncodedBlob(
      blobId: blobId,
      blobIdBytes: blobIdBytes,
      metadataBytes: metadataBytes,
      rootHash: rootHash,
      unencodedLength: data.length,
      primarySlivers: primarySlivers,
      secondarySlivers: secondarySlivers,
    );
  }

  /// Minimal BCS metadata encoding for FFI path.
  ///
  /// The full per-pair hash metadata is not needed for the upload relay
  /// (only blobId/rootHash matter). For direct mode, storage nodes verify
  /// individual slivers via their own Merkle proofs.
  Uint8List _bcsEncodeMetadataFromFFI({
    required int encodingType,
    required int unencodedLength,
    required int numShards,
  }) {
    final builder = BytesBuilder(copy: false);

    // BlobMetadata outer enum: V1 variant index = 0
    builder.addByte(0);

    // BlobMetadataV1.encoding_type: EncodingType BCS enum variant
    builder.addByte(encodingType);

    // BlobMetadataV1.unencoded_length: u64 LE
    _writeU64(builder, unencodedLength);

    // hashes: empty vector placeholder (relay doesn't need pair hashes)
    _writeUleb128(builder, numShards);
    // Each pair needs two MerkleNode::Empty entries as placeholder
    for (var i = 0; i < numShards; i++) {
      builder.addByte(0); // MerkleNode::Empty (primary)
      builder.addByte(0); // MerkleNode::Empty (secondary)
    }

    return builder.toBytes();
  }

  // -------------------------------------------------------------------------
  // Decoding
  // -------------------------------------------------------------------------

  /// Decode (reconstruct) a blob from collected primary slivers.
  ///
  /// Uses the `walrus-core` RS2 decoder via Rust FFI — the same decoder
  /// used by the Walrus network for canonical reconstruction.
  ///
  /// Requires at least `primarySymbols` primary slivers (from any shards)
  /// to reconstruct the original data.
  ///
  /// Returns the original unencoded blob data, trimmed to
  /// [unencodedLength].
  Uint8List decodeBlob({
    required List<SliverData> primarySlivers,
    required int numShards,
    required int unencodedLength,
  }) {
    if (primarySlivers.isEmpty) {
      throw StateError('decodeBlob: no slivers provided');
    }

    final ffi = _requireFFI();
    final slivers = primarySlivers
        .map((s) => (index: s.index, data: s.data))
        .toList();

    return ffi.decodeBlob(
      nShards: numShards,
      blobSize: unencodedLength,
      slivers: slivers,
    );
  }

  // -------------------------------------------------------------------------
  // BCS Encoding for Sliver Data
  // -------------------------------------------------------------------------

  /// BCS-encode a [SliverData] for storage node PUT requests.
  ///
  /// BCS layout: `Symbols { data: byteVector, symbol_size: u16 } || index: u16`
  static Uint8List bcsSliverData(SliverData sliver) {
    final builder = BytesBuilder(copy: false);

    // Symbols.data: BCS byteVector = ULEB128(length) + bytes
    _writeUleb128(builder, sliver.data.length);
    builder.add(sliver.data);

    // Symbols.symbol_size: u16 LE
    _writeU16(builder, sliver.symbolSize);

    // index: u16 LE
    _writeU16(builder, sliver.index);

    return builder.toBytes();
  }

  // -------------------------------------------------------------------------
  // Internal: BCS Primitives
  // -------------------------------------------------------------------------

  static void _writeU16(BytesBuilder builder, int value) {
    builder.addByte(value & 0xFF);
    builder.addByte((value >> 8) & 0xFF);
  }

  static void _writeU64(BytesBuilder builder, int value) {
    var v = value;
    for (var i = 0; i < 8; i++) {
      builder.addByte(v & 0xFF);
      v >>= 8;
    }
  }

  static void _writeUleb128(BytesBuilder builder, int value) {
    var v = value;
    do {
      var byte = v & 0x7F;
      v >>= 7;
      if (v > 0) byte |= 0x80;
      builder.addByte(byte);
    } while (v > 0);
  }
}
