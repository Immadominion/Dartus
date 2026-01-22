library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/client/walrus_client.dart';
import 'package:dartus/src/models/walrus_api_error.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusClient - HTTP Error Handling', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('error_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles 400 Bad Request', () async {
      server.handleNext((request) {
        return MockResponse(
          400,
          jsonEncode({
            'error': {
              'code': 400,
              'status': 'BAD_REQUEST',
              'message': 'Invalid blob format',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(400));
        expect(e.status, equals('BAD_REQUEST'));
        expect(e.message, equals('Invalid blob format'));
      }
    });

    test('handles 401 Unauthorized', () async {
      server.handleNext((request) {
        return MockResponse(
          401,
          jsonEncode({
            'error': {
              'code': 401,
              'status': 'UNAUTHORIZED',
              'message': 'Invalid or expired token',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(401));
        expect(e.status, equals('UNAUTHORIZED'));
      }
    });

    test('handles 403 Forbidden', () async {
      server.handleNext((request) {
        return MockResponse(
          403,
          jsonEncode({
            'error': {
              'code': 403,
              'status': 'FORBIDDEN',
              'message': 'Insufficient permissions',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(403));
        expect(e.status, equals('FORBIDDEN'));
      }
    });

    test('handles 404 Not Found', () async {
      server.handleNext((request) {
        return MockResponse(
          404,
          jsonEncode({
            'error': {
              'code': 404,
              'status': 'NOT_FOUND',
              'message': 'Blob not found',
            },
          }),
        );
      });

      try {
        await client.getBlob('missing-blob');
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(404));
        expect(e.status, equals('NOT_FOUND'));
        expect(e.message, equals('Blob not found'));
      }
    });

    test('handles 429 Too Many Requests', () async {
      server.handleNext((request) {
        return MockResponse(
          429,
          jsonEncode({
            'error': {
              'code': 429,
              'status': 'TOO_MANY_REQUESTS',
              'message': 'Rate limit exceeded',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(429));
        expect(e.status, equals('TOO_MANY_REQUESTS'));
      }
    });

    test('handles 500 Internal Server Error', () async {
      server.handleNext((request) {
        return MockResponse(500, 'Internal Server Error');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(500));
        expect(e.status, equals('SERVER_ERROR'));
      }
    });

    test('handles 502 Bad Gateway', () async {
      server.handleNext((request) {
        return MockResponse(502, 'Bad Gateway');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(502));
        expect(e.status, equals('SERVER_ERROR'));
      }
    });

    test('handles 503 Service Unavailable', () async {
      server.handleNext((request) {
        return MockResponse(503, 'Service Unavailable');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(503));
        expect(e.status, equals('SERVER_ERROR'));
      }
    });

    test('handles 504 Gateway Timeout', () async {
      server.handleNext((request) {
        return MockResponse(504, 'Gateway Timeout');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(504));
        expect(e.status, equals('SERVER_ERROR'));
      }
    });
  });

  group('WalrusClient - Response Parsing Edge Cases', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('parse_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles empty 200 response body', () async {
      server.handleNext((request) {
        return MockResponse(200, '');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(500));
        expect(e.status, equals('INVALID_RESPONSE'));
      }
    });

    test('handles malformed JSON response', () async {
      server.handleNext((request) {
        return MockResponse(200, 'not valid json {{{');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(500));
        expect(e.status, equals('INVALID_RESPONSE'));
      }
    });

    test('handles JSON array instead of object', () async {
      server.handleNext((request) {
        return MockResponse(200, jsonEncode(['a', 'b', 'c']));
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(500));
        expect(e.status, equals('INVALID_RESPONSE'));
      }
    });

    test('handles error response without structured payload', () async {
      server.handleNext((request) {
        return MockResponse(400, 'Plain text error message');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(400));
        expect(e.status, equals('CLIENT_ERROR'));
      }
    });

    test('handles error response with partial error object', () async {
      server.handleNext((request) {
        return MockResponse(
          400,
          jsonEncode({
            'error': {
              // Missing code, status
              'message': 'Something went wrong',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        // Falls back to response status code
        expect(e.code, equals(400));
        expect(e.message, equals('Something went wrong'));
      }
    });

    test('handles error response with extra fields', () async {
      server.handleNext((request) {
        return MockResponse(
          422,
          jsonEncode({
            'error': {
              'code': 422,
              'status': 'UNPROCESSABLE_ENTITY',
              'message': 'Validation failed',
              'details': ['Field A is invalid', 'Field B is required'],
              'timestamp': '2024-01-01T00:00:00Z',
              'requestId': 'abc-123',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(422));
        expect(e.status, equals('UNPROCESSABLE_ENTITY'));
        expect(e.details, contains('Field A is invalid'));
      }
    });

    test('handles nested error response structure', () async {
      server.handleNext((request) {
        return MockResponse(
          500,
          jsonEncode({
            'data': null,
            'error': {
              'code': 500,
              'status': 'INTERNAL_ERROR',
              'message': 'Database connection failed',
            },
          }),
        );
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(500));
        expect(e.status, equals('INTERNAL_ERROR'));
      }
    });
  });

  group('WalrusClient - Binary Response Edge Cases', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('binary_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles empty binary response', () async {
      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = Uint8List(0);
      });

      final result = await client.getBlob('empty-blob');
      expect(result, isEmpty);
    });

    test('handles binary response with null bytes', () async {
      final dataWithNulls = Uint8List.fromList([0, 1, 0, 2, 0, 3, 0]);

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = dataWithNulls;
      });

      final result = await client.getBlob('null-bytes-blob');
      expect(result, equals(dataWithNulls));
    });

    test('handles binary response with all 255 bytes', () async {
      final maxBytes = Uint8List.fromList(List.filled(100, 255));

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = maxBytes;
      });

      final result = await client.getBlob('max-bytes-blob');
      expect(result, equals(maxBytes));
    });
  });

  group('WalrusClient - Context Preservation', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('context_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('includes context in upload error', () async {
      server.handleNext((request) {
        return MockResponse(500, 'Server Error');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        // Context should mention blob/upload
        expect(
          e.context.toLowerCase(),
          anyOf(contains('upload'), contains('blob')),
        );
      }
    });

    test('includes context in download error', () async {
      server.handleNext((request) {
        return MockResponse(404, 'Not Found');
      });

      try {
        await client.getBlob('missing');
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.context.toLowerCase(), contains('blob'));
      }
    });

    test('includes blob ID in context for getBlobByObjectId', () async {
      server.handleNext((request) {
        return MockResponse(404, 'Not Found');
      });

      try {
        await client.getBlobByObjectId('0xABCDEF');
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.context, contains('0xABCDEF'));
      }
    });

    test('includes blob ID in context for getBlobMetadata', () async {
      server.handleNext((request) {
        return MockResponse(404, 'Not Found');
      });

      try {
        await client.getBlobMetadata('metadata-blob-123');
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.context, contains('metadata-blob-123'));
      }
    });
  });

  group('WalrusApiError - Exception Behavior', () {
    test('WalrusApiError is an Exception', () {
      final error = WalrusApiError(
        code: 500,
        status: 'SERVER_ERROR',
        message: 'Test error',
      );

      expect(error, isA<Exception>());
    });

    test('WalrusApiError can be caught as Exception', () async {
      Future<void> throwError() async {
        throw WalrusApiError(
          code: 500,
          status: 'SERVER_ERROR',
          message: 'Test',
        );
      }

      expect(() async {
        try {
          await throwError();
        } on Exception catch (_) {
          // Successfully caught as Exception
          return;
        }
        fail('Should have caught as Exception');
      }, returnsNormally);
    });

    test('toString produces readable output', () {
      final error = WalrusApiError(
        code: 404,
        status: 'NOT_FOUND',
        message: 'Blob not found',
        context: 'Fetching blob xyz',
        details: const ['Additional info'],
      );

      final str = error.toString();
      expect(str, contains('404'));
      expect(str, contains('NOT_FOUND'));
      expect(str, contains('Blob not found'));
      expect(str, contains('Fetching blob xyz'));
    });
  });
}

/// Mock HTTP server for testing
class MockHttpServer {
  MockHttpServer._(this._server, this.port);

  final HttpServer _server;
  final int port;
  final _handlers = <MockResponse Function(HttpRequest)>[];

  static Future<MockHttpServer> start() async {
    final server = await HttpServer.bind('localhost', 0);
    final mock = MockHttpServer._(server, server.port);
    mock._listen();
    return mock;
  }

  void _listen() {
    _server.listen((request) async {
      if (_handlers.isEmpty) {
        request.response.statusCode = 500;
        request.response.write('No handler configured');
        await request.response.close();
        return;
      }

      final handler = _handlers.removeAt(0);
      final response = handler(request);

      request.response.statusCode = response.statusCode;

      if (response.binaryData != null) {
        request.response.add(response.binaryData!);
      } else {
        request.response.write(response.body);
      }
      await request.response.close();
    });
  }

  void handleNext(MockResponse Function(HttpRequest) handler) {
    _handlers.add(handler);
  }

  Future<void> close() async {
    await _server.close();
  }
}

class MockResponse {
  MockResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
  Uint8List? binaryData;
}
