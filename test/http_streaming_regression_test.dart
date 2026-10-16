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

// Inject filesystem failures after real writes, without relying on disk quotas
// or permissions (which differ between CI users and operating systems).
final class _DownloadFaults extends IOOverrides {
  _DownloadFaults({
    this.failWrite = false,
    this.failRename = false,
    this.failCleanup = false,
  });

  final bool failWrite;
  final bool failRename;
  final bool failCleanup;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (path.endsWith('${Platform.pathSeparator}blob') &&
        path.contains('.dartus-download-')) {
      return _StagingFile(file, failWrite: failWrite, failRename: failRename);
    }
    return file;
  }

  @override
  Directory createDirectory(String path) =>
      _DownloadDirectory(super.createDirectory(path), failCleanup);
}

class _StagingFile implements File {
  _StagingFile(
    this.delegate, {
    required this.failWrite,
    required this.failRename,
  });

  final File delegate;
  final bool failWrite;
  final bool failRename;

  @override
  String get path => delegate.path;

  @override
  Future<FileStat> stat() => delegate.stat();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final file = await delegate.open(mode: mode);
    return failWrite ? _FailingWrite(file) : file;
  }

  @override
  Future<File> rename(String newPath) {
    if (failRename) {
      throw FileSystemException('Injected rename failure', path);
    }
    return delegate.rename(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingWrite implements RandomAccessFile {
  _FailingWrite(this.delegate);
  final RandomAccessFile delegate;
  var writes = 0;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) {
    if (writes++ > 0) {
      throw FileSystemException(
        'Injected partial write failure',
        delegate.path,
      );
    }
    return delegate.writeFrom(buffer, start, end);
  }

  @override
  Future<void> close() => delegate.close();

  @override
  Future<RandomAccessFile> flush() => delegate.flush();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DownloadDirectory implements Directory {
  _DownloadDirectory(this.delegate, this.failCleanup);
  final Directory delegate;
  final bool failCleanup;

  @override
  String get path => delegate.path;

  @override
  Future<Directory> create({bool recursive = false}) =>
      delegate.create(recursive: recursive);

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _DownloadDirectory(await delegate.createTemp(prefix), failCleanup);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) {
    if (failCleanup) {
      throw FileSystemException('Injected cleanup failure', path);
    }
    return delegate.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  Future<void> waitForStagedBytes(Directory parent) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await for (final entry in parent.list()) {
        if (entry is Directory && entry.path.contains('.dartus-download-')) {
          final partial = File('${entry.path}/blob');
          if (await partial.exists() && await partial.length() > 0) return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Download did not write a staged chunk');
  }

  test('streaming preserves private destination permissions', () async {
    useTransport(
      _ResponseClient(
        (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
      ),
    );
    final destination = File('${directory.path}/private.bin');
    await destination.writeAsBytes([9, 8, 7]);
    expect((await Process.run('chmod', ['600', destination.path])).exitCode, 0);
    await client.getBlobAsFileStreaming(
      blobId: 'blob',
      destination: destination,
    );
    expect(await destination.readAsBytes(), [1, 2, 3]);
    expect((await destination.stat()).mode & 0xfff, 0x180);
    expect(await directory.list().length, 1);
  }, testOn: '!windows');

  for (final relative in [false, true]) {
    test(
      'streaming preserves ${relative ? 'relative' : 'absolute'} symlink and target permissions',
      () async {
        useTransport(
          _ResponseClient(
            (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
          ),
        );
        final targetParent = await Directory(
          '${directory.path}/targets',
        ).create();
        final target = File('${targetParent.path}/private.bin');
        await target.writeAsBytes([9, 8, 7]);
        expect((await Process.run('chmod', ['600', target.path])).exitCode, 0);
        final link = Link('${directory.path}/out.bin');
        final linkTarget = relative ? 'targets/private.bin' : target.path;
        await link.create(linkTarget);
        await client.getBlobAsFileStreaming(
          blobId: 'blob',
          destination: File(link.path),
        );
        expect(await link.target(), linkTarget);
        expect(await target.readAsBytes(), [1, 2, 3]);
        expect((await target.stat()).mode & 0xfff, 0x180);
        expect(await targetParent.list().length, 1);
      },
      testOn: '!windows',
    );
  }

  test(
    'broken destination symlink is preserved and fails clearly',
    () async {
      useTransport(
        _ResponseClient(
          (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
        ),
      );
      final link = await Link(
        '${directory.path}/out.bin',
      ).create('missing.bin');
      await expectLater(
        client.getBlobAsFileStreaming(
          blobId: 'blob',
          destination: File(link.path),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await link.target(), 'missing.bin');
      expect(await File('${directory.path}/missing.bin').exists(), isFalse);
      expect(await directory.list().length, 1);
    },
    testOn: '!windows',
  );

  for (final failure in ['write', 'rename']) {
    test('$failure failure preserves existing destination bytes', () async {
      useTransport(
        _ResponseClient(
          (_) async => http.StreamedResponse(
            Stream.fromIterable([
              [1, 2, 3],
              [4, 5, 6],
            ]),
            200,
          ),
        ),
      );
      final destination = File('${directory.path}/existing.bin');
      await destination.writeAsBytes([9, 8, 7]);
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => client.getBlobAsFileStreaming(
            blobId: 'blob',
            destination: destination,
          ),
          _DownloadFaults(
            failWrite: failure == 'write',
            failRename: failure == 'rename',
          ),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('Injected'),
          ),
        ),
      );
      expect(await destination.readAsBytes(), [9, 8, 7]);
      expect(await directory.list().length, 1);
    });
  }

  test('permission tightening during a download is not reverted', () async {
    final body = StreamController<List<int>>();
    useTransport(
      _ResponseClient((_) async => http.StreamedResponse(body.stream, 200)),
      timeout: const Duration(seconds: 5),
    );
    final destination = File('${directory.path}/existing.bin');
    await destination.writeAsBytes([9, 8, 7]);
    expect((await Process.run('chmod', ['644', destination.path])).exitCode, 0);
    final result = client
        .getBlobAsFileStreaming(blobId: 'blob', destination: destination)
        .then<Object?>((_) => null, onError: (Object error) => error);
    body.add([1, 2, 3]);
    await waitForStagedBytes(directory);
    expect((await Process.run('chmod', ['600', destination.path])).exitCode, 0);
    await body.close();
    expect(await result, isA<FileSystemException>());
    expect(await destination.readAsBytes(), [9, 8, 7]);
    expect((await destination.stat()).mode & 0xfff, 0x180);
    expect(await directory.list().length, 1);
  }, testOn: '!windows');

  test(
    'retargeting a symlink during download leaves both targets intact',
    () async {
      final body = StreamController<List<int>>();
      useTransport(
        _ResponseClient((_) async => http.StreamedResponse(body.stream, 200)),
        timeout: const Duration(seconds: 5),
      );
      final original = await File(
        '${directory.path}/original.bin',
      ).writeAsBytes([9]);
      final other = await File('${directory.path}/other.bin').writeAsBytes([8]);
      final link = await Link(
        '${directory.path}/out.bin',
      ).create(original.path);
      final result = client
          .getBlobAsFileStreaming(blobId: 'blob', destination: File(link.path))
          .then<Object?>((_) => null, onError: (Object error) => error);
      body.add([1, 2, 3]);
      await waitForStagedBytes(directory);
      await link.update(other.path);
      await body.close();
      expect(await result, isA<FileSystemException>());
      expect(await original.readAsBytes(), [9]);
      expect(await other.readAsBytes(), [8]);
      expect(await link.target(), other.path);
      expect(await directory.list().length, 3);
    },
    testOn: '!windows',
  );

  test(
    'a read-only destination fails without changing its contents',
    () async {
      useTransport(
        _ResponseClient(
          (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
        ),
      );
      final destination = await File(
        '${directory.path}/readonly.bin',
      ).writeAsBytes([9, 8, 7]);
      expect(
        (await Process.run('chmod', ['400', destination.path])).exitCode,
        0,
      );
      try {
        await expectLater(
          client.getBlobAsFileStreaming(
            blobId: 'blob',
            destination: destination,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await destination.readAsBytes(), [9, 8, 7]);
        expect((await destination.stat()).mode & 0xfff, 0x100);
      } finally {
        await Process.run('chmod', ['600', destination.path]);
      }
    },
    testOn: '!windows',
  );

  for (final bodyFails in [false, true]) {
    for (final loggerThrows in [false, true]) {
      test(
        'cleanup failure keeps ${bodyFails ? 'body error' : 'success'} with ${loggerThrows ? 'throwing' : 'normal'} logger',
        () async {
          useTransport(
            _ResponseClient((_) async {
              Stream<List<int>> data() async* {
                yield [1, 2, 3];
                if (bodyFails) throw const HttpException('original body error');
              }

              return http.StreamedResponse(data(), 200);
            }),
          );
          final records = <WalrusLogRecord>[];
          client.logger.level = WalrusLogLevel.error;
          client.logger.onRecord = (record) {
            records.add(record);
            if (loggerThrows) throw StateError('logging unavailable');
          };
          final destination = File('${directory.path}/existing.bin');
          await destination.writeAsBytes([9, 8, 7]);
          final result = IOOverrides.runWithIOOverrides(
            () => client.getBlobAsFileStreaming(
              blobId: 'blob',
              destination: destination,
            ),
            _DownloadFaults(failCleanup: true),
          );
          if (bodyFails) {
            await expectLater(result, throwsA(isA<HttpException>()));
          } else {
            await result;
          }
          expect(
            await destination.readAsBytes(),
            bodyFails ? [9, 8, 7] : [1, 2, 3],
          );
          expect(
            records.single.message,
            contains('Failed to remove staging directory'),
          );
          expect(
            await directory.list().length,
            2,
            reason: 'Failed cleanup is reported, not hidden',
          );
        },
      );
    }
  }

  test(
    'a stale download-like name does not authorize deleting user files',
    () async {
      useTransport(
        _ResponseClient(
          (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
        ),
      );
      final unrelated = await Directory(
        '${directory.path}/.dartus-download-documents',
      ).create();
      final valuable = await File(
        '${unrelated.path}/important.txt',
      ).writeAsString('keep me');
      final oldBlob = await File('${unrelated.path}/blob').writeAsBytes([99]);
      await oldBlob.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      await client.getBlobAsFileStreaming(
        blobId: 'blob',
        destination: File('${directory.path}/out.bin'),
      );
      expect(await valuable.readAsString(), 'keep me');
      expect(await oldBlob.readAsBytes(), [99]);
    },
  );

  test(
    'another download cannot sweep an old but active staging directory',
    () async {
      final body = StreamController<List<int>>();
      useTransport(
        _ResponseClient((_) async => http.StreamedResponse(body.stream, 200)),
        timeout: const Duration(days: 3),
      );
      final destination = File('${directory.path}/active.bin');
      final result = client
          .getBlobAsFileStreaming(blobId: 'active', destination: destination)
          .then<Object?>((_) => null, onError: (Object error) => error);
      body.add([1]);
      await waitForStagedBytes(directory);
      final staging = await directory
          .list()
          .where((entry) => entry is Directory)
          .single;
      // Simulate a suspended process / valid long idle timeout without a day-long test.
      await File(
        '${staging.path}/blob',
      ).setLastModified(DateTime.now().subtract(const Duration(days: 2)));
      final secondTransport = _ResponseClient(
        (_) async => http.StreamedResponse(Stream.value([2]), 200),
      );
      final second = WalrusClient(
        aggregatorBaseUrl: Uri.parse('https://aggregator.example'),
        httpClient: secondTransport,
      );
      try {
        await second.getBlobAsFileStreaming(
          blobId: 'second',
          destination: File('${directory.path}/second.bin'),
        );
        body.add([3]);
        await body.close();
        expect(await result, isNull);
        expect(await destination.readAsBytes(), [1, 3]);
        expect(await directory.list().length, 2);
      } finally {
        await second.close();
        secondTransport.close();
        if (!body.isClosed) await body.close();
      }
    },
  );

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
