/// Tests for BCS parser utilities (parseSliverResponse,
/// parseBlobMetadataResponse, encodeSliverForUpload).
///
/// Validates round-trip encoding/decoding and error handling for
/// BCS-encoded storage node responses.
library;

import 'dart:typed_data';

import 'package:dartus/src/encoding/bcs_parser.dart';
import 'package:dartus/src/models/storage_node_types.dart';
import 'package:test/test.dart';

void main() {
  group('parseSliverResponse', () {
    test('parses a Primary sliver correctly', () {
      // Build a BCS-encoded Primary Sliver manually:
      // variant=0 (Primary), data=[1,2,3,4] (ULEB128 len=4), symbolSize=2, index=7
      final builder = BytesBuilder(copy: false);
      builder.addByte(0); // variant: Primary
      builder.addByte(4); // ULEB128: data length = 4
      builder.add([1, 2, 3, 4]); // data bytes
      builder.addByte(2); // symbol_size low byte
      builder.addByte(0); // symbol_size high byte (= 2)
      builder.addByte(7); // index low byte
      builder.addByte(0); // index high byte (= 7)

      final bcs = Uint8List.fromList(builder.toBytes());
      final parsed = parseSliverResponse(bcs);

      expect(parsed.data, equals([1, 2, 3, 4]));
      expect(parsed.symbolSize, 2);
      expect(parsed.index, 7);
    });

    test('parses a Secondary sliver correctly', () {
      final builder = BytesBuilder(copy: false);
      builder.addByte(1); // variant: Secondary
      builder.addByte(3); // ULEB128: data length = 3
      builder.add([10, 20, 30]); // data bytes
      builder.addByte(16); // symbol_size = 16
      builder.addByte(0);
      builder.addByte(42); // index = 42
      builder.addByte(0);

      final bcs = Uint8List.fromList(builder.toBytes());
      final parsed = parseSliverResponse(bcs);

      expect(parsed.data, equals([10, 20, 30]));
      expect(parsed.symbolSize, 16);
      expect(parsed.index, 42);
    });

    test('handles large data with multi-byte ULEB128 length', () {
      // Data length = 300 → ULEB128 = [0xAC, 0x02]
      final data = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final builder = BytesBuilder(copy: false);
      builder.addByte(0); // variant
      builder.addByte(0xAC); // ULEB128 low byte
      builder.addByte(0x02); // ULEB128 high byte (300 = 0x12C = 0b10_0101100)
      builder.add(data);
      builder.addByte(8); // symbol_size = 8
      builder.addByte(0);
      builder.addByte(0); // index = 0
      builder.addByte(0);

      final bcs = Uint8List.fromList(builder.toBytes());
      final parsed = parseSliverResponse(bcs);

      expect(parsed.data.length, 300);
      expect(parsed.data, equals(data));
      expect(parsed.symbolSize, 8);
      expect(parsed.index, 0);
    });

    test('handles large symbol_size and index (u16)', () {
      final builder = BytesBuilder(copy: false);
      builder.addByte(0); // variant
      builder.addByte(2); // data length = 2
      builder.add([0xFF, 0xFE]);
      // symbol_size = 1024 = 0x0400
      builder.addByte(0x00);
      builder.addByte(0x04);
      // index = 999 = 0x03E7
      builder.addByte(0xE7);
      builder.addByte(0x03);

      final bcs = Uint8List.fromList(builder.toBytes());
      final parsed = parseSliverResponse(bcs);

      expect(parsed.symbolSize, 1024);
      expect(parsed.index, 999);
    });

    test('throws on empty input', () {
      expect(() => parseSliverResponse(Uint8List(0)), throwsFormatException);
    });

    test('throws when data is truncated', () {
      final builder = BytesBuilder(copy: false);
      builder.addByte(0); // variant
      builder.addByte(100); // claims 100 bytes of data
      builder.add([1, 2, 3]); // only 3 bytes

      expect(
        () => parseSliverResponse(Uint8List.fromList(builder.toBytes())),
        throwsFormatException,
      );
    });

    test('throws when symbol_size bytes missing', () {
      final builder = BytesBuilder(copy: false);
      builder.addByte(0); // variant
      builder.addByte(1); // data length = 1
      builder.addByte(42); // data
      // Missing symbol_size and index

      expect(
        () => parseSliverResponse(Uint8List.fromList(builder.toBytes())),
        throwsFormatException,
      );
    });

    test('throws when index bytes missing', () {
      final builder = BytesBuilder(copy: false);
      builder.addByte(0); // variant
      builder.addByte(1); // data length = 1
      builder.addByte(42); // data
      builder.addByte(4); // symbol_size (only 1 byte of u16)
      builder.addByte(0);
      // Missing index

      expect(
        () => parseSliverResponse(Uint8List.fromList(builder.toBytes())),
        throwsFormatException,
      );
    });
  });

  group('encodeSliverForUpload', () {
    test('round-trips with parseSliverResponse for Primary', () {
      final original = SliverData(
        data: Uint8List.fromList([10, 20, 30, 40, 50]),
        symbolSize: 5,
        index: 3,
      );

      final encoded = encodeSliverForUpload(original, SliverType.primary);
      final decoded = parseSliverResponse(encoded);

      expect(decoded.data, equals(original.data));
      expect(decoded.symbolSize, original.symbolSize);
      expect(decoded.index, original.index);
    });

    test('round-trips with parseSliverResponse for Secondary', () {
      final original = SliverData(
        data: Uint8List.fromList(List.generate(256, (i) => i)),
        symbolSize: 128,
        index: 15,
      );

      final encoded = encodeSliverForUpload(original, SliverType.secondary);
      final decoded = parseSliverResponse(encoded);

      expect(decoded.data, equals(original.data));
      expect(decoded.symbolSize, original.symbolSize);
      expect(decoded.index, original.index);
    });

    test('variant byte is 0 for Primary', () {
      final sliver = SliverData(data: Uint8List(1), symbolSize: 1, index: 0);
      final encoded = encodeSliverForUpload(sliver, SliverType.primary);
      expect(encoded[0], 0);
    });

    test('variant byte is 1 for Secondary', () {
      final sliver = SliverData(data: Uint8List(1), symbolSize: 1, index: 0);
      final encoded = encodeSliverForUpload(sliver, SliverType.secondary);
      expect(encoded[0], 1);
    });

    test('round-trips large data (> 127 bytes, multi-byte ULEB128)', () {
      final data = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final original = SliverData(data: data, symbolSize: 50, index: 200);

      final encoded = encodeSliverForUpload(original, SliverType.primary);
      final decoded = parseSliverResponse(encoded);

      expect(decoded.data, equals(original.data));
      expect(decoded.symbolSize, original.symbolSize);
      expect(decoded.index, original.index);
    });

    test('handles empty data', () {
      final original = SliverData(data: Uint8List(0), symbolSize: 0, index: 0);

      final encoded = encodeSliverForUpload(original, SliverType.primary);
      final decoded = parseSliverResponse(encoded);

      expect(decoded.data.length, 0);
      expect(decoded.symbolSize, 0);
      expect(decoded.index, 0);
    });
  });

  group('parseBlobMetadataResponse', () {
    Uint8List buildMetadataBcs({
      required Uint8List blobId,
      int metadataVariant = 0,
      int encodingType = 0,
      int unencodedLength = 0,
    }) {
      final bytes = Uint8List(42);
      bytes.setAll(0, blobId);
      bytes[32] = metadataVariant;
      bytes[33] = encodingType;
      // u64 LE for unencodedLength
      var len = unencodedLength;
      for (var i = 0; i < 8; i++) {
        bytes[34 + i] = len & 0xFF;
        len >>= 8;
      }
      return bytes;
    }

    test('parses blobId, encodingType, unencodedLength correctly', () {
      final blobId = Uint8List.fromList(List.generate(32, (i) => i));
      final bcs = buildMetadataBcs(
        blobId: blobId,
        encodingType: 0,
        unencodedLength: 12345,
      );

      final parsed = parseBlobMetadataResponse(bcs);

      expect(parsed.blobIdBytes, equals(blobId));
      expect(parsed.encodingType, 0);
      expect(parsed.unencodedLength, 12345);
    });

    test('parses RS2 encoding type', () {
      final blobId = Uint8List(32);
      final bcs = buildMetadataBcs(
        blobId: blobId,
        encodingType: 1,
        unencodedLength: 1024,
      );

      final parsed = parseBlobMetadataResponse(bcs);
      expect(parsed.encodingType, 1);
    });

    test('parses large unencodedLength correctly', () {
      final blobId = Uint8List(32);
      // Use a value that exercises multiple bytes of u64.
      // 1_000_000 = 0xF4240
      final bcs = buildMetadataBcs(blobId: blobId, unencodedLength: 1000000);

      final parsed = parseBlobMetadataResponse(bcs);
      expect(parsed.unencodedLength, 1000000);
    });

    test('throws on too-short input', () {
      expect(
        () => parseBlobMetadataResponse(Uint8List(10)),
        throwsFormatException,
      );
      expect(
        () => parseBlobMetadataResponse(Uint8List(41)),
        throwsFormatException,
      );
    });

    test('throws on unknown metadata variant', () {
      final blobId = Uint8List(32);
      final bcs = buildMetadataBcs(blobId: blobId);
      bcs[32] = 5; // Invalid variant

      expect(() => parseBlobMetadataResponse(bcs), throwsFormatException);
    });

    test('accepts extra trailing bytes (hashes vector)', () {
      // Real BCS will have hashes data after byte 42.
      final bcs = Uint8List(100);
      bcs.setAll(0, List.generate(32, (i) => i));
      bcs[32] = 0; // V1
      bcs[33] = 0; // RedStuff
      // unencodedLength = 42
      bcs[34] = 42;

      final parsed = parseBlobMetadataResponse(bcs);
      expect(parsed.unencodedLength, 42);
    });
  });
}
