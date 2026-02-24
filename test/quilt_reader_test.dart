/// Tests for quilt reading infrastructure:
/// - [parseQuiltPatchId] / [encodeQuiltPatchId] round-trip
/// - [parseWalrusId] blob vs quilt patch detection
/// - [BlobReader] with mock callbacks
/// - [QuiltReader] index reading and blob extraction
/// - [QuiltFileReader] lazy file reading from quilts
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/src/files/file.dart';
import 'package:dartus/src/files/readers/blob_reader.dart';
import 'package:dartus/src/files/readers/quilt_reader.dart';
import 'package:dartus/src/utils/encoding_utils.dart';
import 'package:dartus/src/utils/quilts.dart';
import 'package:test/test.dart';

/// Helper: generate a valid URL-safe base64 blob ID from a seed.
String _makeBlobId([int seed = 0]) {
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (i * 7 + seed) & 0xFF;
  }
  return blobIdToUrlSafeBase64(bytes);
}

void main() {
  group('parseQuiltPatchId', () {
    test('round-trips with encodeQuiltPatchId', () {
      final quiltBlobId = blobIdToUrlSafeBase64(Uint8List(32));

      final encoded = encodeQuiltPatchId(
        quiltBlobId: quiltBlobId,
        version: 1,
        startIndex: 3,
        endIndex: 7,
      );

      final parsed = parseQuiltPatchId(encoded);

      expect(parsed.quiltId, quiltBlobId);
      expect(parsed.version, 1);
      expect(parsed.startIndex, 3);
      expect(parsed.endIndex, 7);
    });

    test('round-trips with non-zero blob ID', () {
      final blobIdBytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        blobIdBytes[i] = (i * 7 + 13) & 0xFF;
      }
      final quiltBlobId = blobIdToUrlSafeBase64(blobIdBytes);

      final encoded = encodeQuiltPatchId(
        quiltBlobId: quiltBlobId,
        version: 1,
        startIndex: 100,
        endIndex: 200,
      );

      final parsed = parseQuiltPatchId(encoded);

      expect(parsed.quiltId, quiltBlobId);
      expect(parsed.version, 1);
      expect(parsed.startIndex, 100);
      expect(parsed.endIndex, 200);
    });

    test('preserves max u16 values', () {
      final quiltBlobId = blobIdToUrlSafeBase64(Uint8List(32));

      final encoded = encodeQuiltPatchId(
        quiltBlobId: quiltBlobId,
        version: 255,
        startIndex: 65535,
        endIndex: 65535,
      );

      final parsed = parseQuiltPatchId(encoded);
      expect(parsed.version, 255);
      expect(parsed.startIndex, 65535);
      expect(parsed.endIndex, 65535);
    });
  });

  group('parseWalrusId', () {
    test('identifies 32-byte blob IDs', () {
      final blobId = blobIdToUrlSafeBase64(Uint8List(32));
      final parsed = parseWalrusId(blobId);

      expect(parsed.kind, 'blob');
      expect(parsed.blobId, blobId);
      expect(parsed.patchId, isNull);
    });

    test('identifies quilt patch IDs (37 bytes)', () {
      final quiltBlobId = blobIdToUrlSafeBase64(Uint8List(32));
      final patchEncoded = encodeQuiltPatchId(
        quiltBlobId: quiltBlobId,
        version: 1,
        startIndex: 5,
        endIndex: 10,
      );

      final parsed = parseWalrusId(patchEncoded);

      expect(parsed.kind, 'quiltPatch');
      expect(parsed.patchId, isNotNull);
      expect(parsed.patchId!.quiltId, quiltBlobId);
      expect(parsed.patchId!.startIndex, 5);
      expect(parsed.patchId!.endIndex, 10);
      expect(parsed.blobId, isNull);
    });
  });

  group('BlobReader', () {
    test('caches full blob bytes', () async {
      var callCount = 0;
      final testData = utf8.encode('Hello, Walrus!');

      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async {
          callCount++;
          return testData;
        },
        readSecondarySliver: (blobId, index) async {
          throw UnimplementedError();
        },
      );

      final bytes1 = await reader.getBytes();
      final bytes2 = await reader.getBytes();

      expect(bytes1, equals(testData));
      expect(bytes2, equals(testData));
      expect(callCount, 1, reason: 'Should only fetch once');
    });

    test('caches secondary slivers', () async {
      var callCount = 0;
      final sliverData = Uint8List.fromList(List.filled(100, 42));

      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async {
          callCount++;
          return sliverData;
        },
      );

      final sliver1 = await reader.getSecondarySliver(sliverIndex: 0);
      final sliver2 = await reader.getSecondarySliver(sliverIndex: 0);

      expect(sliver1, equals(sliverData));
      expect(sliver2, equals(sliverData));
      expect(callCount, 1, reason: 'Should only fetch once per index');
    });

    test('sets hasStartedLoadingFullBlob on getBytes', () async {
      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(10),
        readSecondarySliver: (blobId, index) async => Uint8List(5),
      );

      expect(reader.hasStartedLoadingFullBlob, isFalse);

      await reader.getBytes();

      expect(reader.hasStartedLoadingFullBlob, isTrue);
    });

    test('resets hasStartedLoadingFullBlob on failure', () async {
      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async {
          throw Exception('fail');
        },
        readSecondarySliver: (blobId, index) async => Uint8List(5),
      );

      try {
        await reader.getBytes();
      } catch (_) {}

      expect(reader.hasStartedLoadingFullBlob, isFalse);
    });

    test('implements WalrusFileReader', () {
      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async => Uint8List(0),
      );

      expect(reader, isA<WalrusFileReader>());
    });

    test('getIdentifier returns null', () async {
      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async => Uint8List(0),
      );

      expect(await reader.getIdentifier(), isNull);
    });

    test('getTags returns empty map', () async {
      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async => Uint8List(0),
      );

      expect(await reader.getTags(), isEmpty);
    });

    test('getQuiltReader returns QuiltReader', () {
      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async => Uint8List(0),
      );

      final quiltReader = reader.getQuiltReader();
      expect(quiltReader, isA<QuiltReader>());
    });

    test('removes sliver from cache on failure', () async {
      var callCount = 0;

      final reader = BlobReader(
        blobId: 'test-blob',
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async {
          callCount++;
          if (callCount == 1) throw Exception('fail');
          return Uint8List.fromList([42]);
        },
      );

      // First call fails.
      try {
        await reader.getSecondarySliver(sliverIndex: 0);
      } catch (_) {}

      // Second call should retry (not use cached failure).
      final result = await reader.getSecondarySliver(sliverIndex: 0);
      expect(result, equals(Uint8List.fromList([42])));
      expect(callCount, 2);
    });
  });

  group('QuiltReader - round-trip encode/read', () {
    // Helper: encode a quilt and create a BlobReader that serves it.
    BlobReader createQuiltBlobReader(EncodeQuiltResult result) {
      return BlobReader(
        blobId: _makeBlobId(42),
        numShards: 1000,
        readBlob: (blobId) async => result.quilt,
        readSecondarySliver: (blobId, index) async {
          // Extract a secondary sliver (column) from the quilt matrix.
          final src = getSourceSymbols(1000);
          final nRows = src.primary;
          final nCols = src.secondary;
          final symbolSize = result.quilt.length ~/ (nRows * nCols);
          final columnSize = symbolSize * nRows;

          // A "secondary sliver" is the bytes from column `index`.
          final sliver = Uint8List(columnSize);
          for (var row = 0; row < nRows; row++) {
            final rowOffset = row * (symbolSize * nCols);
            final colOffset = index * symbolSize;
            for (var s = 0; s < symbolSize; s++) {
              sliver[row * symbolSize + s] =
                  result.quilt[rowOffset + colOffset + s];
            }
          }
          return sliver;
        },
      );
    }

    test('reads index from quilt with single file', () async {
      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(
            contents: utf8.encode('Hello, Walrus!'),
            identifier: 'hello.txt',
          ),
        ],
        numShards: 1000,
      );

      final blobReader = createQuiltBlobReader(quiltResult);
      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      expect(index, hasLength(1));
      expect(index[0].identifier, 'hello.txt');
      expect(index[0].patchId, isNotEmpty);
      expect(index[0].tags, isEmpty);
    });

    test('reads index from quilt with multiple files', () async {
      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(
            contents: utf8.encode('Content A'),
            identifier: 'alpha.txt',
          ),
          QuiltBlob(
            contents: utf8.encode('Content B'),
            identifier: 'beta.txt',
          ),
          QuiltBlob(
            contents: utf8.encode('Content C'),
            identifier: 'charlie.txt',
          ),
        ],
        numShards: 1000,
      );

      final blobReader = createQuiltBlobReader(quiltResult);
      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      expect(index, hasLength(3));
      // Sorted by identifier: alpha.txt, beta.txt, charlie.txt
      expect(index[0].identifier, 'alpha.txt');
      expect(index[1].identifier, 'beta.txt');
      expect(index[2].identifier, 'charlie.txt');
    });

    test('reads blob content from quilt via full blob', () async {
      final testContent = 'Hello from quilt!';
      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(
            contents: utf8.encode(testContent),
            identifier: 'greet.txt',
          ),
        ],
        numShards: 1000,
      );

      final blobReader = createQuiltBlobReader(quiltResult);
      // Force full blob loading path.
      await blobReader.getBytes();

      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      final file = WalrusFile(reader: index[0].reader);
      final text = await file.text();

      expect(text, testContent);
    });

    test('reads files with tags', () async {
      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(
            contents: utf8.encode('Tagged!'),
            identifier: 'tagged.txt',
            tags: {'content-type': 'text/plain', 'author': 'test'},
          ),
        ],
        numShards: 1000,
      );

      final blobReader = createQuiltBlobReader(quiltResult);
      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      expect(index[0].tags, {'content-type': 'text/plain', 'author': 'test'});

      final file = WalrusFile(reader: index[0].reader);
      final fileTags = await file.getTags();
      expect(fileTags, {'content-type': 'text/plain', 'author': 'test'});
    });

    test('getBlobHeader caches results', () async {
      var readCount = 0;

      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(
            contents: utf8.encode('Cache test'),
            identifier: 'cache.txt',
          ),
        ],
        numShards: 1000,
      );

      final blobReader = BlobReader(
        blobId: _makeBlobId(99),
        numShards: 1000,
        readBlob: (blobId) async {
          readCount++;
          return quiltResult.quilt;
        },
        readSecondarySliver: (blobId, index) async {
          throw UnimplementedError('Not needed for full blob path');
        },
      );

      // Force full blob loading.
      await blobReader.getBytes();

      final quiltReader = blobReader.getQuiltReader();
      await quiltReader.readIndex();

      // Read header twice — should only trigger one blob read.
      final sliverIndex = quiltResult.index.patches[0].startIndex;
      await quiltReader.getBlobHeader(sliverIndex);
      await quiltReader.getBlobHeader(sliverIndex);

      // Only 1 blob read should have happened (both getBytes and reads reuse cache).
      expect(readCount, 1);
    });

    test('readerForPatchId throws for wrong quilt', () {
      final blobReader = BlobReader(
        blobId: _makeBlobId(1),
        numShards: 1000,
        readBlob: (blobId) async => Uint8List(0),
        readSecondarySliver: (blobId, index) async => Uint8List(0),
      );

      final quiltReader = QuiltReader(blob: blobReader);

      // Create a patch ID for a different quilt.
      final otherQuiltBlobId = blobIdToUrlSafeBase64(Uint8List(32));
      final patchId = encodeQuiltPatchId(
        quiltBlobId: otherQuiltBlobId,
        version: 1,
        startIndex: 0,
        endIndex: 5,
      );

      expect(
        () => quiltReader.readerForPatchId(patchId),
        throwsArgumentError,
      );
    });
  });

  group('QuiltFileReader - lazy loading', () {
    test('getIdentifier returns pre-set identifier', () async {
      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(
            contents: utf8.encode('Test'),
            identifier: 'test.txt',
          ),
        ],
        numShards: 1000,
      );

      // Create reader with full blob path.
      final blobReader = BlobReader(
        blobId: _makeBlobId(55),
        numShards: 1000,
        readBlob: (blobId) async => quiltResult.quilt,
        readSecondarySliver: (blobId, index) async =>
            throw UnimplementedError(),
      );
      await blobReader.getBytes();

      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      // Reader already has the identifier from the index.
      final identifier = await index[0].reader.getIdentifier();
      expect(identifier, 'test.txt');
    });
  });

  group('Multiple files round-trip', () {
    test('encode and read back multiple files preserve content', () async {
      final files = {
        'readme.md': '# Walrus SDK\nA great SDK.',
        'config.json': '{"version": 1, "debug": false}',
        'data.csv': 'name,age\nAlice,30\nBob,25\nCharlie,35',
      };

      final blobs = files.entries
          .map(
            (e) => QuiltBlob(
              contents: utf8.encode(e.value),
              identifier: e.key,
            ),
          )
          .toList();

      final quiltResult = encodeQuilt(blobs: blobs, numShards: 1000);

      final blobReader = BlobReader(
        blobId: _makeBlobId(77),
        numShards: 1000,
        readBlob: (blobId) async => quiltResult.quilt,
        readSecondarySliver: (blobId, index) async =>
            throw UnimplementedError(),
      );
      await blobReader.getBytes();

      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      expect(index, hasLength(3));

      // Files are sorted alphabetically by identifier.
      final sortedKeys = files.keys.toList()..sort();
      for (var i = 0; i < index.length; i++) {
        expect(index[i].identifier, sortedKeys[i]);

        final file = WalrusFile(reader: index[i].reader);
        final text = await file.text();
        expect(text, files[sortedKeys[i]]);
      }
    });

    test('encode and read back files with tags', () async {
      final blobs = [
        QuiltBlob(
          contents: utf8.encode('Image data here'),
          identifier: 'photo.jpg',
          tags: {'content-type': 'image/jpeg', 'width': '1920', 'height': '1080'},
        ),
        QuiltBlob(
          contents: utf8.encode('Document text'),
          identifier: 'doc.txt',
          tags: {'content-type': 'text/plain'},
        ),
      ];

      final quiltResult = encodeQuilt(blobs: blobs, numShards: 1000);

      final blobReader = BlobReader(
        blobId: _makeBlobId(88),
        numShards: 1000,
        readBlob: (blobId) async => quiltResult.quilt,
        readSecondarySliver: (blobId, index) async =>
            throw UnimplementedError(),
      );
      await blobReader.getBytes();

      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      // Sorted: doc.txt, photo.jpg
      expect(index[0].identifier, 'doc.txt');
      expect(index[0].tags, {'content-type': 'text/plain'});

      expect(index[1].identifier, 'photo.jpg');
      expect(index[1].tags, {
        'content-type': 'image/jpeg',
        'width': '1920',
        'height': '1080',
      });
    });

    test('large content round-trips correctly', () async {
      // Create a moderately large file (50KB).
      final largeContent = List.generate(50000, (i) => i & 0xFF);
      final largeBytes = Uint8List.fromList(largeContent);

      final quiltResult = encodeQuilt(
        blobs: [
          QuiltBlob(contents: largeBytes, identifier: 'large.bin'),
        ],
        numShards: 1000,
      );

      final blobReader = BlobReader(
        blobId: _makeBlobId(111),
        numShards: 1000,
        readBlob: (blobId) async => quiltResult.quilt,
        readSecondarySliver: (blobId, index) async =>
            throw UnimplementedError(),
      );
      await blobReader.getBytes();

      final quiltReader = blobReader.getQuiltReader();
      final index = await quiltReader.readIndex();

      final file = WalrusFile(reader: index[0].reader);
      final readBack = await file.bytes();

      expect(readBack, equals(largeBytes));
    });
  });
}
