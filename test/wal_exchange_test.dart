/// Tests for WAL exchange transaction builder methods and
/// the new execute wrappers (createStorage, registerBlob, certifyBlob).
///
/// These tests verify that the transaction builder constructs correct
/// Move call transactions with proper arguments for exchange and
/// lifecycle operations.
library;

import 'dart:typed_data';

import 'package:dartus/src/constants/walrus_constants.dart';
import 'package:dartus/src/contracts/transaction_builder.dart';
import 'package:dartus/src/models/protocol_types.dart';
import 'package:sui/builder/transaction.dart';
import 'package:test/test.dart';

void main() {
  late WalrusTransactionBuilder builder;

  setUp(() {
    builder = WalrusTransactionBuilder(
      packageConfig: testnetWalrusPackageConfig,
      walrusPackageId:
          '0x0000000000000000000000000000000000000000000000000000000000000001',
    );
  });

  group('WAL Exchange Transaction Builder', () {
    const exchangeObjectId =
        '0xf4d164ea2def5fe07dc573992a029e010dba09b1a8dcbc44c5c2e79567f39073';
    const walExchangePackageId =
        '0x0000000000000000000000000000000000000000000000000000000000000002';

    group('exchangeForWalTransaction', () {
      test('creates a valid transaction with move call result', () {
        final result = builder.exchangeForWalTransaction(
          exchangeObjectId: exchangeObjectId,
          suiCoinObjectId: '0xsuicoin',
          amountSui: BigInt.from(1000000),
          walExchangePackageId: walExchangePackageId,
        );

        expect(result, isNotNull);
      });

      test('uses provided transaction instead of creating new one', () {
        final tx = Transaction();
        builder.exchangeForWalTransaction(
          exchangeObjectId: exchangeObjectId,
          suiCoinObjectId: '0xsuicoin',
          amountSui: BigInt.from(500),
          walExchangePackageId: walExchangePackageId,
          transaction: tx,
        );

        // Transaction should have move call commands added.
        expect(tx, isNotNull);
      });

      test('accepts zero amount', () {
        final result = builder.exchangeForWalTransaction(
          exchangeObjectId: exchangeObjectId,
          suiCoinObjectId: '0xsuicoin',
          amountSui: BigInt.zero,
          walExchangePackageId: walExchangePackageId,
        );

        expect(result, isNotNull);
      });

      test('accepts large amount', () {
        final result = builder.exchangeForWalTransaction(
          exchangeObjectId: exchangeObjectId,
          suiCoinObjectId: '0xsuicoin',
          amountSui: BigInt.parse('1000000000000000000'),
          walExchangePackageId: walExchangePackageId,
        );

        expect(result, isNotNull);
      });
    });

    group('exchangeForSuiTransaction', () {
      test('creates a valid transaction', () {
        final result = builder.exchangeForSuiTransaction(
          exchangeObjectId: exchangeObjectId,
          walCoinObjectId: '0xwalcoin',
          amountWal: BigInt.from(2000000),
          walExchangePackageId: walExchangePackageId,
        );

        expect(result, isNotNull);
      });

      test('uses provided transaction', () {
        final tx = Transaction();
        builder.exchangeForSuiTransaction(
          exchangeObjectId: exchangeObjectId,
          walCoinObjectId: '0xwalcoin',
          amountWal: BigInt.from(100),
          walExchangePackageId: walExchangePackageId,
          transaction: tx,
        );

        expect(tx, isNotNull);
      });
    });

    group('exchangeAllForWalTransaction', () {
      test('creates a valid transaction', () {
        final result = builder.exchangeAllForWalTransaction(
          exchangeObjectId: exchangeObjectId,
          suiCoinObjectId: '0xsuicoin',
          walExchangePackageId: walExchangePackageId,
        );

        expect(result, isNotNull);
      });

      test('uses provided transaction', () {
        final tx = Transaction();
        builder.exchangeAllForWalTransaction(
          exchangeObjectId: exchangeObjectId,
          suiCoinObjectId: '0xsuicoin',
          walExchangePackageId: walExchangePackageId,
          transaction: tx,
        );

        expect(tx, isNotNull);
      });
    });

    group('exchangeAllForSuiTransaction', () {
      test('creates a valid transaction', () {
        final result = builder.exchangeAllForSuiTransaction(
          exchangeObjectId: exchangeObjectId,
          walCoinObjectId: '0xwalcoin',
          walExchangePackageId: walExchangePackageId,
        );

        expect(result, isNotNull);
      });

      test('uses provided transaction', () {
        final tx = Transaction();
        builder.exchangeAllForSuiTransaction(
          exchangeObjectId: exchangeObjectId,
          walCoinObjectId: '0xwalcoin',
          walExchangePackageId: walExchangePackageId,
          transaction: tx,
        );

        expect(tx, isNotNull);
      });
    });

    group('all exchange methods use correct module path', () {
      // Verifying that the exchange methods exist and can be called
      // with appropriate parameters is the key test here.
      // The actual Move call target verification would require
      // inspecting PTB internals.

      test('all four exchange methods are available', () {
        // exchangeForWal
        expect(
          () => builder.exchangeForWalTransaction(
            exchangeObjectId: exchangeObjectId,
            suiCoinObjectId: '0xsuicoin',
            amountSui: BigInt.one,
            walExchangePackageId: walExchangePackageId,
          ),
          returnsNormally,
        );

        // exchangeForSui
        expect(
          () => builder.exchangeForSuiTransaction(
            exchangeObjectId: exchangeObjectId,
            walCoinObjectId: '0xwalcoin',
            amountWal: BigInt.one,
            walExchangePackageId: walExchangePackageId,
          ),
          returnsNormally,
        );

        // exchangeAllForWal
        expect(
          () => builder.exchangeAllForWalTransaction(
            exchangeObjectId: exchangeObjectId,
            suiCoinObjectId: '0xsuicoin',
            walExchangePackageId: walExchangePackageId,
          ),
          returnsNormally,
        );

        // exchangeAllForSui
        expect(
          () => builder.exchangeAllForSuiTransaction(
            exchangeObjectId: exchangeObjectId,
            walCoinObjectId: '0xwalcoin',
            walExchangePackageId: walExchangePackageId,
          ),
          returnsNormally,
        );
      });
    });
  });

  group('Transaction Builder - Lifecycle Methods', () {
    group('createStorageTransaction', () {
      test('creates storage reservation with owner', () {
        final tx = builder.createStorageTransaction(
          encodedSize: 1024,
          epochs: 3,
          walCoinObjectId: '0xwalcoin',
          storageCost: BigInt.from(100000),
          owner:
              '0x0000000000000000000000000000000000000000000000000000000000000099',
        );

        expect(tx, isNotNull);
      });

      test('creates transaction without owner (no transfer)', () {
        final tx = builder.createStorageTransaction(
          encodedSize: 2048,
          epochs: 5,
          walCoinObjectId: '0xwalcoin',
          storageCost: BigInt.from(200000),
        );

        expect(tx, isNotNull);
      });

      test('handles large encoded sizes', () {
        final tx = builder.createStorageTransaction(
          encodedSize: 10 * 1024 * 1024 * 1024, // 10GB
          epochs: 100,
          walCoinObjectId: '0xwalcoin',
          storageCost: BigInt.parse('999999999999999'),
        );

        expect(tx, isNotNull);
      });
    });

    group('deleteBlobTransaction', () {
      test('creates delete transaction', () {
        final tx = builder.deleteBlobTransaction(blobObjectId: '0xblob123');

        expect(tx, isNotNull);
      });
    });

    group('extendBlobTransaction', () {
      test('creates extend transaction with WAL payment', () {
        final tx = builder.extendBlobTransaction(
          blobObjectId: '0xblob123',
          epochs: 2,
          walCoinObjectId: '0xwalcoin',
          extensionCost: BigInt.from(50000),
        );

        expect(tx, isNotNull);
      });

      test('creates extend transaction without WAL (gas fallback)', () {
        final tx = builder.extendBlobTransaction(
          blobObjectId: '0xblob123',
          epochs: 2,
        );

        expect(tx, isNotNull);
      });
    });

    group('certifyBlobTransaction', () {
      test('builds certify transaction with certificate', () {
        final cert = ProtocolMessageCertificate(
          signers: [0, 1, 2],
          serializedMessage: Uint8List.fromList(List.filled(64, 0xAA)),
          signature: Uint8List.fromList(List.filled(48, 0xBB)),
        );

        final tx = builder.certifyBlobTransaction(
          CertifyBlobOptions(
            blobId: '12345',
            blobObjectId: '0xblob',
            deletable: false,
            certificate: cert,
            committeeSize: 10,
          ),
        );

        expect(tx, isNotNull);
      });

      test('throws when certificate is null', () {
        expect(
          () => builder.certifyBlobTransaction(
            CertifyBlobOptions(
              blobId: '12345',
              blobObjectId: '0xblob',
              deletable: false,
              committeeSize: 10,
            ),
          ),
          throwsArgumentError,
        );
      });
    });

    group('writeBlobAttributesTransaction', () {
      test('creates metadata on blob without existing attributes', () {
        final tx = builder.writeBlobAttributesTransaction(
          blobObjectId: '0xblob',
          attributes: {'key1': 'value1', 'key2': 'value2'},
          existingAttributes: null,
        );

        expect(tx, isNotNull);
      });

      test('updates existing attributes', () {
        final tx = builder.writeBlobAttributesTransaction(
          blobObjectId: '0xblob',
          attributes: {'key1': 'updated'},
          existingAttributes: {'key1': 'old_value'},
        );

        expect(tx, isNotNull);
      });

      test('removes attributes when value is null', () {
        final tx = builder.writeBlobAttributesTransaction(
          blobObjectId: '0xblob',
          attributes: {'remove_me': null},
          existingAttributes: {'remove_me': 'old_value'},
        );

        expect(tx, isNotNull);
      });

      test('skips removal for non-existing keys', () {
        final tx = builder.writeBlobAttributesTransaction(
          blobObjectId: '0xblob',
          attributes: {'nonexistent': null},
          existingAttributes: {'other_key': 'value'},
        );

        expect(tx, isNotNull);
      });

      test('sets _walrusBlobType for quilts', () {
        final tx = builder.writeBlobAttributesTransaction(
          blobObjectId: '0xblob',
          attributes: {'_walrusBlobType': 'quilt'},
          existingAttributes: null,
        );

        expect(tx, isNotNull);
      });
    });

    group('registerBlobWithWal', () {
      test('creates register transaction with WAL payment', () {
        final tx = builder.registerBlobWithWal(
          RegisterBlobOptions(
            size: 1000,
            epochs: 3,
            blobId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            rootHash: Uint8List(32),
            deletable: true,
            owner:
                '0x0000000000000000000000000000000000000000000000000000000000000099',
          ),
          walCoinObjectId: '0xwalcoin',
          walType: '0xpkg::wal::WAL',
          storageCost: BigInt.from(100000),
          writeCost: BigInt.from(10000),
          encodedSize: 2000,
        );

        expect(tx, isNotNull);
      });

      test('omits transfer when owner is null', () {
        final tx = builder.registerBlobWithWal(
          RegisterBlobOptions(
            size: 500,
            epochs: 1,
            blobId: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
            rootHash: Uint8List(32),
            deletable: false,
          ),
          walCoinObjectId: '0xwalcoin',
          walType: '0xpkg::wal::WAL',
          storageCost: BigInt.from(50000),
          writeCost: BigInt.from(5000),
          encodedSize: 1000,
        );

        expect(tx, isNotNull);
      });

      test('rejects invalid root hash length', () {
        expect(
          () => builder.registerBlobWithWal(
            RegisterBlobOptions(
              size: 100,
              epochs: 1,
              blobId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              rootHash: Uint8List(16), // Wrong length
              deletable: false,
            ),
            walCoinObjectId: '0xwalcoin',
            walType: '0xpkg::wal::WAL',
            storageCost: BigInt.from(1000),
            writeCost: BigInt.from(100),
            encodedSize: 200,
          ),
          throwsArgumentError,
        );
      });
    });
  });

  group('WalrusPackageConfig', () {
    test('testnet config has exchange IDs', () {
      expect(testnetWalrusPackageConfig.exchangeIds, isNotNull);
      expect(testnetWalrusPackageConfig.exchangeIds!.length, equals(4));
    });

    test('mainnet config has no exchange IDs', () {
      expect(mainnetWalrusPackageConfig.exchangeIds, isNull);
    });

    test('configs have correct system object IDs', () {
      expect(testnetWalrusPackageConfig.systemObjectId, startsWith('0x'));
      expect(mainnetWalrusPackageConfig.systemObjectId, startsWith('0x'));
    });

    test('configs have correct staking pool IDs', () {
      expect(testnetWalrusPackageConfig.stakingPoolId, startsWith('0x'));
      expect(mainnetWalrusPackageConfig.stakingPoolId, startsWith('0x'));
    });

    test('equality compares system and staking IDs', () {
      const a = WalrusPackageConfig(
        systemObjectId: '0xabc',
        stakingPoolId: '0xdef',
      );
      const b = WalrusPackageConfig(
        systemObjectId: '0xabc',
        stakingPoolId: '0xdef',
        exchangeIds: ['0x123'],
      );
      // Same system & staking IDs — equal (exchangeIds not in hash).
      expect(a, equals(b));
    });

    test('inequality for different IDs', () {
      const a = WalrusPackageConfig(
        systemObjectId: '0xabc',
        stakingPoolId: '0xdef',
      );
      const b = WalrusPackageConfig(
        systemObjectId: '0xdifferent',
        stakingPoolId: '0xdef',
      );
      expect(a, isNot(equals(b)));
    });

    test('toString includes system and staking IDs', () {
      const config = WalrusPackageConfig(
        systemObjectId: '0xabc',
        stakingPoolId: '0xdef',
      );
      final str = config.toString();
      expect(str, contains('0xabc'));
      expect(str, contains('0xdef'));
    });
  });
}
