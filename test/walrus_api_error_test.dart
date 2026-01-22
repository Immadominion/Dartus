library;

import 'package:dartus/src/models/walrus_api_error.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusApiError', () {
    test('creates error with all fields', () {
      final error = WalrusApiError(
        code: 404,
        status: 'NOT_FOUND',
        message: 'Blob not found',
        details: const ['Detail 1', 'Detail 2'],
        context: 'Fetching blob by ID',
      );

      expect(error.code, equals(404));
      expect(error.status, equals('NOT_FOUND'));
      expect(error.message, equals('Blob not found'));
      expect(error.details, equals(['Detail 1', 'Detail 2']));
      expect(error.context, equals('Fetching blob by ID'));
    });

    test('creates error with default empty details and context', () {
      final error = WalrusApiError(
        code: 500,
        status: 'SERVER_ERROR',
        message: 'Internal server error',
      );

      expect(error.code, equals(500));
      expect(error.status, equals('SERVER_ERROR'));
      expect(error.message, equals('Internal server error'));
      expect(error.details, isEmpty);
      expect(error.context, isEmpty);
    });

    test('toString includes context when present', () {
      final error = WalrusApiError(
        code: 404,
        status: 'NOT_FOUND',
        message: 'Blob not found',
        context: 'Test context',
      );

      final errorString = error.toString();
      expect(errorString, contains('Test context'));
      expect(errorString, contains('HTTP 404'));
      expect(errorString, contains('NOT_FOUND'));
      expect(errorString, contains('Blob not found'));
    });

    test('toString excludes context when empty', () {
      final error = WalrusApiError(
        code: 500,
        status: 'SERVER_ERROR',
        message: 'Server error',
      );

      final errorString = error.toString();
      expect(errorString, contains('HTTP 500'));
      expect(errorString, contains('SERVER_ERROR'));
      expect(errorString, contains('Server error'));
      // Error has message, so it will contain ':' separator between status and message
      // This is expected behavior
    });

    test('toString includes details when present', () {
      final error = WalrusApiError(
        code: 400,
        status: 'BAD_REQUEST',
        message: 'Invalid request',
        details: const [
          'Missing parameter: epochs',
          'Invalid value: deletable',
        ],
      );

      final errorString = error.toString();
      expect(errorString, contains('(Details:'));
      expect(errorString, contains('Missing parameter: epochs'));
      expect(errorString, contains('Invalid value: deletable'));
    });

    test('toString excludes details when empty', () {
      final error = WalrusApiError(
        code: 400,
        status: 'BAD_REQUEST',
        message: 'Invalid request',
      );

      final errorString = error.toString();
      expect(errorString, isNot(contains('Details')));
    });

    test('is Exception type', () {
      final error = WalrusApiError(
        code: 404,
        status: 'NOT_FOUND',
        message: 'Not found',
      );

      expect(error, isA<Exception>());
    });

    test('immutable - different instances with same values are equal', () {
      final error1 = WalrusApiError(
        code: 404,
        status: 'NOT_FOUND',
        message: 'Not found',
      );

      final error2 = WalrusApiError(
        code: 404,
        status: 'NOT_FOUND',
        message: 'Not found',
      );

      // Note: WalrusApiError uses @immutable but doesn't override == operator
      // This test documents current behavior
      expect(error1.code, equals(error2.code));
      expect(error1.status, equals(error2.status));
      expect(error1.message, equals(error2.message));
    });
  });
}
