/// Tests for [WalrusBlobEncoder] — encoding, BCS metadata, sliver sizes,
/// and encode→decode round-trip.
library;

import 'dart:typed_data';

import 'package:dartus/src/encoding/walrus_blob_encoder.dart';
import 'package:dartus/src/models/storage_node_types.dart';
import 'package:dartus/src/utils/encoding_utils.dart';
import 'package:test/test.dart';

void main() {
  late WalrusBlobEncoder encoder;

  setUp(() {
    encoder = WalrusBlobEncoder();
  });

  group('encodeBlob', () {
    test('produces correct number of slivers', () {
      final data = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      const numShards = 10;

      final encoded = encoder.encodeBlob(data, numShards);
      expect(encoded.primarySlivers.length, numShards);
      expect(encoded.secondarySlivers.length, numShards);
    });

    test('primary sliver size = secondarySymbols * symbolSize', () {
      final data = Uint8List.fromList(
        List.generate(2048, (i) => (i * 7) % 256),
      );
      const numShards = 10;

      final src = getSourceSymbols(numShards);
      final sizes = getSizes(data.length, numShards);

      final encoded = encoder.encodeBlob(data, numShards);
      final expectedPrimarySize = src.secondary * sizes.symbolSize;

      for (final sliver in encoded.primarySlivers) {
        expect(
          sliver.data.length,
          expectedPrimarySize,
          reason: 'Primary sliver should be secondarySymbols * symbolSize',
        );
        expect(sliver.symbolSize, sizes.symbolSize);
      }
    });

    test('secondary sliver size = primarySymbols * symbolSize', () {
      final data = Uint8List.fromList(
        List.generate(2048, (i) => (i * 3) % 256),
      );
      const numShards = 10;

      final src = getSourceSymbols(numShards);
      final sizes = getSizes(data.length, numShards);

      final encoded = encoder.encodeBlob(data, numShards);
      final expectedSecondarySize = src.primary * sizes.symbolSize;

      for (final sliver in encoded.secondarySlivers) {
        expect(
          sliver.data.length,
          expectedSecondarySize,
          reason: 'Secondary sliver should be primarySymbols * symbolSize',
        );
        expect(sliver.symbolSize, sizes.symbolSize);
      }
    });

    test('blob ID is 32 bytes', () {
      final data = Uint8List(100);
      final encoded = encoder.encodeBlob(data, 10);
      expect(encoded.blobIdBytes.length, 32);
      expect(encoded.blobId, isNotEmpty);
    });

    test('metadata bytes are non-empty', () {
      final data = Uint8List(500);
      final encoded = encoder.encodeBlob(data, 10);
      expect(encoded.metadataBytes, isNotEmpty);
    });

    test('BCS metadata starts with V1 variant prefix 0x00', () {
      final data = Uint8List(256);
      final encoded = encoder.encodeBlob(data, 10);
      expect(
        encoded.metadataBytes[0],
        0x00,
        reason: 'First byte must be V1 enum variant index',
      );
    });

    test('BCS metadata second byte is encoding type (RS2=1)', () {
      final data = Uint8List(256);
      final encoded = encoder.encodeBlob(data, 10);
      expect(
        encoded.metadataBytes[1],
        kEncodingTypeRS2,
        reason: 'Second byte must be encoding type',
      );
    });

    test('deterministic: same data → same blob ID', () {
      final data = Uint8List.fromList(List.generate(100, (i) => i));
      final e1 = encoder.encodeBlob(data, 10);
      final e2 = encoder.encodeBlob(data, 10);
      expect(e1.blobId, e2.blobId);
      expect(e1.blobIdBytes, equals(e2.blobIdBytes));
    });

    test('different data → different blob ID', () {
      final data1 = Uint8List.fromList(List.generate(100, (i) => i));
      final data2 = Uint8List.fromList(List.generate(100, (i) => i + 1));
      final e1 = encoder.encodeBlob(data1, 10);
      final e2 = encoder.encodeBlob(data2, 10);
      expect(e1.blobId, isNot(e2.blobId));
    });

    test('sliver indices are 0-based and sequential', () {
      final data = Uint8List(512);
      const numShards = 10;
      final encoded = encoder.encodeBlob(data, numShards);

      for (var i = 0; i < numShards; i++) {
        expect(encoded.primarySlivers[i].index, i);
        expect(encoded.secondarySlivers[i].index, i);
      }
    });

    test('handles minimal data (1 byte)', () {
      final data = Uint8List.fromList([42]);
      expect(() => encoder.encodeBlob(data, 4), returnsNormally);
      final encoded = encoder.encodeBlob(data, 4);
      expect(encoded.primarySlivers.length, 4);
      expect(encoded.secondarySlivers.length, 4);
    });

    test('handles larger data', () {
      // 1 MiB
      final data = Uint8List(1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }
      const numShards = 10;

      final encoded = encoder.encodeBlob(data, numShards);
      expect(encoded.primarySlivers.length, numShards);
      expect(encoded.secondarySlivers.length, numShards);
      expect(encoded.unencodedLength, data.length);
    });
  });

  group('computeMetadata', () {
    test('returns consistent blob ID and metadata', () async {
      final data = Uint8List.fromList(List.generate(200, (i) => i));
      const numShards = 10;

      final meta = await encoder.computeMetadata(data, numShards);
      expect(meta.blobId, isNotEmpty);
      expect(meta.rootHash.length, 32);
      expect(meta.nonce, isNotNull);

      // Should match encodeBlob's blob ID.
      final encoded = encoder.encodeBlob(data, numShards);
      expect(meta.blobId, encoded.blobId);
    });
  });

  group('bcsSliverData', () {
    test('encodes ULEB128 length + data + symbolSize + index', () {
      final sliver = SliverData(
        data: Uint8List.fromList([10, 20, 30]),
        symbolSize: 3,
        index: 7,
      );

      final encoded = WalrusBlobEncoder.bcsSliverData(sliver);

      // ULEB128(3) = [0x03]
      // data = [10, 20, 30]
      // symbolSize u16 LE = [3, 0]
      // index u16 LE = [7, 0]
      expect(encoded, equals([3, 10, 20, 30, 3, 0, 7, 0]));
    });

    test('encodes ULEB128 for larger lengths', () {
      // 128 bytes → ULEB128(128) = [0x80, 0x01]
      final sliver = SliverData(data: Uint8List(128), symbolSize: 4, index: 0);

      final encoded = WalrusBlobEncoder.bcsSliverData(sliver);
      // Check ULEB128 prefix: 0x80 0x01
      expect(encoded[0], 0x80);
      expect(encoded[1], 0x01);
      // Then 128 bytes of data
      // Then symbolSize u16 LE = [4, 0]
      // Then index u16 LE = [0, 0]
      expect(encoded.length, 2 + 128 + 2 + 2); // 134
    });
  });

  group('encode → decode round-trip', () {
    // Round-trip tests use the FFI encoder which produces canonical RS2
    // slivers, and the FFI decoder (walrus-core) for reconstruction.

    test('small data round-trips correctly', () {
      final original = Uint8List.fromList(
        List.generate(100, (i) => (i * 13) % 256),
      );
      const numShards = 10;

      final encoded = encoder.encodeBlob(original, numShards);
      final decoded = encoder.decodeBlob(
        primarySlivers: encoded.primarySlivers,
        numShards: numShards,
        unencodedLength: original.length,
      );

      expect(decoded, equals(original));
    });

    test('medium data round-trips correctly', () {
      final original = Uint8List(4096);
      for (var i = 0; i < original.length; i++) {
        original[i] = (i * 7 + 3) % 256;
      }
      const numShards = 10;

      final encoded = encoder.encodeBlob(original, numShards);
      final decoded = encoder.decodeBlob(
        primarySlivers: encoded.primarySlivers,
        numShards: numShards,
        unencodedLength: original.length,
      );

      expect(decoded, equals(original));
    });

    test('all-zeros round-trips', () {
      final original = Uint8List(512);
      const numShards = 10;

      final encoded = encoder.encodeBlob(original, numShards);
      final decoded = encoder.decodeBlob(
        primarySlivers: encoded.primarySlivers,
        numShards: numShards,
        unencodedLength: original.length,
      );

      expect(decoded, equals(original));
    });

    test('single byte round-trips', () {
      final original = Uint8List.fromList([0xFF]);
      const numShards = 4;

      final encoded = encoder.encodeBlob(original, numShards);
      final decoded = encoder.decodeBlob(
        primarySlivers: encoded.primarySlivers,
        numShards: numShards,
        unencodedLength: original.length,
      );

      expect(decoded, equals(original));
    });
  });
}
