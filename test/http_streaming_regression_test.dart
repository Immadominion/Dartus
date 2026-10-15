@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class _ResponseClient extends http.BaseClient {
  _ResponseClient(this.respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

void main() {
  late Directory directory;
  late WalrusClient client;
  late http.Client transport;

  void useTransport(http.Client value, {Duration? timeout}) {
    transport = value;
    client = WalrusClient(
      publisherBaseUrl: Uri.parse('https://publisher.example'),
      aggregatorBaseUrl: Uri.parse('https://aggregator.example'),
      httpClient: transport,
      timeout: timeout ?? const Duration(milliseconds: 40),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dartus-stream-test-');
  });

  tearDown(() async {
    await client.close();
    transport.close();
    await directory.delete(recursive: true);
  });

  for (final operation in ['binary', 'json', 'error', 'head', 'file']) {
    test('$operation cancels a stalled response body on timeout', () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(
        onCancel: () => cancelled.complete(),
      );
      useTransport(
        _ResponseClient((_) async {
          return http.StreamedResponse(
            body.stream,
            operation == 'error' ? 503 : 200,
          );
        }),
      );
      final destination = File('${directory.path}/existing.bin');
      await destination.writeAsBytes([9, 8, 7]);
      final Future<Object?> result;
      switch (operation) {
        case 'json':
          result = client.putBlob(data: Uint8List.fromList([1]));
        case 'head':
          result = client.getBlobMetadata('blob');
        case 'file':
          result = client.getBlobAsFileStreaming(
            blobId: 'blob',
            destination: destination,
          );
        default:
          result = client.getBlob('blob');
      }
      // The outer deadline makes a missing SDK timeout fail quickly.
      await expectLater(
        result.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('SDK body timeout did not fire'),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
      await body.close();
      expect(await destination.readAsBytes(), [9, 8, 7]);
      expect(
        await directory.list().length,
        1,
        reason: 'No partial downloads remain',
      );
    });
  }

  test(
    'body timeout resets after each chunk rather than limiting total transfer',
    () async {
      useTransport(
        _ResponseClient((_) async {
          Stream<List<int>> chunks() async* {
            for (var i = 0; i < 8; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 15));
              yield [i];
            }
          }

          return http.StreamedResponse(chunks(), 200);
        }),
        timeout: const Duration(milliseconds: 100),
      );
      expect(await client.getBlob('active'), List<int>.generate(8, (i) => i));
    },
  );

  test(
    'streaming bypasses the byte cache and preserves large file contents',
    () async {
      const chunks = 256;
      const chunkSize = 64 * 1024;
      var requests = 0;
      useTransport(
        _ResponseClient((_) async {
          requests++;
          Stream<List<int>> data() async* {
            for (var i = 0; i < chunks; i++) {
              yield Uint8List(chunkSize)..fillRange(0, chunkSize, i);
            }
          }

          return http.StreamedResponse(
            data(),
            200,
            contentLength: chunks * chunkSize,
          );
        }),
        timeout: const Duration(seconds: 5),
      );
      await client.cache.put('large', [99]);
      final destination = File('${directory.path}/large.bin');
      await destination.writeAsBytes([9, 8, 7]);
      await client.getBlobAsFileStreaming(
        blobId: 'large',
        destination: destination,
      );
      expect(requests, 1);
      expect(await destination.length(), chunks * chunkSize);
      final file = await destination.open();
      try {
        for (var i = 0; i < chunks; i++) {
          final bytes = await file.read(chunkSize);
          expect(bytes.length, chunkSize);
          expect(bytes.every((value) => value == i), isTrue);
        }
      } finally {
        await file.close();
      }
      expect(
        await client.cache.get('large'),
        [99],
        reason: 'Streaming does not read or replace the byte cache',
      );
      expect(await directory.list().length, 1);
    },
  );

  test(
    'file-open failure cancels the body and removes staging files',
    () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(
        onCancel: () => cancelled.complete(),
      );
      useTransport(
        _ResponseClient((_) async => http.StreamedResponse(body.stream, 200)),
      );
      final destination = File('${directory.path}/existing.bin');
      await destination.writeAsBytes([9, 8, 7]);
      // Create this outside the override to avoid recursively overriding File.
      final missingParentFile = File('${directory.path}/missing/blob');
      await expectLater(
        IOOverrides.runZoned(
          () => client.getBlobAsFileStreaming(
            blobId: 'blob',
            destination: destination,
          ),
          createFile: (_) => missingParentFile,
        ),
        throwsA(isA<FileSystemException>()),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
      await body.close();
      expect(await destination.readAsBytes(), [9, 8, 7]);
      expect(await directory.list().length, 1);
    },
  );

  test('streaming error bodies stop after the diagnostic limit', () async {
    final cancelled = Completer<void>();
    final body = StreamController<List<int>>(
      onListen: () {},
      onCancel: () => cancelled.complete(),
    );
    useTransport(
      _ResponseClient((_) async => http.StreamedResponse(body.stream, 503)),
    );
    // A body that reaches the limit but never finishes must not hang or wait
    // for the timeout to discover the already-known HTTP failure.
    body.add(Uint8List(128 * 1024));
    final destination = File('${directory.path}/error.bin');
    await expectLater(
      client.getBlobAsFileStreaming(blobId: 'blob', destination: destination),
      throwsA(isA<WalrusApiError>().having((error) => error.code, 'code', 503)),
    );
    await cancelled.future.timeout(const Duration(seconds: 1));
    await body.close();
    expect(await directory.list().length, 0);
  });

  test(
    'staging cleanup failure does not replace the download error',
    () async {
      final body = StreamController<List<int>>();
      useTransport(
        _ResponseClient((_) async => http.StreamedResponse(body.stream, 200)),
        timeout: const Duration(seconds: 5),
      );
      final result = client
          .getBlobAsFileStreaming(
            blobId: 'blob',
            destination: File('${directory.path}/out.bin'),
          )
          .then<Object?>((_) => null, onError: (Object error) => error);
      body.add([1, 2, 3]);
      while (!directory.listSync().any(
        (entry) => entry.path.contains('.dartus-download-'),
      )) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // A non-writable parent makes deleting the staging directory fail.
      expect((await Process.run('chmod', ['555', directory.path])).exitCode, 0);
      try {
        body.addError(const HttpException('interrupted body'));
        await body.close();
        expect(await result, isA<HttpException>());
      } finally {
        await Process.run('chmod', ['755', directory.path]);
      }
    },
    testOn: '!windows',
  );

  test(
    'failed streaming leaves the old destination intact and removes partial files',
    () async {
      useTransport(
        _ResponseClient((_) async {
          Stream<List<int>> data() async* {
            yield [1, 2, 3];
            throw const HttpException('interrupted body');
          }

          return http.StreamedResponse(data(), 200);
        }),
      );
      final destination = File('${directory.path}/existing.bin');
      await destination.writeAsBytes([9, 8, 7]);
      await expectLater(
        client.getBlobAsFileStreaming(
          blobId: 'broken',
          destination: destination,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await destination.readAsBytes(), [9, 8, 7]);
      expect(await directory.list().length, 1);
      expect(await client.cache.get('broken'), isNull);
    },
  );
}
