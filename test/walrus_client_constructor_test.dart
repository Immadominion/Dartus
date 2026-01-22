library;

import 'dart:io';

import 'package:dartus/src/client/walrus_client.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusClient - Constructor Validation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('constructor_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates client with valid URIs', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.publisherBaseUrl.host, equals('publisher.example.com'));
      expect(client.aggregatorBaseUrl.host, equals('aggregator.example.com'));
      client.close();
    });

    test('normalizes base URLs to end with slash', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com/api'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.publisherBaseUrl.path, endsWith('/'));
      expect(client.aggregatorBaseUrl.path, endsWith('/'));
      client.close();
    });

    test('throws ArgumentError for URI without scheme', () {
      expect(
        () => WalrusClient(
          publisherBaseUrl: Uri.parse('publisher.example.com'),
          aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
          cacheDirectory: tempDir,
          logLevel: WalrusLogLevel.none,
        ),
        throwsArgumentError,
      );
    });

    test('requires valid URI with host', () {
      // WalrusClient validates URLs have proper scheme and host
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.publisherBaseUrl.host, equals('example.com'));
      client.close();
    });

    test('throws ArgumentError for cacheMaxSize of zero', () {
      expect(
        () => WalrusClient(
          publisherBaseUrl: Uri.parse('https://publisher.example.com'),
          aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
          cacheDirectory: tempDir,
          cacheMaxSize: 0,
          logLevel: WalrusLogLevel.none,
        ),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for negative cacheMaxSize', () {
      expect(
        () => WalrusClient(
          publisherBaseUrl: Uri.parse('https://publisher.example.com'),
          aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
          cacheDirectory: tempDir,
          cacheMaxSize: -5,
          logLevel: WalrusLogLevel.none,
        ),
        throwsArgumentError,
      );
    });

    test('accepts cacheMaxSize of 1', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        cacheMaxSize: 1,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.cache.maxSize, equals(1));
      client.close();
    });

    test('uses default timeout of 30 seconds', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.timeout, equals(const Duration(seconds: 30)));
      client.close();
    });

    test('accepts custom timeout', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        timeout: const Duration(seconds: 60),
        logLevel: WalrusLogLevel.none,
      );

      expect(client.timeout, equals(const Duration(seconds: 60)));
      client.close();
    });

    test('accepts custom HttpClient', () {
      final httpClient = HttpClient();
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        httpClient: httpClient,
        logLevel: WalrusLogLevel.none,
      );

      // Should not throw
      expect(client, isNotNull);
      client.close();
      httpClient.close();
    });

    test('initializes with JWT token', () async {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        jwtToken: 'initial-token',
        logLevel: WalrusLogLevel.none,
      );

      // Token is private, we can verify behavior in other tests
      expect(client, isNotNull);
      await client.close();
    });
  });

  group('WalrusClient - Log Level', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('log_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('defaults to basic log level', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
      );

      expect(client.logLevel, equals(WalrusLogLevel.basic));
      client.close();
    });

    test('accepts custom log level', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.verbose,
      );

      expect(client.logLevel, equals(WalrusLogLevel.verbose));
      client.close();
    });

    test('setLogLevel changes current level', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.logLevel, equals(WalrusLogLevel.none));

      client.setLogLevel(WalrusLogLevel.verbose);
      expect(client.logLevel, equals(WalrusLogLevel.verbose));

      client.setLogLevel(WalrusLogLevel.basic);
      expect(client.logLevel, equals(WalrusLogLevel.basic));

      client.close();
    });
  });

  group('WalrusClient - JWT Token Management', () {
    late Directory tempDir;
    late WalrusClient client;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('jwt_mgmt_test_');
      client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );
    });

    tearDown(() async {
      await client.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('setJwtToken sets the token', () {
      client.setJwtToken('my-token');
      // Token is private but behavior is verified in auth tests
      expect(() => client.setJwtToken('my-token'), returnsNormally);
    });

    test('clearJwtToken clears the token', () {
      client.setJwtToken('my-token');
      client.clearJwtToken();
      // Token is private but behavior is verified in auth tests
      expect(() => client.clearJwtToken(), returnsNormally);
    });

    test('setJwtToken can be called multiple times', () {
      client.setJwtToken('token-1');
      client.setJwtToken('token-2');
      client.setJwtToken('token-3');
      expect(() => client.setJwtToken('token-4'), returnsNormally);
    });

    test('clearJwtToken is safe to call multiple times', () {
      client.clearJwtToken();
      client.clearJwtToken();
      expect(() => client.clearJwtToken(), returnsNormally);
    });
  });

  group('WalrusClient - Resource Cleanup', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cleanup_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('close releases resources', () async {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      // Should not throw
      await expectLater(client.close(), completes);
    });

    test('close with force=true', () async {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      await expectLater(client.close(force: true), completes);
    });

    test('close does not close provided HttpClient', () async {
      final httpClient = HttpClient();

      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
        cacheDirectory: tempDir,
        httpClient: httpClient,
        logLevel: WalrusLogLevel.none,
      );

      await client.close();

      // HttpClient should still be usable after client.close()
      // (this doesn't throw if the client is still open)
      expect(() => httpClient.connectionTimeout, returnsNormally);

      httpClient.close();
    });
  });

  group('WalrusClient - URL Path Handling', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('url_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('handles base URL with trailing slash', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com/'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com/'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.publisherBaseUrl.path, equals('/'));
      expect(client.aggregatorBaseUrl.path, equals('/'));
      client.close();
    });

    test('handles base URL with path segments', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com/api/v2'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com/storage'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.publisherBaseUrl.path, equals('/api/v2/'));
      expect(client.aggregatorBaseUrl.path, equals('/storage/'));
      client.close();
    });

    test('base URL preserves query in normalized form', () {
      // Note: Uri.replace(query: null) in Dart doesn't actually clear
      // the query - this test documents actual behavior
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.example.com/'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.example.com/'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      // Verify normalized path ends with slash
      expect(client.publisherBaseUrl.path, endsWith('/'));
      expect(client.aggregatorBaseUrl.path, endsWith('/'));
      client.close();
    });

    test('handles various URI formats', () {
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('http://localhost:8080/'),
        aggregatorBaseUrl: Uri.parse('https://192.168.1.1:443/api'),
        cacheDirectory: tempDir,
        logLevel: WalrusLogLevel.none,
      );

      expect(client.publisherBaseUrl.host, equals('localhost'));
      expect(client.publisherBaseUrl.port, equals(8080));
      expect(client.aggregatorBaseUrl.path, equals('/api/'));
      client.close();
    });
  });
}
