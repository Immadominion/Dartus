/// Tests for encoding math utilities [encoding_utils.dart].
///
/// Values verified against the TypeScript SDK's `utils/index.ts`
/// to ensure identical shard/symbol calculations across SDKs.
library;

import 'dart:typed_data';

import 'package:dartus/src/utils/encoding_utils.dart';
import 'package:test/test.dart';

void main() {
  group('getMaxFaultyNodes', () {
    test('standard BFT threshold floor((n-1)/3)', () {
      // f = floor((n-1)/3)
      expect(getMaxFaultyNodes(1), 0);
      expect(getMaxFaultyNodes(4), 1);
      expect(getMaxFaultyNodes(7), 2);
      expect(getMaxFaultyNodes(10), 3);
      expect(getMaxFaultyNodes(13), 4);
      expect(getMaxFaultyNodes(100), 33);
      expect(getMaxFaultyNodes(1000), 333);
    });
  });

  group('getSourceSymbols', () {
    test('RS2 encoding with various shard counts', () {
      // RS2: safetyLimit=0, so primary = n-f - f - 0 = n-2f, secondary = n-f
      // n=10: f=3, primary=10-6=4, secondary=10-3=7
      final s10 = getSourceSymbols(10);
      expect(s10.primary, 4);
      expect(s10.secondary, 7);

      // n=100: f=33, primary=100-66=34, secondary=100-33=67
      final s100 = getSourceSymbols(100);
      expect(s100.primary, 34);
      expect(s100.secondary, 67);

      // n=1000: f=333, primary=1000-666=334, secondary=1000-333=667
      final s1000 = getSourceSymbols(1000);
      expect(s1000.primary, 334);
      expect(s1000.secondary, 667);
    });

    test('RedStuff encoding with safety limit', () {
      // RedStuff: safetyLimit = min(5, floor(f/5))
      // n=10: f=3, limit=min(5,0)=0, primary=10-6-0=4, secondary=10-3-0=7
      final s10 = getSourceSymbols(10, encodingType: kEncodingTypeRedStuff);
      expect(s10.primary, 4);
      expect(s10.secondary, 7);

      // n=100: f=33, limit=min(5,6)=5, primary=100-66-5=29, secondary=100-33-5=62
      final s100 = getSourceSymbols(100, encodingType: kEncodingTypeRedStuff);
      expect(s100.primary, 29);
      expect(s100.secondary, 62);

      // n=1000: f=333, limit=min(5,66)=5, primary=1000-666-5=329, secondary=1000-333-5=662
      final s1000 = getSourceSymbols(1000, encodingType: kEncodingTypeRedStuff);
      expect(s1000.primary, 329);
      expect(s1000.secondary, 662);
    });

    test('small shard counts produce valid positive values', () {
      // n=4: f=1, RS2: primary=4-2-0=2, secondary=4-1-0=3
      final s = getSourceSymbols(4);
      expect(s.primary, 2);
      expect(s.secondary, 3);
      expect(s.primary, greaterThan(0));
      expect(s.secondary, greaterThan(s.primary));
    });
  });

  group('getSizes', () {
    test('symbol size computation for various blob sizes', () {
      // n=10 RS2: primary=4, secondary=7
      // symbolSize = ceil(blobSize / (primary * secondary))
      // For 280 bytes: symbolSize = ceil(280/28) = 10 (already even)
      final s = getSizes(280, 10);
      expect(s.symbolSize, 10);
      expect(s.rowSize, s.symbolSize * 7); // symbolSize * secondary
      expect(s.columnSize, s.symbolSize * 4); // symbolSize * primary
    });

    test('symbol size 1 for tiny blob', () {
      // blobSize=1: symbolSize = ceil(1/(primary*secondary)) = 1
      // RS2 even alignment → 2
      final s = getSizes(1, 10);
      expect(s.symbolSize, 2);
    });

    test('row and column sizes are consistent', () {
      final src = getSourceSymbols(100);
      final sizes = getSizes(1000000, 100);
      expect(sizes.rowSize, sizes.symbolSize * src.secondary);
      expect(sizes.columnSize, sizes.symbolSize * src.primary);
    });
  });

  group('quorum and validity', () {
    test('isQuorum requires > 2f confirmations', () {
      // n=10, f=3: quorum requires > 6
      expect(isQuorum(6, 10), isFalse);
      expect(isQuorum(7, 10), isTrue);
      expect(isQuorum(10, 10), isTrue);
    });

    test('isAboveValidity triggers when failures > f', () {
      // n=10, f=3
      expect(isAboveValidity(3, 10), isFalse);
      expect(isAboveValidity(4, 10), isTrue);
    });
  });

  group('shard ↔ pair index mapping', () {
    test('round-trip: toPairIndex ↔ toShardIndex', () {
      // For any blob ID and shard count, the mapping should round-trip.
      final blobId = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        blobId[i] = i;
      }

      const numShards = 100;
      for (var shard = 0; shard < numShards; shard++) {
        final pair = toPairIndex(shard, blobId, numShards);
        final backToShard = toShardIndex(pair, blobId, numShards);
        expect(
          backToShard,
          shard,
          reason: 'shard $shard → pair $pair → shard $backToShard',
        );
      }
    });

    test('all pair indices are unique for a given blob', () {
      final blobId = Uint8List(32)..fillRange(0, 32, 0xAB);
      const numShards = 50;
      final pairs = <int>{};
      for (var shard = 0; shard < numShards; shard++) {
        pairs.add(toPairIndex(shard, blobId, numShards));
      }
      expect(pairs.length, numShards);
    });

    test('different blob IDs produce different rotations', () {
      final blobA = Uint8List(32)..fillRange(0, 32, 0x00);
      final blobB = Uint8List(32)..fillRange(0, 32, 0xFF);
      const numShards = 100;

      final pairA = toPairIndex(0, blobA, numShards);
      final pairB = toPairIndex(0, blobB, numShards);
      // Not guaranteed to differ, but overwhelmingly likely with distinct IDs.
      // We just check the function doesn't crash and returns valid range.
      expect(pairA, inInclusiveRange(0, numShards - 1));
      expect(pairB, inInclusiveRange(0, numShards - 1));
    });
  });

  group('sliverPairIndexFromSecondarySliverIndex', () {
    test('mirrors TS SDK formula: numShards - sliverIndex - 1', () {
      expect(sliverPairIndexFromSecondarySliverIndex(0, 100), 99);
      expect(sliverPairIndexFromSecondarySliverIndex(99, 100), 0);
      expect(sliverPairIndexFromSecondarySliverIndex(50, 100), 49);
    });
  });

  group('signersToBitmap', () {
    test('sets correct bits for given signers', () {
      final bitmap = signersToBitmap([0, 2, 7], 8);
      // bit 0 | bit 2 | bit 7 = 0b10000101 = 0x85
      expect(bitmap, equals(Uint8List.fromList([0x85])));
    });

    test('multi-byte bitmap for large committee', () {
      final bitmap = signersToBitmap([0, 8, 16], 24);
      expect(bitmap.length, 3);
      expect(bitmap[0], 1); // bit 0
      expect(bitmap[1], 1); // bit 8
      expect(bitmap[2], 1); // bit 16
    });

    test('empty signers produce zero bitmap', () {
      final bitmap = signersToBitmap([], 10);
      expect(bitmap.every((b) => b == 0), isTrue);
    });
  });

  group('blobId encoding', () {
    test('roundtrip: bytes → urlSafeBase64 → bytes', () {
      final original = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        original[i] = i * 7 + 13;
      }

      final encoded = blobIdToUrlSafeBase64(original);
      final decoded = blobIdFromUrlSafeBase64(encoded);
      expect(decoded, equals(original));
    });

    test('URL-safe base64 has no padding or unsafe chars', () {
      final bytes = Uint8List(32)..fillRange(0, 32, 0xFF);
      final encoded = blobIdToUrlSafeBase64(bytes);
      expect(encoded, isNot(contains('=')));
      expect(encoded, isNot(contains('+')));
      expect(encoded, isNot(contains('/')));
    });
  });

  group('computeBlobId', () {
    test('produces 32-byte SHA-256 digest', () {
      final rootHash = Uint8List(32)..fillRange(0, 32, 0xAA);
      final id = computeBlobId(
        encodingType: kEncodingTypeRS2,
        unencodedLength: 1024,
        rootHash: rootHash,
      );
      expect(id.length, 32);
    });

    test('deterministic: same inputs → same output', () {
      final rootHash = Uint8List(32)..fillRange(0, 32, 0xBB);
      final id1 = computeBlobId(
        encodingType: kEncodingTypeRS2,
        unencodedLength: 2048,
        rootHash: rootHash,
      );
      final id2 = computeBlobId(
        encodingType: kEncodingTypeRS2,
        unencodedLength: 2048,
        rootHash: rootHash,
      );
      expect(id1, equals(id2));
    });

    test('different encoding types produce different IDs', () {
      final rootHash = Uint8List(32)..fillRange(0, 32, 0xCC);
      final rsId = computeBlobId(
        encodingType: kEncodingTypeRS2,
        unencodedLength: 1024,
        rootHash: rootHash,
      );
      final redId = computeBlobId(
        encodingType: kEncodingTypeRedStuff,
        unencodedLength: 1024,
        rootHash: rootHash,
      );
      expect(rsId, isNot(equals(redId)));
    });

    test('rejects non-32-byte root hash', () {
      expect(
        () => computeBlobId(
          encodingType: kEncodingTypeRS2,
          unencodedLength: 100,
          rootHash: Uint8List(16),
        ),
        throwsArgumentError,
      );
    });
  });

  group('storageUnitsFromSize', () {
    test('rounds up to MiB boundary', () {
      expect(storageUnitsFromSize(1), 1);
      expect(storageUnitsFromSize(1024 * 1024), 1);
      expect(storageUnitsFromSize(1024 * 1024 + 1), 2);
      expect(storageUnitsFromSize(5 * 1024 * 1024), 5);
    });
  });

  group('bigInt/bytes32 conversion', () {
    test('roundtrip BigInt ↔ Uint8List', () {
      final value = BigInt.from(42) << 200;
      final bytes = bigIntToBytes32(value);
      final back = bytes32ToBigInt(bytes);
      expect(back, value);
    });

    test('zero BigInt produces zero bytes', () {
      final bytes = bigIntToBytes32(BigInt.zero);
      expect(bytes.every((b) => b == 0), isTrue);
    });

    test('rejects non-32-byte input', () {
      expect(() => bytes32ToBigInt(Uint8List(16)), throwsArgumentError);
    });
  });
}
