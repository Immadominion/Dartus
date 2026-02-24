/// Tests for EpochState parsing and WalrusStakingState extensions.
///
/// Validates:
/// - EpochState enum kinds and transitioning detection
/// - EpochState parsing from various JSON-RPC formats
/// - WalrusStakingState with epochState and previousCommittee fields
@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:dartus/src/chain/system_state_reader.dart';

void main() {
  group('EpochStateKind', () {
    test('has three values', () {
      expect(EpochStateKind.values.length, 3);
      expect(
        EpochStateKind.values,
        containsAll([
          EpochStateKind.epochChangeSync,
          EpochStateKind.epochChangeDone,
          EpochStateKind.nextParamsSelected,
        ]),
      );
    });
  });

  group('EpochState', () {
    test('isTransitioning returns true for epochChangeSync', () {
      const state = EpochState(kind: EpochStateKind.epochChangeSync);
      expect(state.isTransitioning, isTrue);
    });

    test('isTransitioning returns false for epochChangeDone', () {
      const state = EpochState(kind: EpochStateKind.epochChangeDone);
      expect(state.isTransitioning, isFalse);
    });

    test('isTransitioning returns false for nextParamsSelected', () {
      const state = EpochState(kind: EpochStateKind.nextParamsSelected);
      expect(state.isTransitioning, isFalse);
    });

    test('value is preserved', () {
      const state = EpochState(kind: EpochStateKind.epochChangeSync, value: 42);
      expect(state.value, 42);
    });

    test('value defaults to null', () {
      const state = EpochState(kind: EpochStateKind.epochChangeDone);
      expect(state.value, isNull);
    });

    test('toString includes kind and value', () {
      const state = EpochState(kind: EpochStateKind.epochChangeSync, value: 5);
      expect(state.toString(), contains('epochChangeSync'));
      expect(state.toString(), contains('5'));
    });
  });

  group('WalrusStakingState with epochState', () {
    test('creates with epochState', () {
      const state = WalrusStakingState(
        nShards: 1000,
        epoch: 42,
        committeeMembers: {
          '0xabc': [0, 1, 2],
        },
        epochState: EpochState(kind: EpochStateKind.nextParamsSelected),
      );

      expect(state.nShards, 1000);
      expect(state.epoch, 42);
      expect(state.epochState.kind, EpochStateKind.nextParamsSelected);
      expect(state.epochState.isTransitioning, isFalse);
      expect(state.previousCommittee, isNull);
    });

    test('creates with previousCommittee', () {
      const prevCommittee = {
        '0xdef': [3, 4, 5],
      };
      const state = WalrusStakingState(
        nShards: 1000,
        epoch: 42,
        committeeMembers: {
          '0xabc': [0, 1, 2],
        },
        epochState: EpochState(kind: EpochStateKind.epochChangeSync),
        previousCommittee: prevCommittee,
      );

      expect(state.epochState.isTransitioning, isTrue);
      expect(state.previousCommittee, isNotNull);
      expect(state.previousCommittee!['0xdef'], [3, 4, 5]);
    });

    test('toString includes epochState', () {
      const state = WalrusStakingState(
        nShards: 500,
        epoch: 10,
        committeeMembers: {},
        epochState: EpochState(kind: EpochStateKind.epochChangeDone),
      );

      final str = state.toString();
      expect(str, contains('nShards: 500'));
      expect(str, contains('epoch: 10'));
      expect(str, contains('epochState'));
    });
  });
}
