/// Deterministic chain fixtures: no public RPC endpoint or wallet is used.
@TestOn('vm')
@Tags(['unit'])
library;

import 'package:dartus/direct.dart';
import 'package:sui/sui.dart';
import 'package:test/test.dart';

const _packageId = '0x1234';
const _blobId = '0xabcd';

class _FixtureRpc extends JsonRpcClient {
  _FixtureRpc() : super('https://rpc.invalid');

  final calls = <String>[];
  String epochVariant = 'EpochChangeSync';
  Object? failure;
  bool missingState = false;
  bool malformedCommittee = false;

  @override
  Future<dynamic> request(String method, [List<dynamic>? args]) async {
    calls.add(method);
    if (failure != null) throw failure!;
    final parameters = args ?? [];
    switch (method) {
      case 'sui_getObject':
        expect(parameters.first, testnetWalrusPackageConfig.stakingPoolId);
        return _object({'version': '1', 'package_id': _packageId});
      case 'suix_getDynamicFieldObject':
        if (parameters.first == _blobId) {
          expect(parameters[1], {
            'type': 'vector<u8>',
            'value': 'metadata'.codeUnits,
          });
          return {
            'error': {'code': 'dynamicFieldNotFound'},
          };
        }
        expect(parameters.first, testnetWalrusPackageConfig.stakingPoolId);
        expect(parameters[1], {'type': 'u64', 'value': '1'});
        if (missingState) {
          return {
            'error': {'code': 'notExists'},
          };
        }
        return _object({
          'value': {
            'fields': {
              'n_shards': '4',
              'epoch': '42',
              'committee': malformedCommittee ? 123 : _members('0xaaa', [0, 1]),
              'previous_committee': _members('0xbbb', [2, 3]),
              'epoch_state': {epochVariant: '7'},
            },
          },
        });
      case 'sui_multiGetObjects':
        expect(parameters.first, ['0xbbb']);
        return [
          _object({
            'node_info': {
              'fields': {
                'node_id': '0xbbb',
                'network_address': 'node.invalid:443',
                'public_key': {
                  'bytes': [1, 2, 3],
                },
              },
            },
          }),
        ];
      default:
        throw StateError('Unexpected RPC call: $method');
    }
  }
}

class _FixtureSuiClient extends SuiClient {
  _FixtureSuiClient(this.fixture) : super('https://rpc.invalid');
  final _FixtureRpc fixture;

  @override
  JsonRpcClient get client => fixture;
}

Map<String, dynamic> _object(Map<String, dynamic> fields) => {
  'data': {
    'objectId': '0xcafe',
    'version': '1',
    'digest': 'fixture',
    'type': '0x1234::fixture::Object',
    'content': {
      'dataType': 'moveObject',
      'type': '0x1234::fixture::Object',
      'fields': fields,
    },
  },
};

Map<String, dynamic> _members(String node, List<int> shards) => {
  'contents': [
    {'key': node, 'value': shards},
  ],
};

void main() {
  late _FixtureRpc rpc;
  late _FixtureSuiClient sui;
  late WalrusDirectClient client;

  setUp(() {
    rpc = _FixtureRpc();
    sui = _FixtureSuiClient(rpc);
    client = WalrusDirectClient(
      network: WalrusNetwork.testnet,
      walrusPackageId: _packageId,
      suiClient: sui,
    );
  });
  tearDown(() => client.close());

  for (final variant in {
    'EpochChangeSync': EpochStateKind.epochChangeSync,
    'EpochChangeDone': EpochStateKind.epochChangeDone,
    'NextParamsSelected': EpochStateKind.nextParamsSelected,
  }.entries) {
    test('stakingState parses ${variant.key} and committee values', () async {
      rpc.epochVariant = variant.key;
      final state = await client.stakingState();
      expect(state.epoch, 42);
      expect(state.nShards, 4);
      expect(state.epochState.kind, variant.value);
      expect(state.epochState.value, 7);
      expect(state.committeeMembers, {
        '0xaaa': [0, 1],
      });
      expect(state.previousCommittee, {
        '0xbbb': [2, 3],
      });
      expect(await client.stakingState(), same(state));
      expect(rpc.calls, ['sui_getObject', 'suix_getDynamicFieldObject']);
    });
  }

  test('stakingState propagates a network failure', () async {
    final failure = StateError('RPC unavailable');
    rpc.failure = failure;
    await expectLater(client.stakingState(), throwsA(same(failure)));
  });

  test('stakingState rejects a missing dynamic field', () async {
    rpc.missingState = true;
    await expectLater(
      client.stakingState(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Failed to read staking state'),
        ),
      ),
    );
  });

  test('stakingState rejects malformed committee data', () async {
    rpc.malformedCommittee = true;
    await expectLater(
      client.stakingState(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Unexpected committee format'),
        ),
      ),
    );
  });

  test(
    'readBlobAttributes returns null for an absent metadata field',
    () async {
      expect(await client.readBlobAttributes(blobObjectId: _blobId), isNull);
      expect(rpc.calls, ['suix_getDynamicFieldObject']);
    },
  );

  test('readBlobAttributes propagates unexpected RPC failures', () async {
    final failure = StateError('RPC unavailable');
    rpc.failure = failure;
    await expectLater(
      client.readBlobAttributes(blobObjectId: _blobId),
      throwsA(same(failure)),
    );
  });

  test('writeBlobAttributesTransaction builds metadata Move calls', () async {
    final tx = await client.writeBlobAttributesTransaction(
      blobObjectId: _blobId,
      attributes: {'_walrusBlobType': 'quilt'},
    );
    final calls = tx.getData().commands!.map((command) {
      final call = command['MoveCall'] as Map<String, dynamic>;
      return '${call['module']}::${call['function']}';
    }).toList();
    expect(calls, [
      'metadata::new',
      'blob::add_metadata',
      'blob::insert_or_update_metadata_pair',
    ]);
    expect(rpc.calls, ['suix_getDynamicFieldObject']);
  });

  test(
    'resolver maps supplied committee members to nodes and shards',
    () async {
      final resolver = CommitteeResolver(
        suiClient: sui,
        config: testnetWalrusPackageConfig,
      );
      final committee = await resolver.resolveCommitteeFromMembers({
        '0xbbb': [2, 3],
      });
      expect(committee.epoch, 42);
      expect(committee.numShards, 4);
      expect(committee.nodeByShardIndex.keys, [2, 3]);
      final node = committee.nodeByShardIndex[2]!;
      expect(node.nodeId, '0xbbb');
      expect(node.endpointUrl, 'https://node.invalid:443');
      expect(node.publicKey, [1, 2, 3]);
      expect(committee.nodeByShardIndex[3], same(node));
      expect(rpc.calls, [
        'sui_getObject',
        'suix_getDynamicFieldObject',
        'sui_multiGetObjects',
      ]);
    },
  );

  test('resolver rejects an empty committee', () async {
    final resolver = CommitteeResolver(
      suiClient: sui,
      config: testnetWalrusPackageConfig,
    );
    await expectLater(
      resolver.resolveCommitteeFromMembers({}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Committee has no members',
        ),
      ),
    );
  });
}
