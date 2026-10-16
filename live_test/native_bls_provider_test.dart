@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bls_dart/bls_dart.dart';
import 'package:dartus/src/crypto/bls_dart_provider.dart';
// bls_dart exposes this bridge type in RustLib.init's public signature.
// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:test/test.dart';

/// Opt-in native runtime check; no network, wallet secrets, or Sui transactions.
/// Build bls_dart, then set DARTUS_BLS_LIBRARY to its dynamic-library path.
void main() {
  setUpAll(() async {
    final path = Platform.environment['DARTUS_BLS_LIBRARY'];
    if (path == null || path.isEmpty) {
      fail('Set DARTUS_BLS_LIBRARY to a built bls_dart dynamic library');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(path));
  });
  final fixture =
      jsonDecode(File('test/fixtures/bls_min_pk.json').readAsStringSync())
          as Map<String, dynamic>;
  Uint8List bytes(String key) =>
      Uint8List.fromList((fixture[key] as List).cast<int>());
  const provider = BlsDartProvider();

  test(
    'real min_pk provider verifies compressed and on-chain uncompressed G1',
    () {
      expect(bytes('pk1'), hasLength(48));
      expect(bytes('pk1Uncompressed'), hasLength(96));
      expect(
        provider.verify(bytes('sig1'), bytes('pk1'), bytes('message')),
        isTrue,
      );
      expect(
        provider.verify(
          bytes('sig1'),
          bytes('pk1Uncompressed'),
          bytes('message'),
        ),
        isTrue,
      );
      expect(
        provider.verify(
          bytes('sig1'),
          bytes('pk2Uncompressed'),
          bytes('message'),
        ),
        isFalse,
      );
      expect(
        provider.verify(
          bytes('sig1'),
          bytes('pk1Uncompressed'),
          Uint8List.fromList([0]),
        ),
        isFalse,
      );
    },
  );
  test(
    'real provider aggregates and verifies against uncompressed committee keys',
    () {
      final signature = provider.aggregate([bytes('sig1'), bytes('sig2')]);
      expect(signature, hasLength(96));
      expect(
        provider.verifyAggregate(
          [bytes('pk1Uncompressed'), bytes('pk2Uncompressed')],
          bytes('message'),
          signature,
        ),
        isTrue,
      );
      expect(
        provider.verifyAggregate(
          [bytes('pk1'), bytes('pk2')],
          bytes('message'),
          signature,
        ),
        isTrue,
      );
      expect(
        provider.verifyAggregate(
          [bytes('pk1Uncompressed')],
          bytes('message'),
          signature,
        ),
        isFalse,
      );
    },
  );
}
