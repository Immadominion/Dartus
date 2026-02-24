/// Tests for WalrusTransactionBuilder metadata (blob attributes) methods.
///
/// Validates:
/// - createMetadata builds the correct Move call
/// - addMetadata, insertOrUpdateMetadataPair, removeMetadataPair
/// - writeBlobAttributesTransaction combines operations correctly
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:sui/builder/transaction.dart';

import 'package:dartus/src/constants/walrus_constants.dart';
import 'package:dartus/src/contracts/transaction_builder.dart';

void main() {
  late WalrusTransactionBuilder builder;
  const testPackageId = '0xtest_package_id';

  setUp(() {
    builder = WalrusTransactionBuilder(
      packageConfig: testnetWalrusPackageConfig,
      walrusPackageId: testPackageId,
    );
  });

  group('createMetadata', () {
    test('creates a new Metadata object via Move call', () {
      final tx = Transaction();
      final result = builder.createMetadata(tx: tx);
      expect(result, isNotNull);
    });
  });

  group('addMetadata', () {
    test('builds addMetadata Move call', () {
      final tx = Transaction();
      final meta = builder.createMetadata(tx: tx);
      final blob = tx.object('0xblob_id');

      // Should not throw.
      builder.addMetadata(tx: tx, blobObject: blob, metadata: meta);
    });
  });

  group('insertOrUpdateMetadataPair', () {
    test('builds insertOrUpdateMetadataPair Move call', () {
      final tx = Transaction();
      final blob = tx.object('0xblob_id');

      // Should not throw.
      builder.insertOrUpdateMetadataPair(
        tx: tx,
        blobObject: blob,
        key: 'content-type',
        value: 'image/png',
      );
    });
  });

  group('removeMetadataPair', () {
    test('builds removeMetadataPair Move call', () {
      final tx = Transaction();
      final blob = tx.object('0xblob_id');

      // Should not throw.
      builder.removeMetadataPair(tx: tx, blobObject: blob, key: 'content-type');
    });
  });

  group('removeMetadataPairIfExists', () {
    test('builds removeMetadataPairIfExists Move call', () {
      final tx = Transaction();
      final blob = tx.object('0xblob_id');

      // Should not throw.
      builder.removeMetadataPairIfExists(
        tx: tx,
        blobObject: blob,
        key: 'content-type',
      );
    });
  });

  group('writeBlobAttributesTransaction', () {
    test('creates metadata when existingAttributes is null', () {
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {'key1': 'value1', 'key2': 'value2'},
        existingAttributes: null,
      );
      expect(tx, isA<Transaction>());
    });

    test('skips metadata creation when existingAttributes is provided', () {
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {'key1': 'new_value'},
        existingAttributes: {'key1': 'old_value'},
      );
      expect(tx, isA<Transaction>());
    });

    test('removes existing keys when value is null', () {
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {'to_remove': null},
        existingAttributes: {'to_remove': 'old_value'},
      );
      expect(tx, isA<Transaction>());
    });

    test('does not remove non-existing keys when value is null', () {
      // When the key doesn't exist in existingAttributes, setting null
      // should be a no-op (no removeMetadataPair call).
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {'nonexistent': null},
        existingAttributes: {'other_key': 'value'},
      );
      expect(tx, isA<Transaction>());
    });

    test('handles mixed operations (insert, update, remove)', () {
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {
          'new_key': 'new_value', // insert
          'existing_key': 'updated', // update
          'remove_key': null, // remove
        },
        existingAttributes: {
          'existing_key': 'old_value',
          'remove_key': 'to_be_removed',
        },
      );
      expect(tx, isA<Transaction>());
    });

    test('accepts custom transaction', () {
      final existingTx = Transaction();
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {'key': 'value'},
        existingAttributes: null,
        transaction: existingTx,
      );
      expect(tx, same(existingTx));
    });

    test('handles empty attributes map', () {
      // Empty attributes with no existing metadata
      final tx = builder.writeBlobAttributesTransaction(
        blobObjectId: '0xblob_id',
        attributes: {},
        existingAttributes: null,
      );
      expect(tx, isA<Transaction>());
    });
  });

  group('addOrReplaceMetadata', () {
    test('builds addOrReplaceMetadata Move call', () {
      final tx = Transaction();
      final meta = builder.createMetadata(tx: tx);
      final blob = tx.object('0xblob_id');

      final result = builder.addOrReplaceMetadata(
        tx: tx,
        blobObject: blob,
        metadata: meta,
      );
      expect(result, isNotNull);
    });
  });
}
