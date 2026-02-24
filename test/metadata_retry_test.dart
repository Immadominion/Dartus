/// Tests for metadata write retry behavior.
///
/// Validates that the retry utility correctly retries on
/// BlobNotRegisteredError (as used in _writeEncodedBlobToNode).
@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:dartus/src/errors/walrus_errors.dart';
import 'package:dartus/src/utils/retry.dart';

void main() {
  group('retry with BlobNotRegisteredError condition', () {
    test('retries on BlobNotRegisteredError and succeeds', () async {
      var attempts = 0;

      final result = await retry<String>(
        () async {
          attempts++;
          if (attempts < 3) {
            throw const BlobNotRegisteredError('Blob not registered');
          }
          return 'success';
        },
        count: 3,
        delay: const Duration(milliseconds: 10), // Short for testing
        condition: (e) => e is BlobNotRegisteredError,
      );

      expect(result, 'success');
      expect(attempts, 3);
    });

    test('does not retry on non-matching errors', () async {
      var attempts = 0;

      expect(() async {
        await retry<String>(
          () async {
            attempts++;
            throw StateError('unrelated error');
          },
          count: 3,
          delay: const Duration(milliseconds: 10),
          condition: (e) => e is BlobNotRegisteredError,
        );
      }, throwsA(isA<StateError>()));

      // Should only attempt once since condition doesn't match.
      expect(attempts, 1);
    });

    test('throws after exhausting retries', () async {
      var attempts = 0;

      try {
        await retry<String>(
          () async {
            attempts++;
            throw const BlobNotRegisteredError('Still not registered');
          },
          count: 3,
          delay: const Duration(milliseconds: 10),
          condition: (e) => e is BlobNotRegisteredError,
        );
        fail('Should have thrown');
      } on BlobNotRegisteredError {
        // Expected.
      }

      expect(attempts, 3);
    });

    test('retries with default count of 3', () async {
      var attempts = 0;

      try {
        await retry<String>(
          () async {
            attempts++;
            throw const BlobNotRegisteredError('not registered');
          },
          delay: const Duration(milliseconds: 10),
          condition: (e) => e is BlobNotRegisteredError,
        );
        fail('Should have thrown');
      } on BlobNotRegisteredError {
        // Expected.
      }

      expect(attempts, 3); // Default count
    });
  });
}
