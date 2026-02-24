/// Protocol types for wallet-integrated Walrus operations (Phase 2+3).
///
/// These types mirror the TypeScript SDK's `types.ts` and `bcs.ts` structures
/// used in the upload relay, multi-step write blob flow, and direct storage
/// node interaction.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Protocol Message Certificate
// ---------------------------------------------------------------------------

/// A certificate proving a blob has been stored by a quorum of storage nodes.
///
/// Returned by the upload relay after a successful blob upload, or constructed
/// from individual node confirmations in direct mode.
///
/// Corresponds to the TS SDK's `ProtocolMessageCertificate` interface.
@immutable
class ProtocolMessageCertificate {
  /// Bitmap indices of the storage-node signers that contributed to this
  /// certificate.
  final List<int> signers;

  /// The BCS-serialized storage confirmation message that was signed.
  final Uint8List serializedMessage;

  /// The aggregated BLS signature over [serializedMessage].
  final Uint8List signature;

  const ProtocolMessageCertificate({
    required this.signers,
    required this.serializedMessage,
    required this.signature,
  });

  /// Construct from the JSON structure returned by the upload relay.
  ///
  /// The relay response shape:
  /// ```json
  /// {
  ///   "signers": [0, 1, 2, ...],
  ///   "serialized_message": [byte, byte, ...],
  ///   "signature": "<url-safe-base64>"
  /// }
  /// ```
  factory ProtocolMessageCertificate.fromJson(Map<String, dynamic> json) {
    return ProtocolMessageCertificate(
      signers: (json['signers'] as List).cast<int>(),
      serializedMessage: Uint8List.fromList(
        (json['serialized_message'] as List).cast<int>(),
      ),
      signature: _decodeSignature(json['signature']),
    );
  }

  Map<String, dynamic> toJson() => {
    'signers': signers,
    'serialized_message': serializedMessage.toList(),
    'signature': signature.toList(),
  };

  /// Decode from URL-safe base64 or raw byte list.
  static Uint8List _decodeSignature(dynamic value) {
    if (value is List) {
      return Uint8List.fromList(value.cast<int>());
    }
    if (value is String) {
      return _urlSafeBase64Decode(value);
    }
    throw ArgumentError('Unexpected signature format: ${value.runtimeType}');
  }

  static Uint8List _urlSafeBase64Decode(String input) {
    // Restore standard base64 padding and characters.
    var normalized = input.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    // Use dart:convert through Uint8List
    final bytes = <int>[];
    const base64Chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final buffer = <int>[];
    for (var i = 0; i < normalized.length; i++) {
      final char = normalized[i];
      if (char == '=') break;
      buffer.add(base64Chars.indexOf(char));
      if (buffer.length == 4) {
        bytes.add((buffer[0] << 2) | (buffer[1] >> 4));
        bytes.add(((buffer[1] & 0xF) << 4) | (buffer[2] >> 2));
        bytes.add(((buffer[2] & 0x3) << 6) | buffer[3]);
        buffer.clear();
      }
    }
    if (buffer.length >= 2) {
      bytes.add((buffer[0] << 2) | (buffer[1] >> 4));
    }
    if (buffer.length >= 3) {
      bytes.add(((buffer[1] & 0xF) << 4) | (buffer[2] >> 2));
    }
    return Uint8List.fromList(bytes);
  }

  @override
  String toString() =>
      'ProtocolMessageCertificate('
      'signers: ${signers.length} nodes, '
      'messageLen: ${serializedMessage.length}, '
      'signatureLen: ${signature.length})';
}

// ---------------------------------------------------------------------------
// Tip Strategy & Upload Relay Config
// ---------------------------------------------------------------------------

/// Strategy for calculating the tip to send to the upload relay operator.
///
/// Mirrors the TS SDK `TipStrategy` type:
/// - `const` → fixed tip amount in MIST
/// - `linear` → `base + perEncodedKib * encodedSizeKiB`
sealed class TipStrategy {
  const TipStrategy();

  /// Calculate the tip amount in MIST for the given blob size.
  BigInt calculateTip(int blobSizeBytes);

  factory TipStrategy.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('const')) {
      return ConstTipStrategy(amount: BigInt.from(json['const'] as num));
    }
    if (json.containsKey('linear')) {
      final linear = json['linear'] as Map<String, dynamic>;
      return LinearTipStrategy(
        base: BigInt.from(linear['base'] as num),
        perEncodedKib: BigInt.from(linear['encoded_size_mul_per_kib'] as num),
      );
    }
    throw ArgumentError('Unknown tip strategy: $json');
  }
}

/// Fixed-amount tip strategy. Every upload pays the same tip in MIST.
@immutable
class ConstTipStrategy extends TipStrategy {
  final BigInt amount;

  const ConstTipStrategy({required this.amount});

