import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/src/client/walrus_direct_client.dart';
import 'package:dartus/src/client/write_blob_flow.dart';
import 'package:dartus/src/client/write_files_flow.dart';
import 'package:dartus/src/constants/walrus_constants.dart';
import 'package:dartus/src/contracts/transaction_builder.dart';
import 'package:dartus/src/encoding/blob_encoder.dart';
import 'package:dartus/src/errors/walrus_errors.dart';
import 'package:dartus/src/files/file.dart';
import 'package:dartus/src/models/protocol_types.dart';
import 'package:dartus/src/upload_relay/upload_relay_client.dart';
import 'package:sui/sui.dart';
import 'package:test/test.dart';

const _owner = '0xabc';
const _walType = '0x123::wal::WAL';

CoinStruct _coin(String id, int balance) =>
    CoinStruct(_walType, id, 1, 'digest', '$balance', 'previous');

class _PagedSuiClient extends SuiClient {
  final Map<String?, PaginatedCoins> pages;
  final List<String?> cursors = [];
  Transaction? submittedTransaction;
  int systemReads = 0;

  _PagedSuiClient(this.pages) : super('http://127.0.0.1:1');

  @override
  Future<SuiObjectResponse> getObject(
    String objectId, {
    SuiObjectDataOptions? options,
  }) async {
    expect(objectId, WalrusNetwork.testnet.packageConfig.systemObjectId);
    systemReads++;
    // Registration resolves the network's Blob type before constructing a
    // payment. Keep that real lookup path while returning a local fixture.
    return SuiObjectResponse.fromJson({
      'data': {
        'objectId': objectId,
        'version': '1',
        'digest': 'system-fixture',
        'type': '0x123::system::System',
        'content': {
          'dataType': 'moveObject',
          'type': '0x123::system::System',
          'hasPublicTransfer': false,
          'fields': {'version': '1', 'package_id': '0x123'},
        },
      },
    });
  }

  @override
  Future<PaginatedCoins> getCoins(
    String owner, {
    String? coinType,
    String? cursor,
    int? limit,
  }) async {
    expect(owner, _owner);
    expect(coinType, _walType);
    cursors.add(cursor);
    if (cursors.length > pages.length + 1) {
      fail('Pagination loop did not terminate');
    }
    final page = pages[cursor];
    if (page == null) fail('Unexpected cursor: $cursor');
    return page;
  }

  @override
  Future<SuiTransactionBlockResponse> signAndExecuteTransactionBlock(
    SuiAccount signer,
    Transaction transaction, {
    BuildOptions? options,
    SuiTransactionBlockResponseOptions? responseOptions,
    ExecuteTransaction requestType = ExecuteTransaction.WaitForEffectsCert,
  }) async {
    // Deliberately neither build nor sign nor submit: inspect the commands only.
    submittedTransaction = transaction;
    return SuiTransactionBlockResponse.fromJson({
      'digest': 'mock-digest',
      'effects': {
        'status': {'status': 'success'},
        'transactionDigest': 'mock-digest',
        'gasUsed': {
          'computationCost': '0',
          'storageCost': '0',
          'storageRebate': '0',
          'nonRefundableStorageFee': '0',
        },
        'gasObject': {
          'owner': {'AddressOwner': _owner},
          'reference': {
            'objectId': '0x10',
            'version': '1',
            'digest': 'gas-fixture',
          },
        },
      },
    });
  }
}

class _DirectClient extends WalrusDirectClient {
  _DirectClient(SuiClient client)
    : super(network: WalrusNetwork.testnet, suiClient: client);

  @override
  Future<String> getWalType() async => _walType;
}

// Accessing any signer member fails: the regression never uses a private key.
class _UnusedSigner implements SuiAccount {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('This test must not sign');
}

// These registration-only tests use the relay path: metadata is sufficient
// there, whereas direct mode correctly requires fully encoded slivers.
// Accessing the relay fails, so no upload or other network operation is hidden.
class _UnusedRelay implements UploadRelayClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('This test must not contact an upload relay');
}

BlobMetadata _metadata(int length) => BlobMetadata(
  blobId: base64UrlEncode(Uint8List(32)).replaceAll('=', ''),
  rootHash: Uint8List(32),
  unencodedLength: length,
  encodingType: 1,
  nonce: Uint8List(32),
  blobDigest: Uint8List(32),
);

class _FixtureEncoder implements BlobEncoder {
  @override
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards) async =>
      _metadata(data.length);
}

