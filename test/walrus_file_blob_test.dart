/// Tests for [WalrusFile], [LocalFileReader], and [WalrusBlob].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/src/constants/walrus_constants.dart';
import 'package:dartus/src/files/blob.dart';
import 'package:dartus/src/files/file.dart';
import 'package:dartus/src/models/storage_node_types.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusFile', () {
    test('factory constructor creates from contents', () {
      final data = utf8.encode('Hello, Walrus!');
      final file = WalrusFile.from(
        contents: Uint8List.fromList(data),
        identifier: 'hello.txt',
      );

      expect(file, isA<WalrusFile>());
    });

    test('bytes() returns the file contents', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final file = WalrusFile.from(contents: data, identifier: 'test.bin');

      final bytes = await file.bytes();
      expect(bytes, data);
    });

    test('text() returns UTF-8 decoded string', () async {
      final text = 'Hello, World! 🌍';
      final file = WalrusFile.from(
        contents: Uint8List.fromList(utf8.encode(text)),
        identifier: 'text.txt',
      );

      expect(await file.text(), text);
    });

    test('json() parses JSON content', () async {
      final json = {'key': 'value', 'count': 42};
      final file = WalrusFile.from(
        contents: Uint8List.fromList(utf8.encode(jsonEncode(json))),
        identifier: 'data.json',
      );

      final parsed = await file.json();
      expect(parsed, json);
    });

    test('getIdentifier() returns the identifier', () async {
      final file = WalrusFile.from(
        contents: Uint8List(10),
        identifier: 'test-file.bin',
      );

      expect(await file.getIdentifier(), 'test-file.bin');
    });

    test('getTags() returns tags', () async {
      final file = WalrusFile.from(
        contents: Uint8List(10),
        identifier: 'tagged.bin',
        tags: {'content-type': 'application/octet-stream'},
      );

      expect(await file.getTags(), {
        'content-type': 'application/octet-stream',
      });
    });

    test('getTags() returns empty map when no tags', () async {
      final file = WalrusFile.from(
        contents: Uint8List(10),
        identifier: 'notags.bin',
      );

      expect(await file.getTags(), isEmpty);
    });

    test('unnamed constructor wraps a custom reader', () async {
      final data = utf8.encode('custom reader');
      final file = WalrusFile(
        reader: LocalFileReader(
          contents: Uint8List.fromList(data),
          identifier: 'custom.txt',
        ),
      );

      expect(await file.bytes(), data);
    });
  });

  group('WalrusBlob', () {
    test('asFile() returns a WalrusFile backed by blob data', () async {
      final data = utf8.encode('blob content');
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List.fromList(data),
      );

      final file = blob.asFile();
      expect(file, isA<WalrusFile>());

      final bytes = await file.bytes();
      expect(bytes, data);
    });

    test('exists() returns true for permanent blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => BlobStatusPermanent(endEpoch: 100),
      );

      expect(result, isTrue);
    });

    test('exists() returns true for deletable blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => BlobStatusDeletable(initialCertifiedEpoch: 100),
      );

      expect(result, isTrue);
    });

    test('exists() returns false for nonexistent blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => const BlobStatusNonexistent(),
      );

      expect(result, isFalse);
    });

    test('exists() returns false for invalid blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final result = await blob.exists(
        (blobId) async => const BlobStatusInvalid(),
      );

      expect(result, isFalse);
    });

    test('storedUntil() returns endEpoch for permanent blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final epoch = await blob.storedUntil(
        (blobId) async => BlobStatusPermanent(endEpoch: 42),
      );

      expect(epoch, 42);
    });

    test('storedUntil() returns null for deletable blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final epoch = await blob.storedUntil(
        (blobId) async => BlobStatusDeletable(initialCertifiedEpoch: 99),
      );

      expect(epoch, isNull);
    });

    test('storedUntil() returns null for nonexistent blob', () async {
      final blob = WalrusBlob(
        blobId: 'test-blob-id',
        bytesProvider: () async => Uint8List(0),
      );

      final epoch = await blob.storedUntil(
        (blobId) async => const BlobStatusNonexistent(),
      );

      expect(epoch, isNull);
    });
  });

  group('BlobStatus', () {
    test('type getter returns correct string', () {
      expect(const BlobStatusNonexistent().type, 'nonexistent');
      expect(const BlobStatusInvalid().type, 'invalid');
      expect(BlobStatusPermanent(endEpoch: 1).type, 'permanent');
      expect(BlobStatusDeletable(initialCertifiedEpoch: 1).type, 'deletable');
    });

    test('toJson() works for all subtypes', () {
      expect(const BlobStatusNonexistent().toJson(), {'type': 'nonexistent'});
      expect(const BlobStatusInvalid().toJson(), {'type': 'invalid'});
      expect(BlobStatusPermanent(endEpoch: 5).toJson(), {
        'type': 'permanent',
        'endEpoch': 5,
        'isCertified': false,
      });
      expect(BlobStatusDeletable(initialCertifiedEpoch: 3).toJson(), {
        'type': 'deletable',
        'initialCertifiedEpoch': 3,
      });
    });

    test('toJson() includes initialCertifiedEpoch when present', () {
      expect(
        BlobStatusPermanent(endEpoch: 5, initialCertifiedEpoch: 2).toJson(),
        {
          'type': 'permanent',
          'endEpoch': 5,
          'isCertified': false,
          'initialCertifiedEpoch': 2,
        },
      );
      expect(BlobStatusDeletable(initialCertifiedEpoch: 1).toJson(), {
        'type': 'deletable',
        'initialCertifiedEpoch': 1,
      });
    });
  });

  group('statusLifecycleRank', () {
    test('invalid has the highest rank', () {
      expect(
        statusLifecycleRank['invalid']!,
        greaterThan(statusLifecycleRank['permanent']!),
      );
      expect(
        statusLifecycleRank['permanent']!,
        greaterThan(statusLifecycleRank['deletable']!),
      );
      expect(
        statusLifecycleRank['deletable']!,
        greaterThan(statusLifecycleRank['nonexistent']!),
      );
    });
  });
}
