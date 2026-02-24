/// Abstract interface for blob encoding (erasure coding).
///
/// The concrete implementation [WalrusBlobEncoder] uses Rust FFI
/// (`walrus_ffi`) for canonical RS2 encoding/decoding, producing
/// bit-identical output to the official walrus-core and TypeScript SDK.
library;

import 'dart:typed_data';

import '../models/protocol_types.dart';

/// Encodes raw blob data into Walrus slivers and computes metadata.
///
/// The Walrus protocol requires blobs to be erasure-coded before
/// registration on-chain. The encoding produces:
/// - A Merkle root hash over the encoded slivers
/// - A blob ID derived from the root hash, encoding type, and size
/// - Encoded slivers for distribution to storage nodes
///
/// ## Phase 2 usage
///
/// Since the concrete encoder is Phase 3, Phase 2 users have two options:
///
/// 1. **Upload Relay path**: Provide raw blob data to the relay, which
///    handles encoding server-side. Pre-computed metadata must still be
///    supplied for on-chain registration.
///
/// 2. **Custom encoder**: Implement this interface with your own encoding
///    logic and pass it to [WalrusDirectClient].
///
/// ## Current
///
/// [WalrusBlobEncoder] provides canonical RS2 encoding via Rust FFI,
/// enabling fully client-side encoding without the upload relay.
abstract class BlobEncoder {
  /// Compute metadata for the given blob data without full encoding.
  ///
  /// Returns [BlobMetadata] containing the blob ID, root hash, and
  /// other fields needed for on-chain registration.
  ///
  /// [data] is the raw unencoded blob content.
  /// [numShards] is the number of storage shards in the current committee.
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards);
}
