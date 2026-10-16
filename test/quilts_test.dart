/// Tests for Quilts encoding [quilts.dart].
///
/// Verifies quilt structure, symbol size computation, and
/// round-trip consistency of the encoding.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartus/src/utils/encoding_utils.dart';
import 'package:dartus/src/utils/quilts.dart';
import 'package:test/test.dart';

void main() {
  _referenceQuiltVectors();

  group('computeSymbolSize', () {
    test('returns a valid symbol size for simple inputs', () {
      final result = computeSymbolSize(
        blobSizes: [100, 200, 300],
        nColumns: 667,
        nRows: 334,
        maxNumColumnsForQuiltIndex: kMaxNumSliversForQuiltIndex,
      );

      // Must be a positive even number (RS2 alignment = 2).
      expect(result, greaterThan(0));
      expect(result % 2, 0, reason: 'Must be aligned to 2 for RS2');
    });

    test('throws for empty blobs', () {
      expect(
        () => computeSymbolSize(
          blobSizes: [],
          nColumns: 667,
          nRows: 334,
          maxNumColumnsForQuiltIndex: 10,
        ),
        throwsArgumentError,
      );
    });

    test('throws when too many blobs', () {
      final sizes = List.filled(1000, 100);
      expect(
        () => computeSymbolSize(
          blobSizes: sizes,
          nColumns: 10,
          nRows: 5,
          maxNumColumnsForQuiltIndex: 10,
        ),
        throwsArgumentError,
      );
    });

    test('handles single blob', () {
      final result = computeSymbolSize(
        blobSizes: [1000],
        nColumns: 100,
        nRows: 50,
        maxNumColumnsForQuiltIndex: 10,
      );
      expect(result, greaterThan(0));
    });
  });

  group('encodeQuilt', () {
    test('encodes a single file', () {
      final blob = QuiltBlob(
        contents: utf8.encode('Hello, Walrus!'),
        identifier: 'hello.txt',
      );

      final result = encodeQuilt(blobs: [blob], numShards: 1000);

      expect(result.quilt, isNotEmpty);
      expect(result.index.patches, hasLength(1));
      expect(result.index.patches[0].identifier, 'hello.txt');
      expect(result.index.patches[0].startIndex, greaterThan(0));
      expect(
        result.index.patches[0].endIndex,
        greaterThanOrEqualTo(result.index.patches[0].startIndex),
      );
    });

    test('encodes multiple files', () {
      final blobs = [
        QuiltBlob(
          contents: utf8.encode('File one contents'),
          identifier: 'one.txt',
        ),
        QuiltBlob(
          contents: utf8.encode('File two contents — longer data'),
          identifier: 'two.txt',
        ),
        QuiltBlob(contents: utf8.encode('Three'), identifier: 'three.txt'),
      ];

      final result = encodeQuilt(blobs: blobs, numShards: 1000);

      expect(result.quilt, isNotEmpty);
      // Sorted by identifier: one.txt, three.txt, two.txt
      expect(result.index.patches, hasLength(3));
      expect(result.index.patches[0].identifier, 'one.txt');
      expect(result.index.patches[1].identifier, 'three.txt');
      expect(result.index.patches[2].identifier, 'two.txt');

      // Patches should not overlap.
      for (var i = 1; i < result.index.patches.length; i++) {
        expect(
          result.index.patches[i].startIndex,
          greaterThanOrEqualTo(result.index.patches[i - 1].endIndex),
          reason: 'Patch $i overlaps with patch ${i - 1}',
        );
      }
    });

    test('throws for empty blobs list', () {
      expect(
        () => encodeQuilt(blobs: [], numShards: 1000),
        throwsArgumentError,
      );
    });

    test('throws for duplicate identifiers', () {
      final blobs = [
        QuiltBlob(contents: Uint8List(10), identifier: 'same.txt'),
        QuiltBlob(contents: Uint8List(20), identifier: 'same.txt'),
      ];

      expect(
        () => encodeQuilt(blobs: blobs, numShards: 1000),
        throwsArgumentError,
      );
    });

    test('encodes blobs with tags', () {
      final blob = QuiltBlob(
        contents: utf8.encode('Tagged content'),
        identifier: 'tagged.txt',
        tags: {'content-type': 'text/plain', 'author': 'test'},
      );

      final result = encodeQuilt(blobs: [blob], numShards: 1000);

      expect(result.index.patches[0].tags, {
        'content-type': 'text/plain',
        'author': 'test',
      });
    });

    test('quilt size is correct for encoding matrix', () {
      final blobs = [
        QuiltBlob(contents: Uint8List(500), identifier: 'a.bin'),
        QuiltBlob(contents: Uint8List(1000), identifier: 'b.bin'),
      ];

      final result = encodeQuilt(blobs: blobs, numShards: 1000);

      final src = getSourceSymbols(1000);
      final nRows = src.primary;
      final nCols = src.secondary;

      // Quilt should be exactly nRows * rowSize bytes.
      // rowSize = symbolSize * nCols
      // totalSize = nRows * nCols * symbolSize
      expect(result.quilt.length % (nRows * nCols), 0);
    });
  });

  group('encodeQuiltPatchId', () {
    test('produces a non-empty URL-safe base64 string', () {
      final id = encodeQuiltPatchId(
        quiltBlobId: blobIdToUrlSafeBase64(Uint8List(32)),
        version: 1,
        startIndex: 5,
        endIndex: 10,
      );

      expect(id, isNotEmpty);
      expect(id.contains('+'), isFalse);
      expect(id.contains('/'), isFalse);
    });

    test('different ranges produce different IDs', () {
      final blobId = blobIdToUrlSafeBase64(Uint8List(32));
      final id1 = encodeQuiltPatchId(
        quiltBlobId: blobId,
        version: 1,
        startIndex: 0,
        endIndex: 5,
      );
      final id2 = encodeQuiltPatchId(
        quiltBlobId: blobId,
        version: 1,
        startIndex: 5,
        endIndex: 10,
      );
      expect(id1, isNot(equals(id2)));
    });
  });
}

