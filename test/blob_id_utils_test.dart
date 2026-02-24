/// Tests for [blob_id_utils.dart].
///
/// Verifies BCS blob ID encoding/decoding against known values.
library;

import 'dart:typed_data';

import 'package:dartus/src/utils/blob_id_utils.dart';
import 'package:test/test.dart';

void main() {
  group('blobIdFromInt', () {
    test('encodes zero as URL-safe base64', () {
      final result = blobIdFromInt(BigInt.zero);
      expect(result, isA<String>());
      expect(result.isNotEmpty, isTrue);
      // Should not contain padding or unsafe chars.
      expect(result.contains('+'), isFalse);
      expect(result.contains('/'), isFalse);
    });

    test('round-trips through blobIdToInt', () {
      final values = [
        BigInt.zero,
        BigInt.one,
        BigInt.from(255),
        BigInt.from(256),
        BigInt.from(0xDEADBEEF),
        BigInt.parse('123456789012345678901234567890'),
      ];

      for (final v in values) {
        final encoded = blobIdFromInt(v);
        final roundTripped = blobIdToInt(encoded);
        expect(roundTripped, v, reason: 'round-trip failed for $v');
      }
    });

    test('encodes max u256 without error', () {
      final maxU256 = (BigInt.one << 256) - BigInt.one;
      final result = blobIdFromInt(maxU256);
      expect(result, isA<String>());
      expect(result.isNotEmpty, isTrue);
    });

    test('different values produce different strings', () {
      final a = blobIdFromInt(BigInt.one);
      final b = blobIdFromInt(BigInt.two);
      expect(a, isNot(equals(b)));
    });
  });

  group('blobIdToInt', () {
    test('decodes zero blob ID', () {
      final zeroEncoded = blobIdFromInt(BigInt.zero);
      expect(blobIdToInt(zeroEncoded), BigInt.zero);
    });

    test('decodes max u256', () {
      final maxU256 = (BigInt.one << 256) - BigInt.one;
      final encoded = blobIdFromInt(maxU256);
      expect(blobIdToInt(encoded), maxU256);
    });
  });

  group('blobIdFromBytes', () {
    test('returns URL-safe base64 blob ID string', () {
      final bytes = Uint8List(32);
      final result = blobIdFromBytes(bytes);
      expect(result, isA<String>());
      expect(result.contains('+'), isFalse);
      expect(result.contains('/'), isFalse);
    });

    test('consistent with blobIdFromInt for same value', () {
      final value = BigInt.from(42);
      final fromInt = blobIdFromInt(value);

      // Manually create the 32-byte LE representation of 42.
      final bytes = Uint8List(32);
      bytes[0] = 42;
      final fromBytes = blobIdFromBytes(bytes);

      expect(fromBytes, fromInt);
    });

    test('throws for wrong length', () {
      expect(() => blobIdFromBytes(Uint8List(31)), throwsArgumentError);
      expect(() => blobIdFromBytes(Uint8List(33)), throwsArgumentError);
    });
  });
}
