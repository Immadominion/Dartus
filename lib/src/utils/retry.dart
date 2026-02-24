/// Retry utility for Walrus SDK operations.
///
/// Mirrors the TypeScript SDK's `utils/retry.ts`, providing configurable
/// retry logic with delay, jitter, and conditional retry evaluation.
library;

import 'dart:math';

/// Retries [fn] up to [count] times with configurable [delay] and [jitter].
///
/// If [condition] is provided, only retries when `condition(error)` returns
/// `true`. Otherwise retries on any error.
///
/// Matching the TS SDK signature:
/// ```typescript
/// export async function retry<T>(
///   fn: () => Promise<T>,
///   options: { condition?, count?, delay?, jitter? },
/// ): Promise<T>
/// ```
///
/// Example:
/// ```dart
/// final result = await retry(
///   () => storageNodeClient.storeBlobMetadata(blobId: id, metadata: meta),
///   count: 3,
///   delay: const Duration(milliseconds: 1000),
///   condition: (e) => e is BlobNotRegisteredError,
/// );
/// ```
Future<T> retry<T>(
  Future<T> Function() fn, {
  int count = 3,
  Duration? delay,
  Duration? jitter,
  bool Function(Object error)? condition,
}) async {
  int remaining = count;
  final random = jitter != null ? Random() : null;

  while (remaining > 0) {
    try {
      remaining -= 1;
      return await fn();
    } catch (error) {
      if (remaining <= 0 || (condition != null && !condition(error))) {
        rethrow;
      }

      if (delay != null) {
        final jitterMs = jitter != null
            ? (random!.nextDouble() * jitter.inMilliseconds)
            : 0;
        final totalDelay = Duration(
          milliseconds: delay.inMilliseconds + jitterMs.toInt(),
        );
        await Future<void>.delayed(totalDelay);
      }
    }
  }

  // Should never be reached
  throw StateError('Retry count exceeded');
}