/// Quilts produced by `@mysten/walrus` 1.2.35's `encodeQuilt` (1000 shards).
/// Aggregators parse quilts with the Rust implementation; byte-identical
/// output to the TS SDK keeps every patch readable.
void _referenceQuiltVectors() {
  final text = utf8.encode;
  final cases = {
    'three files, tags and an empty file': (
      [
        QuiltBlob(
          identifier: 'notes.txt',
          contents: Uint8List.fromList(text('Notes for the quilt test')),
        ),
        QuiltBlob(
          identifier: 'photo.bin',
          contents: Uint8List.fromList(List.generate(3000, (i) => i % 251)),
          tags: const {'type': 'image/jpeg', 'b': 'second'},
        ),
        QuiltBlob(identifier: 'empty.txt', contents: Uint8List(0)),
      ],
      'd4f8d0cb3e67cb7b48c4e626796ca79a106bf8b0789f93e9da1e850376b9e162',
      [('empty.txt', 1, 2), ('notes.txt', 2, 3), ('photo.bin', 3, 8)],
    ),
    'a non-ASCII identifier and a 100 kB file': (
      [
        QuiltBlob(
          identifier: 'Ọlá Adébáyọ̀.txt',
          contents: Uint8List.fromList(text('Yoruba name')),
        ),
        QuiltBlob(
          identifier: 'a',
          contents: Uint8List(100000)..fillRange(0, 100000, 7),
        ),
      ],
      '5b50d9d5ad730eacdb47fb7204db443a766b67a873bce39cd52322e7a4d16c1a',
      [('a', 1, 151), ('Ọlá Adébáyọ̀.txt', 151, 152)],
    ),
  };

  group('matches the TS SDK byte for byte', () {
    for (final MapEntry(key: name, value: (blobs, sha, patches))
        in cases.entries) {
      test(name, () {
        final result = encodeQuilt(blobs: blobs, numShards: 1000);
        expect(result.quilt.length, 445556);
        expect(sha256.convert(result.quilt).toString(), sha);
        expect([
          for (final p in result.index.patches)
            (p.identifier, p.startIndex, p.endIndex),
        ], patches);
      });
    }
  });
}