  @override
  BigInt calculateTip(int blobSizeBytes) => amount;

  @override
  String toString() => 'ConstTipStrategy(amount: $amount)';
}

/// Linear tip strategy: `base + perEncodedKib * ceil(blobSize / 1024)`.
@immutable
class LinearTipStrategy extends TipStrategy {
  final BigInt base;
  final BigInt perEncodedKib;

  const LinearTipStrategy({required this.base, required this.perEncodedKib});

  @override
  BigInt calculateTip(int blobSizeBytes) {
    final kib = BigInt.from((blobSizeBytes + 1023) ~/ 1024);
    return base + perEncodedKib * kib;
  }

  @override
  String toString() =>
      'LinearTipStrategy(base: $base, perEncodedKib: $perEncodedKib)';
}

/// Configuration for tipping the upload relay operator.
///
/// Retrieved from the relay's `/v1/tip-config` endpoint.
///
/// Corresponds to the TS SDK's `UploadRelayTipConfig`.
@immutable
class UploadRelayTipConfig {
  /// Sui address of the relay operator to receive the tip.
  final String address;

  /// Tip calculation strategy.
  final TipStrategy kind;

  /// Optional maximum tip amount in MIST.
  final BigInt? max;

  const UploadRelayTipConfig({
    required this.address,
    required this.kind,
    this.max,
  });

  /// Parse from the relay `/v1/tip-config` response.
  ///
  /// Response format:
  /// ```json
  /// { "send_tip": { "address": "0x...", "kind": { "const": 105 } } }
  /// ```
  /// or `"no_tip"` → returns `null`.
  static UploadRelayTipConfig? fromRelayResponse(dynamic json) {
    if (json == 'no_tip') return null;
    if (json is Map<String, dynamic> && json.containsKey('send_tip')) {
      final sendTip = json['send_tip'] as Map<String, dynamic>;
      return UploadRelayTipConfig(
        address: sendTip['address'] as String,
        kind: TipStrategy.fromJson(sendTip['kind'] as Map<String, dynamic>),
        max: sendTip.containsKey('max')
            ? BigInt.from(sendTip['max'] as num)
            : null,
      );
    }
    throw ArgumentError('Unknown tip config format: $json');
  }

  /// Calculate the effective tip, capped at [max] if set.
  BigInt calculateTip(int blobSizeBytes) {
    final tip = kind.calculateTip(blobSizeBytes);
    if (max != null && tip > max!) return max!;
    return tip;
  }

  @override
  String toString() =>
      'UploadRelayTipConfig('
      'address: $address, kind: $kind, max: $max)';
}

// ---------------------------------------------------------------------------
// Blob Metadata (returned by the encode step)
// ---------------------------------------------------------------------------

/// Metadata computed from encoding a blob, needed for on-chain registration.
///
/// Computed automatically by [WalrusBlobEncoder] using Rust FFI
/// (`walrus_ffi`) for canonical RS2 encoding.
@immutable
class BlobMetadata {
  /// The Walrus blob ID (derived from rootHash + encodingType + size).
  final String blobId;

  /// Merkle root hash of the encoded slivers.
  final Uint8List rootHash;

  /// Original unencoded blob size in bytes.
  final int unencodedLength;

  /// Walrus encoding type identifier (1 = RS2).
  final int encodingType;

  /// Random 32-byte nonce used for upload relay tip authentication.
  final Uint8List nonce;

  /// SHA-256 digest of the raw blob data.
  final Uint8List blobDigest;

  const BlobMetadata({
    required this.blobId,
    required this.rootHash,
    required this.unencodedLength,
    required this.encodingType,
    required this.nonce,
    required this.blobDigest,
  });

  @override
  String toString() =>
      'BlobMetadata('
      'blobId: $blobId, '
      'unencodedLength: $unencodedLength, '
      'encodingType: $encodingType)';
}

// ---------------------------------------------------------------------------
// Upload Relay Configuration
// ---------------------------------------------------------------------------

/// Configuration for the upload relay client.
///
/// Corresponds to the TS SDK's `UploadRelayConfig` in `WalrusClientConfig`.
@immutable
class UploadRelayConfig {
  /// Base URL of the upload relay (e.g. `https://upload-relay.testnet.walrus.space`).
  final String host;

  /// Whether to send a tip to the relay operator.
  /// If non-null, the tip config overrides auto-fetched config.
  final UploadRelayTipConfig? sendTip;

  /// Maximum tip amount in MIST (convenience shorthand).
  final BigInt? maxTip;

  /// Request timeout for relay operations.
  final Duration timeout;

  const UploadRelayConfig({
    required this.host,
    this.sendTip,
    this.maxTip,
    this.timeout = const Duration(seconds: 120),
  });

  @override
  String toString() => 'UploadRelayConfig(host: $host)';
}

