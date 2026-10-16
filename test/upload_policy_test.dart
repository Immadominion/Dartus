@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/testing.dart';
import 'package:sui/sui.dart';
import 'package:test/test.dart';

void main() {
  test(
    'publisher uploads reject permanent storage before file or HTTP I/O',
    () async {
      var requests = 0;
      final http = MockClient((_) async {
        requests++;
        throw StateError('No request should be sent');
      });
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.invalid'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.invalid'),
        httpClient: http,
      );
      addTearDown(client.close);
      final missing = File('/does-not-exist/dartus-policy-test');
      await expectLater(
        client.putBlob(data: Uint8List(1), deletable: false),
        throwsArgumentError,
      );
      await expectLater(
        client.putBlobFromFile(file: missing, deletable: false),
        throwsArgumentError,
      );
      await expectLater(
        client.putBlobStreaming(file: missing, deletable: false),
        throwsArgumentError,
      );
      expect(requests, 0);
    },
  );

  test('relay rejects permanent storage without sending bytes', () async {
    var requests = 0;
    final relay = UploadRelayClient(
      host: 'https://relay.invalid',
      httpClient: MockClient((_) async {
        requests++;
        throw StateError('No request should be sent');
      }),
    );
    await expectLater(
      relay.writeBlob(
        blobId: 'unused',
        blob: Uint8List(1),
        nonce: Uint8List(32),
        txDigest: 'unused',
        blobObjectId: '0x1',
        deletable: false,
      ),
      throwsArgumentError,
    );
    expect(requests, 0);
  });

  test(
    'registration and certification reject permanent storage before modifying a transaction',
    () {
      final builder = WalrusTransactionBuilder(
        packageConfig: testnetWalrusPackageConfig,
        walrusPackageId: '0x1',
      );
      final options = RegisterBlobOptions(
        size: 1,
        epochs: 1,
        blobId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        rootHash: Uint8List(32),
        deletable: false,
      );
      final tx = Transaction();
      expect(
        () => builder.registerBlobWithWal(
          options,
          walCoinObjectId: '0x2',
          walType: '0x1::wal::WAL',
          storageCost: BigInt.one,
          writeCost: BigInt.one,
          encodedSize: 100,
          transaction: tx,
        ),
        throwsArgumentError,
      );
      expect(
        () => builder.addRegisterBlob(
          tx,
          blobId: options.blobId,
          rootHash: options.rootHash,
          size: 1,
          encodedSize: 100,
          epochs: 1,
          deletable: false,
          walType: '0x1::wal::WAL',
          storageCost: BigInt.one,
          writeCost: BigInt.one,
        ),
        throwsArgumentError,
      );
      expect(
        () => builder.certifyBlobTransaction(
          CertifyBlobOptions(
            blobId: options.blobId,
            blobObjectId: '0x2',
            deletable: false,
            committeeSize: 1,
          ),
          transaction: tx,
        ),
        throwsArgumentError,
      );
      // ignore: deprecated_member_use_from_same_package
      expect(
        () => builder.registerBlobTransaction(options, transaction: tx),
        throwsUnsupportedError,
      );
      expect(tx.getData().commands, isEmpty);
      expect(tx.getData().inputs, isEmpty);
    },
  );
}
