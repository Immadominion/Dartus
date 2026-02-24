/// Concrete [BlsProvider] backed by the `bls_dart` package.
///
/// Uses [flutter_rust_bridge] + the `blst` crate for BLS12-381 min_pk
/// operations. Before creating an instance, the Rust runtime must be
/// initialized:
///
/// ```dart
/// import 'package:bls_dart/bls_dart.dart';
///
/// await RustLib.init();
/// final provider = BlsDartProvider();
/// ```
///
/// This file is kept separate from [bls_provider.dart] so that
/// consumers who do not use `bls_dart` (e.g., relay-only mode)
/// avoid pulling in the native dependency.
library;

import 'dart:typed_data';

import 'package:bls_dart/bls_dart.dart';

import 'bls_provider.dart';

/// BLS12-381 min_pk provider powered by the `bls_dart` FFI package.
///
/// Usage:
/// ```dart
/// import 'package:bls_dart/bls_dart.dart';
/// import 'package:dartus/dartus.dart';
///
/// void main() async {
///   await RustLib.init();
///
///   final client = WalrusDirectClient(
///     network: WalrusNetwork.testnet(),
///     blsProvider: BlsDartProvider(),
///   );
/// }
/// ```
class BlsDartProvider implements BlsProvider {
  /// Creates a [BlsDartProvider].
  ///
  /// Ensure [RustLib.init] has been called before invoking any method.
  const BlsDartProvider();

  @override
  bool verify(Uint8List signature, Uint8List publicKey, Uint8List message) {
    return bls12381MinPkVerify(
      sigBytes: signature,
      pkBytes: publicKey,
      msg: message,
    );
  }

  @override
  Uint8List aggregate(List<Uint8List> signatures) {
    final result = bls12381MinPkAggregate(sigsBytes: signatures);
    if (result.isEmpty) {
      throw ArgumentError(
        'BLS signature aggregation failed — '
        'check that all inputs are valid 96-byte G2 signatures',
      );
    }
    return result;
  }

  @override
  bool verifyAggregate(
    List<Uint8List> publicKeys,
    Uint8List message,
    Uint8List aggregateSignature,
  ) {
    return bls12381MinPkVerifyAggregate(
      pksBytes: publicKeys,
      msg: message,
      aggSigBytes: aggregateSignature,
    );
  }
}
