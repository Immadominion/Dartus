/// Randomness utilities for Walrus SDK operations.
///
/// Mirrors the TypeScript SDK's `utils/randomness.ts`, providing:
/// - [weightedShuffle] — weight-proportional random ordering (used when
///   selecting which storage nodes to query for slivers)
/// - [shuffle] — Fisher-Yates shuffle (used when querying nodes for metadata)
library;

import 'dart:math';

/// An item paired with a weight for [weightedShuffle].
class WeightedItem<T> {
  final T value;
  final int weight;

  const WeightedItem({required this.value, required this.weight});
}

/// Returns the values from [items] in a random order that respects weights.
///
/// Higher-weighted items are more likely to appear earlier in the result.
/// Uses the algorithm: for each item, compute `random^(1/weight)` and sort
/// descending. This is a well-known weighted random sampling technique.
///
/// Matches the TS SDK:
/// ```typescript
/// export function weightedShuffle<T>(arr: WeightedItem<T>[]): T[] {
///   return arr
///     .map(({ value, weight }) => ({
///       value,
///       weight: Math.pow(Math.random(), 1 / weight),
///     }))
///     .sort((a, b) => b.weight - a.weight)
///     .map((item) => item.value);
/// }
/// ```
List<T> weightedShuffle<T>(List<WeightedItem<T>> items, [Random? rng]) {
  final random = rng ?? Random();

  final scored = items.map((item) {
    // Avoid division by zero: treat weight 0 as very low priority.
    final w = item.weight > 0 ? item.weight : 1;
    final score = pow(random.nextDouble(), 1.0 / w);
    return _ScoredItem(item.value, score.toDouble());
  }).toList();

  // Sort descending by score — higher scores first.
  scored.sort((a, b) => b.score.compareTo(a.score));

  return scored.map((s) => s.value).toList();
}

/// Fisher-Yates shuffle — returns a new list with elements in random order.
///
/// Matches the TS SDK:
/// ```typescript
/// export function shuffle<T>(arr: T[]): T[] {
///   const result = [...arr];
///   for (let i = result.length - 1; i > 0; i -= 1) {
///     const j = Math.floor(Math.random() * (i + 1));
///     [result[i], result[j]] = [result[j], result[i]];
///   }
///   return result;
/// }
/// ```
List<T> shuffle<T>(List<T> list, [Random? rng]) {
  final random = rng ?? Random();
  final result = List<T>.from(list);

  for (var i = result.length - 1; i > 0; i -= 1) {
    final j = random.nextInt(i + 1);
    final temp = result[i];
    result[i] = result[j];
    result[j] = temp;
  }

  return result;
}

/// Internal helper to pair a value with its random score.
class _ScoredItem<T> {
  final T value;
  final double score;

  _ScoredItem(this.value, this.score);
}
