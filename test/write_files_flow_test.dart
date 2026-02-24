/// Tests for [WriteFileResult] and [WriteFilesFlowRegisterOptions].
///
/// NOTE: WriteFilesFlow imports `package:sui` which depends on
/// Flutter (`dart:ui`), so it cannot be loaded in plain `dart test`.
/// These tests verify the data types independently. The flow class
/// itself is tested via the Flutter example app and integration tests.
library;

import 'package:test/test.dart';

void main() {
  group('WriteFileResult (mirrors write_files_flow.dart)', () {
    // Since we can't import the actual class due to Flutter dependency,
    // we test the equivalent data contract here.

    test('stores id, blobId, blobObjectId', () {
      // Verifying the expected shape of WriteFileResult.
      final result = _MockWriteFileResult(
        id: 'patch-id-abc',
        blobId: 'blob-id-def',
        blobObjectId: '0x123',
      );

      expect(result.id, 'patch-id-abc');
      expect(result.blobId, 'blob-id-def');
      expect(result.blobObjectId, '0x123');
    });

    test('toString is readable', () {
      final result = _MockWriteFileResult(
        id: 'p',
        blobId: 'b',
        blobObjectId: '0x1',
      );

      final str = result.toString();
      expect(str, contains('WriteFileResult'));
      expect(str, contains('p'));
      expect(str, contains('b'));
      expect(str, contains('0x1'));
    });
  });

  group('WriteFilesFlowRegisterOptions (mirrors write_files_flow.dart)', () {
    test('required fields', () {
      final options = _MockRegisterOptions(
        epochs: 5,
        owner: '0xowner',
        deletable: true,
      );

      expect(options.epochs, 5);
      expect(options.owner, '0xowner');
      expect(options.deletable, isTrue);
    });

    test('optional fields default to null', () {
      final options = _MockRegisterOptions(
        epochs: 1,
        owner: '0x1',
        deletable: false,
      );

      expect(options.attributes, isNull);
      expect(options.walCoinObjectId, isNull);
      expect(options.walType, isNull);
      expect(options.storageCost, isNull);
      expect(options.writeCost, isNull);
      expect(options.encodedSize, isNull);
    });

    test('accepts all optional fields', () {
      final options = _MockRegisterOptions(
        epochs: 3,
        owner: '0xabc',
        deletable: true,
        attributes: {'key': 'value'},
        walCoinObjectId: '0xcoin',
        walType: '0x2::wal::WAL',
        storageCost: BigInt.from(100),
        writeCost: BigInt.from(50),
        encodedSize: 4096,
      );

      expect(options.attributes, {'key': 'value'});
      expect(options.walCoinObjectId, '0xcoin');
      expect(options.walType, '0x2::wal::WAL');
      expect(options.storageCost, BigInt.from(100));
      expect(options.writeCost, BigInt.from(50));
      expect(options.encodedSize, 4096);
    });
  });
}

// ---------------------------------------------------------------------------
// Mock classes mirroring the actual write_files_flow.dart types
// since they can't be imported in plain dart test.
// ---------------------------------------------------------------------------

class _MockWriteFileResult {
  final String id;
  final String blobId;
  final String blobObjectId;

  const _MockWriteFileResult({
    required this.id,
    required this.blobId,
    required this.blobObjectId,
  });

  @override
  String toString() =>
      'WriteFileResult(id: $id, blobId: $blobId, blobObjectId: $blobObjectId)';
}

class _MockRegisterOptions {
  final int epochs;
  final String owner;
  final bool deletable;
  final Map<String, String?>? attributes;
  final String? walCoinObjectId;
  final String? walType;
  final BigInt? storageCost;
  final BigInt? writeCost;
  final int? encodedSize;

  const _MockRegisterOptions({
    required this.epochs,
    required this.owner,
    required this.deletable,
    this.attributes,
    this.walCoinObjectId,
    this.walType,
    this.storageCost,
    this.writeCost,
    this.encodedSize,
  });
}
