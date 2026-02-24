/// Tests for [weightedShuffle] and [shuffle] randomness utilities.
library;

import 'dart:math';

import 'package:dartus/src/utils/randomness.dart';
import 'package:test/test.dart';

void main() {
  group('shuffle', () {
    test('returns a list of same length', () {
      final input = [1, 2, 3, 4, 5];
      final result = shuffle(List.of(input));
      expect(result.length, input.length);
    });

    test('contains same elements', () {
      final input = [1, 2, 3, 4, 5];
      final result = shuffle(List.of(input));
      expect(result.toSet(), input.toSet());
    });

    test('with fixed seed is deterministic', () {
      final a = shuffle(List.of([1, 2, 3, 4, 5]), Random(42));
      final b = shuffle(List.of([1, 2, 3, 4, 5]), Random(42));
      expect(a, equals(b));
    });

    test('different seeds produce different orders (likely)', () {
      final a = shuffle(List.of([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), Random(1));
      final b = shuffle(List.of([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), Random(2));
      // Very unlikely to be identical with 10! permutations.
      expect(a, isNot(equals(b)));
    });

    test('empty list returns empty', () {
      expect(shuffle(<int>[]), isEmpty);
    });

    test('single element returns same', () {
      expect(shuffle([42]), equals([42]));
    });
  });

  group('weightedShuffle', () {
    test('returns all items', () {
      final items = [
        WeightedItem(value: 'a', weight: 10),
        WeightedItem(value: 'b', weight: 5),
        WeightedItem(value: 'c', weight: 1),
      ];
      final result = weightedShuffle(items);
      expect(result.length, 3);
      expect(result.toSet(), {'a', 'b', 'c'});
    });

    test('with fixed seed is deterministic', () {
      final items = [
        WeightedItem(value: 'a', weight: 10),
        WeightedItem(value: 'b', weight: 5),
        WeightedItem(value: 'c', weight: 1),
      ];
      final a = weightedShuffle(items, Random(42));
      final b = weightedShuffle(items, Random(42));
      expect(a, equals(b));
    });

    test('heavily weighted item appears first most of the time', () {
      final items = [
        WeightedItem(value: 'heavy', weight: 1000),
        WeightedItem(value: 'light1', weight: 1),
        WeightedItem(value: 'light2', weight: 1),
      ];
      // Run many trials — 'heavy' should be first almost every time.
      var heavyFirstCount = 0;
      const trials = 200;
      for (var i = 0; i < trials; i++) {
        final result = weightedShuffle(items, Random(i));
        if (result.first == 'heavy') heavyFirstCount++;
      }
      // Should be first >90% of the time with weight 1000 vs 1.
      expect(heavyFirstCount, greaterThan(trials * 0.9));
    });

    test('empty list returns empty', () {
      expect(weightedShuffle(<WeightedItem<String>>[]), isEmpty);
    });

    test('single item returns that item', () {
      final result = weightedShuffle([WeightedItem(value: 99, weight: 5)]);
      expect(result, [99]);
    });

    test('equal weights produce varied orderings', () {
      final items = List.generate(
        10,
        (i) => WeightedItem<int>(value: i, weight: 1),
      );
      final a = weightedShuffle(items, Random(1));
      final b = weightedShuffle(items, Random(2));
      // Equal weights → Fisher-Yates-like behavior, very unlikely same order.
      expect(a, isNot(equals(b)));
    });
  });
}
