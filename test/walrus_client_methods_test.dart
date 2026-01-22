library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/client/walrus_client.dart';
import 'package:dartus/src/models/walrus_api_error.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusClient - putBlob', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('put_blob_test_');
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

    test('uploads in-memory data successfully', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      server.handleNext((request) {
        expect(request.method, equals('PUT'));
        expect(request.uri.path, equals('/v1/blobs'));
        return MockResponse(
          200,
          jsonEncode({
            'newlyCreated': {
              'blobObject': {'blobId': 'test-blob-id-123'},
            },
          }),
        );
      });

      final response = await client.putBlob(data: data);
      expect(response, isNotEmpty);
      expect(response['newlyCreated'], isNotNull);
    });

    test('handles empty data upload', () async {
      final data = Uint8List(0);
      server.handleNext((request) {
        return MockResponse(
          200,
          jsonEncode({'status': 'ok', 'blobId': 'empty-blob'}),
        );
      });

      final response = await client.putBlob(data: data);
      expect(response, isNotEmpty);
    });

    test('handles large data upload', () async {
      // 100KB of data (reasonable for unit test)
      final data = Uint8List(100 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      server.handleNext((request) {
        return MockResponse(
          200,
          jsonEncode({'status': 'ok', 'size': data.length}),
        );
      });

      final response = await client.putBlob(data: data);
      expect(response['size'], equals(data.length));
    });

    test('sends correct content-type header', () async {
      server.handleNext((request) {
        expect(
          request.headers.value(HttpHeaders.contentTypeHeader),
          equals('application/octet-stream'),
        );
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlob(data: Uint8List.fromList([1, 2, 3]));
    });

    test('throws WalrusApiError on 400 response', () async {
      server.handleNext((request) {
        return MockResponse(
          400,
          jsonEncode({
            'error': {
              'code': 400,
              'status': 'BAD_REQUEST',
              'message': 'Invalid blob data',
            },
          }),
        );
      });

      expect(
        () => client.putBlob(data: Uint8List.fromList([1, 2, 3])),
        throwsA(isA<WalrusApiError>().having((e) => e.code, 'code', 400)),
      );
    });

    test('throws WalrusApiError on 500 response', () async {
      server.handleNext((request) {
        return MockResponse(500, 'Internal Server Error');
      });

      expect(
        () => client.putBlob(data: Uint8List.fromList([1, 2, 3])),
        throwsA(isA<WalrusApiError>().having((e) => e.code, 'code', 500)),
      );
    });
  });

  group('WalrusClient - putBlobFromFile', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;
    late File testFile;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('put_file_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
      testFile = File('${tempDir.path}/test-upload.dat');
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('uploads file successfully', () async {
      await testFile.writeAsBytes([1, 2, 3, 4, 5]);

      server.handleNext((request) {
        return MockResponse(200, jsonEncode({'blobId': 'file-blob-id'}));
      });

      final response = await client.putBlobFromFile(file: testFile);
      expect(response['blobId'], equals('file-blob-id'));
    });

    test('throws FileSystemException for non-existent file', () async {
      final nonExistent = File('${tempDir.path}/does-not-exist.dat');

      expect(
        () => client.putBlobFromFile(file: nonExistent),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('passes query parameters correctly', () async {
      await testFile.writeAsBytes([1, 2, 3]);

      server.handleNext((request) {
        expect(request.uri.queryParameters['epochs'], equals('5'));
        expect(request.uri.queryParameters['deletable'], equals('false'));
        expect(request.uri.queryParameters['send_object_to'], equals('0xabc'));
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlobFromFile(
        file: testFile,
        epochs: 5,
        deletable: false,
        sendObjectTo: '0xabc',
      );
    });
  });

  group('WalrusClient - putBlobStreaming', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;
    late File testFile;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('streaming_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:${server.port}'),
        aggregatorBaseUrl: Uri.parse('http://localhost:${server.port}'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
      testFile = File('${tempDir.path}/stream-upload.dat');
    });

    tearDown(() async {
      await client.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('streams file upload successfully', () async {
      await testFile.writeAsBytes([1, 2, 3, 4, 5]);

      server.handleNext((request) {
        return MockResponse(200, jsonEncode({'blobId': 'streamed-blob-id'}));
      });

      final response = await client.putBlobStreaming(file: testFile);
      expect(response['blobId'], equals('streamed-blob-id'));
    });

    test('throws FileSystemException for non-existent file', () async {
      final nonExistent = File('${tempDir.path}/no-stream.dat');

      expect(
        () => client.putBlobStreaming(file: nonExistent),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('passes all query parameters', () async {
      await testFile.writeAsBytes([1, 2, 3]);

      server.handleNext((request) {
        expect(request.uri.queryParameters['epochs'], equals('10'));
        expect(request.uri.queryParameters['deletable'], equals('true'));
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlobStreaming(
        file: testFile,
        epochs: 10,
        deletable: true,
      );
    });

    test('sends JWT token with streaming upload', () async {
      await testFile.writeAsBytes([1, 2, 3]);
      client.setJwtToken('stream-token');

      server.handleNext((request) {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          equals('Bearer stream-token'),
        );
        return MockResponse(200, jsonEncode({'status': 'ok'}));
      });

      await client.putBlobStreaming(file: testFile);
    });
  });

  group('WalrusClient - getBlob', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('get_blob_test_');
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

    test('fetches blob from server on cache miss', () async {
      final blobData = Uint8List.fromList([10, 20, 30, 40, 50]);

      server.handleNext((request) {
        expect(request.method, equals('GET'));
        expect(request.uri.path, equals('/v1/blobs/test-blob-id'));
        return MockResponse(200, String.fromCharCodes(blobData))
          ..isBinary = true
          ..binaryData = blobData;
      });

      final result = await client.getBlob('test-blob-id');
      expect(result, equals(blobData));
    });

    test('returns cached blob on cache hit', () async {
      final blobId = 'cached-blob-id';
      final blobData = Uint8List.fromList([1, 2, 3, 4, 5]);

      // First, populate cache
      await client.cache.put(blobId, blobData);

      // Server should NOT be called (no handler added)
      final result = await client.getBlob(blobId);
      expect(result, equals(blobData));
    });

    test('caches blob after successful fetch', () async {
      final blobId = 'cacheable-blob';
      final blobData = Uint8List.fromList([5, 6, 7, 8, 9]);

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = blobData;
      });

      await client.getBlob(blobId);

      // Verify it's now in cache
      final cached = await client.cache.get(blobId);
      expect(cached, equals(blobData));
    });

    test('throws WalrusApiError on 404', () async {
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

      expect(
        () => client.getBlob('nonexistent-blob'),
        throwsA(isA<WalrusApiError>().having((e) => e.code, 'code', 404)),
      );
    });
  });

  group('WalrusClient - getBlobMetadata', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('metadata_test_');
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

    test('sends HEAD request for metadata', () async {
      server.handleNext((request) {
        expect(request.method, equals('HEAD'));
        expect(request.uri.path, equals('/v1/blobs/metadata-blob'));
        return MockResponse(200, '')
          ..headers['content-length'] = '1024'
          ..headers['content-type'] = 'application/octet-stream';
      });

      final metadata = await client.getBlobMetadata('metadata-blob');
      expect(metadata, isA<Map<String, String>>());
    });

    test('throws WalrusApiError on 404', () async {
      server.handleNext((request) {
        return MockResponse(404, 'Not Found');
      });

      expect(
        () => client.getBlobMetadata('missing-blob'),
        throwsA(isA<WalrusApiError>().having((e) => e.code, 'code', 404)),
      );
    });
  });

  group('WalrusClient - getBlobAsFile', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('get_file_test_');
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

    test('writes blob to file from cache', () async {
      final blobId = 'file-cache-blob';
      final blobData = Uint8List.fromList([10, 20, 30, 40]);
      final destination = File('${tempDir.path}/output.dat');

      await client.cache.put(blobId, blobData);

      await client.getBlobAsFile(blobId: blobId, destination: destination);

      expect(await destination.exists(), isTrue);
      expect(await destination.readAsBytes(), equals(blobData));
    });

    test('fetches and writes blob when not cached', () async {
      final blobData = Uint8List.fromList([5, 10, 15, 20]);
      final destination = File('${tempDir.path}/fetched.dat');

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = blobData;
      });

      await client.getBlobAsFile(
        blobId: 'uncached-blob',
        destination: destination,
      );

      expect(await destination.exists(), isTrue);
      expect(await destination.readAsBytes(), equals(blobData));
    });

    test('creates parent directories if needed', () async {
      final blobData = Uint8List.fromList([1, 2, 3]);
      final destination = File('${tempDir.path}/deep/nested/dir/output.dat');

      await client.cache.put('nested-blob', blobData);

      await client.getBlobAsFile(
        blobId: 'nested-blob',
        destination: destination,
      );

      expect(await destination.exists(), isTrue);
    });
  });

  group('WalrusClient - getBlobAsFileStreaming', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('streaming_file_test_');
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

    test('streams blob to file', () async {
      final blobData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final destination = File('${tempDir.path}/streamed.dat');

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = blobData;
      });

      await client.getBlobAsFileStreaming(
        blobId: 'stream-blob',
        destination: destination,
      );

      expect(await destination.exists(), isTrue);
      expect(await destination.readAsBytes(), equals(blobData));
    });

    test('uses cache when available', () async {
      final blobData = Uint8List.fromList([11, 22, 33]);
      final destination = File('${tempDir.path}/cached-stream.dat');

      await client.cache.put('cached-stream-blob', blobData);

      await client.getBlobAsFileStreaming(
        blobId: 'cached-stream-blob',
        destination: destination,
      );

      expect(await destination.readAsBytes(), equals(blobData));
    });

    test('caches blob after streaming download', () async {
      final blobData = Uint8List.fromList([100, 101, 102]);
      final destination = File('${tempDir.path}/cache-after-stream.dat');

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = blobData;
      });

      await client.getBlobAsFileStreaming(
        blobId: 'to-cache-blob',
        destination: destination,
      );

      final cached = await client.cache.get('to-cache-blob');
      expect(cached, equals(blobData));
    });
  });

  group('WalrusClient - getBlobByObjectId', () {
    late MockHttpServer server;
    late WalrusClient client;
    late Directory tempDir;

    setUp(() async {
      server = await MockHttpServer.start();
      tempDir = await Directory.systemTemp.createTemp('object_id_test_');
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

    test('fetches blob by object ID (no caching)', () async {
      final blobData = Uint8List.fromList([1, 2, 3, 4, 5]);

      server.handleNext((request) {
        expect(request.uri.path, equals('/v1/blobs/0x12345'));
        return MockResponse(200, '')..binaryData = blobData;
      });

      final result = await client.getBlobByObjectId('0x12345');
      expect(result, equals(blobData));
    });

    test('does not use cache for object ID fetch', () async {
      final cachedData = Uint8List.fromList([1, 1, 1]);
      final serverData = Uint8List.fromList([2, 2, 2]);

      await client.cache.put('0x99999', cachedData);

      server.handleNext((request) {
        return MockResponse(200, '')..binaryData = serverData;
      });

      final result = await client.getBlobByObjectId('0x99999');
      // Should get server data, not cached data
      expect(result, equals(serverData));
    });
  });
}

/// Enhanced mock HTTP server for testing
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

      for (final entry in response.headers.entries) {
        request.response.headers.set(entry.key, entry.value);
      }

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
  bool isBinary = false;
  final Map<String, String> headers = {};
}