WalrusTransactionBuilder _builder() => WalrusTransactionBuilder(
  packageConfig: WalrusNetwork.testnet.packageConfig,
  walrusPackageId: '0x123',
);

_PagedSuiClient _twoPages() => _PagedSuiClient({
  null: PaginatedCoins([_coin('0x1', 2)], 'second', true),
  'second': PaginatedCoins([_coin('0x2', 10)], null, false),
});

Set<String> _objectInputs(Transaction tx) => tx
    .getData()
    .inputs!
    .where((input) => input['UnresolvedObject'] != null)
    .map(
      (input) =>
          (input['UnresolvedObject'] as Map<String, dynamic>)['objectId']
              as String,
    )
    .toSet();

void main() {
  group('WAL coin pagination', () {
    test('findWalCoin finds a sufficient coin on page two', () async {
      final sui = _twoPages();
      final result = await _DirectClient(
        sui,
      ).findWalCoin(_owner, BigInt.from(8));
      expect(result, '0x2');
      expect(sui.cursors, [null, 'second']);
    });

    test(
      'findWalCoin merge candidate includes balance from page two',
      () async {
        final sui = _twoPages();
        final result = await _DirectClient(
          sui,
        ).findWalCoin(_owner, BigInt.from(12), merge: true);
        expect(result, '0x2');
        expect(sui.cursors, [null, 'second']);
        expect(sui.submittedTransaction, isNull);
      },
    );

    test('mergeWalCoins includes all pages in one merge command', () async {
      final sui = _twoPages();
      final result = await _DirectClient(
        sui,
      ).mergeWalCoins(_owner, _UnusedSigner());
      expect(result, '0x1');
      expect(sui.cursors, [null, 'second']);
      final tx = sui.submittedTransaction!;
      expect(_objectInputs(tx), {
        normalizeSuiAddress('0x1'),
        normalizeSuiAddress('0x2'),
      });
      final merge =
          tx.getData().commands!.single['MergeCoins'] as Map<String, dynamic>;
      expect(merge['destination'], containsPair('Input', 0));
      expect(merge['sources'], [containsPair('Input', 1)]);
    });

    test('WriteBlobFlow.register selects a coin from page two', () async {
      final sui = _twoPages();
      final flow = WriteBlobFlow(
        blob: Uint8List.fromList([1, 2, 3]),
        txBuilder: _builder(),
        relayClient: _UnusedRelay(),
        precomputedMetadata: _metadata(3),
        suiClient: sui,
      );
      await flow.encode();
      final tx = await flow.register(
        WriteBlobFlowRegisterOptions(
          epochs: 1,
          owner: _owner,
          deletable: true,
          walType: _walType,
          storageCost: BigInt.from(5),
          writeCost: BigInt.from(3),
          encodedSize: 1000,
        ),
      );
      expect(sui.cursors, [null, 'second']);
      expect(sui.systemReads, 1);
      expect(_objectInputs(tx), contains(normalizeSuiAddress('0x2')));
      expect(_objectInputs(tx), isNot(contains(normalizeSuiAddress('0x1'))));
      expect(sui.submittedTransaction, isNull);
    });

    test('WriteFilesFlow.register selects a coin from page two', () async {
      final sui = _twoPages();
      final flow = WriteFilesFlow(
        files: [
          WalrusFile.from(
            contents: Uint8List.fromList([1]),
            identifier: 'test',
          ),
        ],
        txBuilder: _builder(),
        relayClient: _UnusedRelay(),
        encoder: _FixtureEncoder(),
        suiClient: sui,
      );
      await flow.encode();
      final tx = await flow.register(
        WriteFilesFlowRegisterOptions(
          epochs: 1,
          owner: _owner,
          deletable: true,
          walType: _walType,
          storageCost: BigInt.from(5),
          writeCost: BigInt.from(3),
          encodedSize: 1000,
        ),
      );
      expect(sui.cursors, [null, 'second']);
      expect(sui.systemReads, 1);
      expect(_objectInputs(tx), contains(normalizeSuiAddress('0x2')));
      expect(_objectInputs(tx), isNot(contains(normalizeSuiAddress('0x1'))));
      expect(sui.submittedTransaction, isNull);
    });

    test('stops fetching as soon as a single coin is sufficient', () async {
      final sui = _twoPages();
      expect(await _DirectClient(sui).findWalCoin(_owner, BigInt.one), '0x1');
      expect(sui.cursors, [null]);
    });

    test(
      'returns null after all pages when combined balance is too low',
      () async {
        final sui = _twoPages();
        expect(
          await _DirectClient(
            sui,
          ).findWalCoin(_owner, BigInt.from(13), merge: true),
          isNull,
        );
        expect(sui.cursors, [null, 'second']);
      },
    );

    test('an empty terminal page ends selection', () async {
      final sui = _PagedSuiClient({null: PaginatedCoins([], null, false)});
      expect(await _DirectClient(sui).findWalCoin(_owner, BigInt.one), isNull);
      expect(sui.cursors, [null]);
    });

    test('an empty intermediate page still follows its cursor', () async {
      final sui = _PagedSuiClient({
        null: PaginatedCoins([], 'second', true),
        'second': PaginatedCoins([_coin('0x2', 10)], null, false),
      });
      expect(await _DirectClient(sui).findWalCoin(_owner, BigInt.one), '0x2');
      expect(sui.cursors, [null, 'second']);
    });

    test('hasNextPage false terminates even if a cursor remains', () async {
      final sui = _PagedSuiClient({
        null: PaginatedCoins([_coin('0x1', 2)], 'unused', false),
      });
      expect(
        await _DirectClient(sui).findWalCoin(_owner, BigInt.from(8)),
        isNull,
      );
      expect(sui.cursors, [null]);
    });

    for (final cursor in <String?>[null, '']) {
      test(
        'rejects an advertised next page with invalid cursor: $cursor',
        () async {
          final sui = _PagedSuiClient({
            null: PaginatedCoins([_coin('0x1', 2)], cursor, true),
          });
          await expectLater(
            _DirectClient(sui).findWalCoin(_owner, BigInt.from(8)),
            throwsStateError,
          );
          expect(sui.cursors, [null]);
        },
      );
    }

    test('rejects cursor cycles before requesting a page twice', () async {
      final sui = _PagedSuiClient({
        null: PaginatedCoins([_coin('0x1', 2)], 'a', true),
        'a': PaginatedCoins([], 'b', true),
        'b': PaginatedCoins([], 'a', true),
      });
      await expectLater(
        _DirectClient(sui).mergeWalCoins(_owner, _UnusedSigner()),
        throwsStateError,
      );
      expect(sui.cursors, [null, 'a', 'b']);
      expect(sui.submittedTransaction, isNull);
    });

    test(
      'does not double count overlapping pages when checking balance',
      () async {
        final sui = _PagedSuiClient({
          null: PaginatedCoins([_coin('0x1', 2)], 'second', true),
          'second': PaginatedCoins(
            [_coin('0x1', 2), _coin('0x2', 3)],
            null,
            false,
          ),
        });
        expect(
          await _DirectClient(
            sui,
          ).findWalCoin(_owner, BigInt.from(6), merge: true),
          isNull,
        );
      },
    );

    test('merge includes every distinct coin across three pages', () async {
      final sui = _PagedSuiClient({
        null: PaginatedCoins([_coin('0x1', 2)], 'second', true),
        'second': PaginatedCoins(
          [_coin('0x1', 2), _coin('0x2', 3)],
          'third',
          true,
        ),
        'third': PaginatedCoins([_coin('0x3', 4)], null, false),
      });
      await _DirectClient(sui).mergeWalCoins(_owner, _UnusedSigner());
      expect(sui.cursors, [null, 'second', 'third']);
      final tx = sui.submittedTransaction!;
      expect(_objectInputs(tx), {
        normalizeSuiAddress('0x1'),
        normalizeSuiAddress('0x2'),
        normalizeSuiAddress('0x3'),
      });
      final merge =
          tx.getData().commands!.single['MergeCoins'] as Map<String, dynamic>;
      expect(merge['destination'], containsPair('Input', 0));
      expect(merge['sources'], [
        containsPair('Input', 1),
        containsPair('Input', 2),
      ]);
    });

    test('merging no coins fails without signing', () async {
      final sui = _PagedSuiClient({null: PaginatedCoins([], null, false)});
      await expectLater(
        _DirectClient(sui).mergeWalCoins(_owner, _UnusedSigner()),
        throwsA(isA<InsufficientWalBalanceError>()),
      );
      expect(sui.submittedTransaction, isNull);
    });

    test('single coin followed by empty final page needs no merge', () async {
      final sui = _PagedSuiClient({
        null: PaginatedCoins([_coin('0x1', 2)], 'last', true),
        'last': PaginatedCoins([], null, false),
      });
      expect(
        await _DirectClient(sui).mergeWalCoins(_owner, _UnusedSigner()),
        '0x1',
      );
      expect(sui.cursors, [null, 'last']);
      expect(sui.submittedTransaction, isNull);
    });
  });
}
