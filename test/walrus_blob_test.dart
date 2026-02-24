/// Tests for [WalrusBlob] — asFile, fromReader, files, exists, storedUntil.
///
/// Exercises both legacy (bytesProvider) and reader-backed (BlobReader)
/// construction modes, including quilt file filtering.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/src/files/blob.dart';
import 'package:dartus/src/files/file.dart';
import 'package:dartus/src/files/readers/blob_reader.dart';
import 'package:dartus/src/models/storage_node_types.dart';
import 'package:dartus/src/utils/encoding_utils.dart';
import 'package:test/test.dart';

/// Generate a valid 32-byte blob ID, URL-safe base64, from a seed.
String _makeBlobId(int seed) {
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (seed + i) % 256;
  }
  return blobIdToUrlSafeBase64(bytes);
}

void main() {
  group('WalrusBlob (legacy constructor)', () {
    test('asFile returns a WalrusFile', () async {
      final data = utf8.encode('Hello, Walrus!');
      final blob = WalrusBlob(
        blobId: _makeBlobId(1),
        bytesProvider: () async => Uint8List.fromList(data),
      );

      final file = blob.asFile();
      expect(file, isA<WalrusFile>());

      final bytes = await file.bytes();
      expect(utf8.decode(bytes), 'Hello, Walrus!');
    });

    test('asFile preserves blob ID as identifier', () async {
      final blobId = _makeBlobId(2);
      final blob = WalrusBlob(
        blobId: blobId,
        bytesProvider: () async => Uint8List(0),
      );

      final file = blob.asFile();
      final identifier = await file.getIdentifier();
      expect(identifier, blobId);
    });

    test('asFile returns empty tags', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(3),
        bytesProvider: () async => Uint8List(0),
      );

      final tags = await blob.asFile().getTags();
      expect(tags, isEmpty);
    });

    test('files() throws StateError without BlobReader', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(4),
        bytesProvider: () async => Uint8List(0),
      );

      expect(() => blob.files(), throwsStateError);
    });

    test('exists with permanent status returns true', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(5),
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => const BlobStatusPermanent(endEpoch: 100),
      );
      expect(result, isTrue);
    });

    test('exists with deletable status returns true', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(6),
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => const BlobStatusDeletable(initialCertifiedEpoch: 50),
      );
      expect(result, isTrue);
    });

    test('exists with nonexistent status returns false', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(7),
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => const BlobStatusNonexistent(),
      );
      expect(result, isFalse);
    });

    test('exists with invalid status returns false', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(8),
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => const BlobStatusInvalid(),
      );
      expect(result, isFalse);
    });

    test('exists without callback or client throws StateError', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(9),
        bytesProvider: () async => Uint8List(0),
      );

      expect(() => blob.exists(), throwsStateError);
    });

    test('storedUntil returns endEpoch for permanent', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(10),
        bytesProvider: () async => Uint8List(0),
      );

      final epoch = await blob.storedUntil(
        (blobId) async => const BlobStatusPermanent(endEpoch: 200),
      );
      expect(epoch, 200);
    });

    test('storedUntil returns null for deletable', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(11),
        bytesProvider: () async => Uint8List(0),
      );

      final epoch = await blob.storedUntil(
        (blobId) async => const BlobStatusDeletable(initialCertifiedEpoch: 300),
      );
      expect(epoch, isNull);
    });

    test('storedUntil returns null for nonexistent', () async {
      final blob = WalrusBlob(
        blobId: _makeBlobId(12),
        bytesProvider: () async => Uint8List(0),
      );

      final epoch = await blob.storedUntil(
        (blobId) async => const BlobStatusNonexistent(),
      );
      expect(epoch, isNull);
    });

    test('caches status across exists and storedUntil calls', () async {
      var callCount = 0;
      final blob = WalrusBlob(
        blobId: _makeBlobId(13),
        bytesProvider: () async => Uint8List(0),
      );

      Future<BlobStatus> getStatus(String id) async {
        callCount++;
        return const BlobStatusPermanent(endEpoch: 999);
      }

      await blob.exists(getStatus);
      await blob.storedUntil(getStatus);

      // Should have been called only once due to caching.
      expect(callCount, 1);
    });
  });

  group('WalrusBlob.fromReader', () {
    test('blobId comes from reader', () {
      final blobId = _makeBlobId(20);
      final reader = BlobReader(
        blobId: blobId,
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      final blob = WalrusBlob.fromReader(reader: reader);
      expect(blob.blobId, blobId);
    });

    test('asFile returns a WalrusFile backed by BlobReader', () async {
      final data = utf8.encode('Reader data');
      final blobId = _makeBlobId(21);
      final reader = BlobReader(
        blobId: blobId,
        numShards: 100,
        readBlob: (id) async => Uint8List.fromList(data),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      final blob = WalrusBlob.fromReader(reader: reader);
      final file = blob.asFile();
      final bytes = await file.bytes();
      expect(utf8.decode(bytes), 'Reader data');
    });

    test('exists works with explicit callback', () async {
      final reader = BlobReader(
        blobId: _makeBlobId(22),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      final blob = WalrusBlob.fromReader(reader: reader);
      final result = await blob.exists(
        (blobId) async => const BlobStatusPermanent(endEpoch: 42),
      );
      expect(result, isTrue);
    });
  });

  group('BlobFileReader', () {
    test('getIdentifier returns blob ID', () async {
      final blobId = _makeBlobId(30);
      final reader = BlobFileReader(
        blobId: blobId,
        bytesProvider: () async => Uint8List(0),
      );

      expect(await reader.getIdentifier(), blobId);
    });

    test('getTags returns empty map', () async {
      final reader = BlobFileReader(
        blobId: _makeBlobId(31),
        bytesProvider: () async => Uint8List(0),
      );

      final tags = await reader.getTags();
      expect(tags, isEmpty);
    });

    test('getBytes returns provider data', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final reader = BlobFileReader(
        blobId: _makeBlobId(32),
        bytesProvider: () async => data,
      );

      expect(await reader.getBytes(), equals(data));
    });
  });

  group('WalrusBlobFilesFilter', () {
    test('default constructor has all null filters', () {
      const filter = WalrusBlobFilesFilter();
      expect(filter.ids, isNull);
      expect(filter.tags, isNull);
      expect(filter.identifiers, isNull);
    });

    test('accepts ids filter', () {
      final filter = WalrusBlobFilesFilter(ids: ['abc', 'def']);
      expect(filter.ids, hasLength(2));
    });

    test('accepts tags filter', () {
      final filter = WalrusBlobFilesFilter(
        tags: [
          {'type': 'image'},
        ],
      );
      expect(filter.tags, hasLength(1));
    });

    test('accepts identifiers filter', () {
      final filter = WalrusBlobFilesFilter(
        identifiers: ['file1.txt', 'file2.txt'],
      );
      expect(filter.identifiers, hasLength(2));
    });
  });

  group('BlobReader', () {
    test('getBytes delegates to readBlob callback', () async {
      var called = false;
      final data = Uint8List.fromList([99, 98, 97]);
      final reader = BlobReader(
        blobId: _makeBlobId(40),
        numShards: 100,
        readBlob: (id) async {
          called = true;
          return data;
        },
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      final bytes = await reader.getBytes();
      expect(called, isTrue);
      expect(bytes, equals(data));
    });

    test('caches getBytes result', () async {
      var callCount = 0;
      final reader = BlobReader(
        blobId: _makeBlobId(41),
        numShards: 100,
        readBlob: (id) async {
          callCount++;
          return Uint8List.fromList([1, 2, 3]);
        },
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      await reader.getBytes();
      await reader.getBytes();
      expect(callCount, 1);
    });

    test('getSecondarySliver delegates and caches', () async {
      var callCount = 0;
      final reader = BlobReader(
        blobId: _makeBlobId(42),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async {
          callCount++;
          return Uint8List.fromList([index]);
        },
      );

      final s1 = await reader.getSecondarySliver(sliverIndex: 5);
      final s2 = await reader.getSecondarySliver(sliverIndex: 5);
      expect(s1, equals([5]));
      expect(s2, equals([5]));
      expect(callCount, 1, reason: 'Second call should use cache');

      final s3 = await reader.getSecondarySliver(sliverIndex: 10);
      expect(s3, equals([10]));
      expect(callCount, 2);
    });

    test('getQuiltReader returns a QuiltReader', () {
      final reader = BlobReader(
        blobId: _makeBlobId(43),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      final qr = reader.getQuiltReader();
      expect(qr, isNotNull);
    });

    test('getIdentifier returns null', () async {
      final reader = BlobReader(
        blobId: _makeBlobId(44),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      expect(await reader.getIdentifier(), isNull);
    });

    test('getTags returns empty map', () async {
      final reader = BlobReader(
        blobId: _makeBlobId(45),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      expect(await reader.getTags(), isEmpty);
    });

    test('hasStartedLoadingFullBlob is false initially', () {
      final reader = BlobReader(
        blobId: _makeBlobId(46),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      expect(reader.hasStartedLoadingFullBlob, isFalse);
    });

    test('hasStartedLoadingFullBlob becomes true after getBytes', () async {
      final reader = BlobReader(
        blobId: _makeBlobId(47),
        numShards: 100,
        readBlob: (id) async => Uint8List(0),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      await reader.getBytes();
      expect(reader.hasStartedLoadingFullBlob, isTrue);
    });

    test('failed getBytes resets hasStartedLoadingFullBlob', () async {
      final reader = BlobReader(
        blobId: _makeBlobId(48),
        numShards: 100,
        readBlob: (id) async => throw Exception('Network error'),
        readSecondarySliver: (id, index) async => Uint8List(0),
      );

      try {
        await reader.getBytes();
      } catch (_) {
        // Expected.
      }

      expect(reader.hasStartedLoadingFullBlob, isFalse);
    });
  });
}
