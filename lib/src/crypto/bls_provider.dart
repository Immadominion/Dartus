/// BLS12-381 signature operations interface for Walrus blob certification.
///
/// This provides an abstraction layer so that the Dartus SDK can use
/// different BLS implementations:
///
/// - [BlsDartProvider] — uses the `bls_dart` package (Rust FFI via
///   flutter_rust_bridge, recommended for production)
/// - Custom implementations can extend [BlsProvider] for testing or
///   alternative crypto backends.
///
/// Without a BLS provider, [WalrusDirectClient] falls back to the
/// single-signature placeholder (sufficient for relay mode but not
/// for on-chain direct-mode certification with multiple signers).
library;

import 'dart:typed_data';

/// Interface for BLS12-381 min_pk signature operations.
///
/// Implementations must use the standard IETF RFC 9380 DST:
/// `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_`
///
/// This matches Sui Move's native `bls12381_min_pk_verify`,
/// MystenLabs `fastcrypto`, and the Walrus protocol.
abstract class BlsProvider {
  /// Verify a single BLS12-381 min_pk signature.
  ///
  /// - [signature] — 96-byte compressed G2 signature
  /// - [publicKey] — 48-byte compressed G1 public key
  /// - [message] — arbitrary-length message bytes
  ///
  /// Returns `true` if the signature is valid.
  bool verify(Uint8List signature, Uint8List publicKey, Uint8List message);

  /// Aggregate multiple BLS12-381 min_pk signatures into one.
  ///
  /// Each signature in [signatures] must be 96 bytes.
  /// Returns the 96-byte aggregate signature.
  ///
  /// Throws [ArgumentError] if [signatures] is empty or any entry is
  /// malformed.
  Uint8List aggregate(List<Uint8List> signatures);

  /// Verify an aggregate BLS12-381 min_pk signature where all signers
  /// signed the same [message].
  ///
  /// - [publicKeys] — list of 48-byte compressed G1 public keys
  /// - [message] — the shared message all signers signed
  /// - [aggregateSignature] — 96-byte compressed aggregate G2 signature
  ///
  /// Returns `true` if the aggregate signature is valid.
  bool verifyAggregate(
    List<Uint8List> publicKeys,
    Uint8List message,
    Uint8List aggregateSignature,
  );
}