// ---------------------------------------------------------------------------
// Write Blob Result
// ---------------------------------------------------------------------------

/// Result of a complete write blob operation.
@immutable
class WriteBlobResult {
  /// The Walrus blob ID.
  final String blobId;

  /// The Sui object ID of the on-chain Blob object.
  final String blobObjectId;

  /// The transaction digest of the certify transaction.
  final String certifyDigest;

  const WriteBlobResult({
    required this.blobId,
    required this.blobObjectId,
    required this.certifyDigest,
  });

  @override
  String toString() =>
      'WriteBlobResult('
      'blobId: $blobId, blobObjectId: $blobObjectId)';
}

// ---------------------------------------------------------------------------
// Register Blob Options
// ---------------------------------------------------------------------------

/// Options for registering a blob on-chain.
///
/// Corresponds to the TS SDK's `RegisterBlobOptions`.
@immutable
class RegisterBlobOptions {
  /// Unencoded blob size in bytes.
  final int size;

  /// Number of storage epochs.
  final int epochs;

  /// The Walrus blob ID (URL-safe base64 string, as produced by the encoder).
  final String blobId;

  /// Merkle root hash of encoded slivers.
  final Uint8List rootHash;

  /// Whether the blob can be deleted.
  final bool deletable;

  /// Sui address to transfer the blob object to.
  final String? owner;

  const RegisterBlobOptions({
    required this.size,
    required this.epochs,
    required this.blobId,
    required this.rootHash,
    required this.deletable,
    this.owner,
  });
}

// ---------------------------------------------------------------------------
// Certify Blob Options
// ---------------------------------------------------------------------------

/// Options for certifying a blob on-chain.
///
/// Corresponds to the TS SDK's `CertifyBlobOptions`.
/// Provide either [certificate] (from upload relay or aggregated confirmations)
/// or it will be aggregated automatically in direct mode.
@immutable
class CertifyBlobOptions {
  /// The Walrus blob ID.
  final String blobId;

  /// The Sui object ID of the on-chain Blob object.
  final String blobObjectId;

  /// Whether the blob is deletable.
  final bool deletable;

  /// Certificate from the upload relay or aggregated from node confirmations.
  final ProtocolMessageCertificate? certificate;

  /// Number of committee members (unique storage nodes).
  ///
  /// Required to convert the certificate's signer indices into the
  /// compact bitmap that the on-chain `certify_blob` Move call expects.
  /// Mirrors the TS SDK which passes `systemState.committee.members.length`.
  final int committeeSize;

  const CertifyBlobOptions({
    required this.blobId,
    required this.blobObjectId,
    required this.deletable,
    required this.committeeSize,
    this.certificate,
  });
}

// ---------------------------------------------------------------------------
// Direct-Mode Write Options (Phase 3)
// ---------------------------------------------------------------------------

/// Options for a direct-mode blob write (no upload relay).
///
/// Used when writing slivers directly to storage nodes.
@immutable
class DirectWriteOptions {
  /// Number of storage epochs.
  final int epochs;

  /// Whether the blob can be deleted.
  final bool deletable;

  /// Sui address that will own the blob object.
  final String? owner;

  /// Maximum time to wait for each storage node response.
  final Duration nodeTimeout;

  /// Maximum concurrent writes to storage nodes.
  final int maxConcurrency;

  const DirectWriteOptions({
    required this.epochs,
    required this.deletable,
    this.owner,
    this.nodeTimeout = const Duration(seconds: 30),
    this.maxConcurrency = 50,
  });
}

// ---------------------------------------------------------------------------
// Confirmation Aggregation Result (Phase 3)
// ---------------------------------------------------------------------------

/// Result of aggregating individual storage node confirmations
/// into a single certificate for on-chain certification.
///
/// In Phase 3, the client collects individual [StorageConfirmation]s
/// from storage nodes and aggregates their BLS signatures.
///
/// [Unverified] BLS signature aggregation requires a BLS12-381 library.
/// The current implementation collects confirmations; aggregation
/// can be performed using an external BLS library or deferred
/// to a future version that integrates Rust FFI.
@immutable
class ConfirmationAggregation {
  /// Storage node indices that provided valid confirmations.
  final List<int> signers;

  /// The BCS-serialized storage confirmation message.
  final Uint8List serializedMessage;

  /// Individual raw signatures from each confirming node.
  final List<Uint8List> individualSignatures;

  /// Whether a quorum of confirmations was collected.
  final bool hasQuorum;

  const ConfirmationAggregation({
    required this.signers,
    required this.serializedMessage,
    required this.individualSignatures,
    required this.hasQuorum,
  });

  /// Total weight (number of signers).
  int get weight => signers.length;

  @override
  String toString() =>
      'ConfirmationAggregation('
      'signers: ${signers.length}, '
      'hasQuorum: $hasQuorum)';
}
