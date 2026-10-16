@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartus/direct.dart';
import 'package:test/test.dart';

/// Explicit read-only public-network smoke test. Never creates or signs a
/// transaction. Keep outside test/ so default checks remain deterministic.
void main() {
  for (final network in WalrusNetwork.values) {
    test(
      'native gRPC reads ${network.name}',
      () async {
        if (Platform.environment['DARTUS_RUN_LIVE_READS'] != 'true') {
          fail(
            'Set DARTUS_RUN_LIVE_READS=true for this read-only network check',
          );
        }
        final client = WalrusDirectClient.fromNetwork(network: network);
        addTearDown(client.close);
        final state = await client.systemState();
        final committee = await client.getCommittee();
        final staking = await client.stakingState();
        final cost = await client.storageCost(1024, 1);
        final walType = await client.getWalType();
        expect(state.nShards, greaterThan(0));
        expect(staking.epochState.value, isNotNull);
        expect(state.committeeSize, committee.nodes.length);
        expect(committee.nodeByShardIndex.length, state.nShards);
        expect(committee.nodes.every((n) => n.publicKey?.length == 96), isTrue);
        expect(cost.totalCost, greaterThan(BigInt.zero));
        expect(walType, endsWith('::wal::WAL'));
        print(
          '${network.name}: epoch=${state.epoch}, shards=${state.nShards}, '
          'members=${committee.nodes.length}, cost=${cost.totalCost} FROST',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
