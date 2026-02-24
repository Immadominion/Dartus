/// Tests for [retry] utility.
library;

import 'package:dartus/src/utils/retry.dart';
import 'package:test/test.dart';

void main() {
  group('retry', () {
    test('returns result on first success', () async {
      var callCount = 0;
      final result = await retry<int>(() {
        callCount++;
        return Future.value(42);
      });
      expect(result, 42);
      expect(callCount, 1);
    });

    test('retries up to count times on failure', () async {
      var callCount = 0;
      final result = await retry<int>(
        () {
          callCount++;
          if (callCount < 3) throw StateError('fail');
          return Future.value(99);
        },
        count: 5,
        delay: Duration.zero,
      );
      expect(result, 99);
      expect(callCount, 3);
    });

    test('throws after exhausting retries', () async {
      expect(
        () => retry<int>(
          () {
            throw StateError('always fail');
          },
          count: 3,
          delay: Duration.zero,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('respects condition — only retries matching errors', () async {
      var callCount = 0;
      expect(
        () => retry<int>(
          () {
            callCount++;
            throw ArgumentError('wrong');
          },
          count: 5,
          delay: Duration.zero,
          condition: (e) => e is StateError, // won't match ArgumentError
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Should fail on first attempt (condition didn't match).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(callCount, 1);
    });

    test('retries when condition matches', () async {
      var callCount = 0;
      final result = await retry<String>(
        () {
          callCount++;
          if (callCount < 3) throw StateError('transient');
          return Future.value('done');
        },
        count: 5,
        delay: Duration.zero,
        condition: (e) => e is StateError,
      );
      expect(result, 'done');
      expect(callCount, 3);
    });

    test('applies delay between retries', () async {
      final stopwatch = Stopwatch()..start();
      var callCount = 0;
      await retry<void>(
        () async {
          callCount++;
          if (callCount < 3) throw StateError('fail');
        },
        count: 5,
        delay: const Duration(milliseconds: 50),
      );
      stopwatch.stop();
      // 2 retries × ~50ms delay = ≥100ms.
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(80));
    });
  });
}
