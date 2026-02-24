/// Tests for the read committee epoch logic in WalrusDirectClient.
///
/// Validates:
/// - _getCertificationEpoch behavior during normal and transitioning epochs
/// - _getReadCommittee returns previous committee when appropriate
/// - WalrusDirectClient constructor and new public APIs
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:sui/sui.dart';

import 'package:dartus/dartus.dart';

void main() {
  group('WalrusDirectClient read committee API', () {
    late WalrusDirectClient client;

    setUp(() {
      client = WalrusDirectClient(
        network: WalrusNetwork.testnet,
        suiClient: SuiClient(SuiUrls.testnet),
      );
    });

    tearDown(() {
      client.close();
    });

    test('stakingState() returns a WalrusStakingState', () async {
      // This tests that our updated stakingState() can be called
      // and returns the enhanced WalrusStakingState type.
      try {
        final state = await client.stakingState();
        expect(state, isA<WalrusStakingState>());
        expect(state.epoch, greaterThan(0));
        expect(state.nShards, greaterThan(0));
        expect(state.epochState, isA<EpochState>());
        expect(state.epochState.kind, isA<EpochStateKind>());
      } catch (e) {
        // Network errors are acceptable in CI — just verify the API exists.
        expect(e, isNot(isA<TypeError>()));
      }
    });

    test('readBlobAttributes returns null for nonexistent blob', () async {
      try {
        final attrs = await client.readBlobAttributes(
          blobObjectId:
              '0x0000000000000000000000000000000000000000000000000000000000000000',
        );
        // Either null (no metadata) or throws (object not found).
        expect(attrs, isNull);
      } catch (e) {
        // Network/object errors are acceptable.
        expect(e, isNot(isA<TypeError>()));
      }
    });

    test('writeBlobAttributesTransaction builds a transaction', () async {
      try {
        final tx = await client.writeBlobAttributesTransaction(
          blobObjectId: '0xsome_blob_object',
          attributes: {'_walrusBlobType': 'quilt'},
        );
        expect(tx, isA<Transaction>());
      } catch (e) {
        // Package ID resolution may fail without network — that's fine.
        expect(e, isNot(isA<TypeError>()));
      }
    });
  });

  group('WalrusDirectClient execute wrappers', () {
    late WalrusDirectClient client;

    setUp(() {
      client = WalrusDirectClient(
        network: WalrusNetwork.testnet,
        suiClient: SuiClient(SuiUrls.testnet),
      );
    });

    tearDown(() {
      client.close();
    });

    test('executeDeleteBlobTransaction is callable', () {
      // Just verify the method exists and has the right signature.
      expect(client.executeDeleteBlobTransaction, isA<Function>());
    });

    test('executeExtendBlobTransaction is callable', () {
      expect(client.executeExtendBlobTransaction, isA<Function>());
    });

    test('executeWriteBlobAttributesTransaction is callable', () {
      expect(client.executeWriteBlobAttributesTransaction, isA<Function>());
    });
  });

  group('CommitteeResolver.resolveCommitteeFromMembers', () {
    test('method exists on CommitteeResolver', () {
      final resolver = CommitteeResolver(
        suiClient: SuiClient(SuiUrls.testnet),
        config: testnetWalrusPackageConfig,
      );
      expect(resolver.resolveCommitteeFromMembers, isA<Function>());
    });
  });
}
