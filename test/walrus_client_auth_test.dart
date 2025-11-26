import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/client/walrus_client.dart';
import 'package:dartus/src/models/walrus_api_error.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusClient JWT Authentication', () {
    late MockHttpServer server;
    late WalrusClient client;

    setUp(() async {
      server = await MockHttpServer.start();
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: await Directory.systemTemp.createTemp('jwt_test_'),
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('setJwtToken configures instance-level token', () async {
      client.setJwtToken('test-token-123');

      server.handleNext((request) {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          equals('Bearer test-token-123'),
        );
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
    });

    test('clearJwtToken removes instance-level token', () async {
      client.setJwtToken('test-token-123');
      client.clearJwtToken();

      server.handleNext((request) {
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
    });

    test('method-level jwtToken overrides instance token', () async {
      client.setJwtToken('instance-token');

      server.handleNext((request) {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          equals('Bearer method-token'),
        );
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(
        data: Uint8List.fromList([1, 2, 3]),
        jwtToken: 'method-token',
      );
    });

    test('no Authorization header when no token set', () async {
      server.handleNext((request) {
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
    });
  });

  group('WalrusClient Query Parameters', () {
    late MockHttpServer server;
    late WalrusClient client;

    setUp(() async {
      server = await MockHttpServer.start();
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: await Directory.systemTemp.createTemp('query_test_'),
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('builds query with epochs parameter', () async {
      server.handleNext((request) {
        expect(request.uri.queryParameters['epochs'], equals('10'));
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(data: Uint8List.fromList([1, 2, 3]), epochs: 10);
    });

    test('builds query with deletable parameter', () async {
      server.handleNext((request) {
        expect(request.uri.queryParameters['deletable'], equals('true'));
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(
        data: Uint8List.fromList([1, 2, 3]),
        deletable: true,
      );
    });

    test('builds query with sendObjectTo parameter', () async {
      server.handleNext((request) {
        expect(
          request.uri.queryParameters['send_object_to'],
          equals('0x1234567890abcdef'),
        );
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(
        data: Uint8List.fromList([1, 2, 3]),
        sendObjectTo: '0x1234567890abcdef',
      );
    });

    test('builds query with all parameters', () async {
      server.handleNext((request) {
        expect(request.uri.queryParameters['epochs'], equals('5'));
        expect(request.uri.queryParameters['deletable'], equals('false'));
        expect(request.uri.queryParameters['send_object_to'], equals('0xabc'));
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(
        data: Uint8List.fromList([1, 2, 3]),
        epochs: 5,
        deletable: false,
        sendObjectTo: '0xabc',
      );
    });

    test('omits null query parameters', () async {
      server.handleNext((request) {
        expect(request.uri.queryParameters, isEmpty);
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
    });
  });

  group('WalrusClient Error Parsing', () {
    late MockHttpServer server;
    late WalrusClient client;

    setUp(() async {
      server = await MockHttpServer.start();
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: await Directory.systemTemp.createTemp('error_test_'),
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('parses structured error response', () async {
      server.handleNext((request) {
        return MockResponse(
          404,
          jsonEncode({
            'error': {
              'code': 404,
              'status': 'NOT_FOUND',
              'message': 'Blob not found',
              'details': ['Detail 1', 'Detail 2'],
            },
          }),
        );
      });

      try {
        await client.getBlob('non-existent-blob');
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(404));
        expect(e.status, equals('NOT_FOUND'));
        expect(e.message, equals('Blob not found'));
        expect(e.details, equals(['Detail 1', 'Detail 2']));
      }
    });

    test('handles generic HTTP error without structured payload', () async {
      server.handleNext((request) {
        return MockResponse(500, 'Internal Server Error');
      });

      try {
        await client.getBlob('test-blob');
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(500));
        expect(e.status, equals('SERVER_ERROR'));
      }
    });

    test('handles malformed JSON response', () async {
      server.handleNext((request) {
        return MockResponse(400, 'Not valid JSON');
      });

      try {
        await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
        fail('Should have thrown WalrusApiError');
      } on WalrusApiError catch (e) {
        expect(e.code, equals(400));
        expect(e.status, equals('CLIENT_ERROR'));
      }
    });
  });
}

/// Simple mock HTTP server for testing
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
      request.response.write(response.body);
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
}
