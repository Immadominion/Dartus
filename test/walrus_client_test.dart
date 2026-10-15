@TestOn('vm')
@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/src/client/walrus_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late WalrusClient client;
  late MockClient transport;
  late Directory temp;
  late File source;
  late List<String> requests;
  final bytes = Uint8List.fromList(utf8.encode('Dartus local file fixture\n'));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dartus-file-test-');
    source = await File('${temp.path}/source').writeAsBytes(bytes);
    requests = [];
    transport = MockClient((request) async {
      requests.add(request.method);
      if (request.method == 'PUT') {
        expect(request.url.path, '/v1/blobs');
        expect(request.bodyBytes, bytes);
        return http.Response(
          jsonEncode({
            'newlyCreated': {
              'blobObject': {'blobId': 'fixture-blob'},
            },
          }),
          200,
        );
      }
      expect(request.url.path, '/v1/blobs/fixture-blob');
      return http.Response.bytes(bytes, 200);
    });
    client = WalrusClient(
      publisherBaseUrl: Uri.parse('https://publisher.invalid'),
      aggregatorBaseUrl: Uri.parse('https://aggregator.invalid'),
      httpClient: transport,
    );
  });

  tearDown(() async {
    await client.close();
    transport.close();
    await temp.delete(recursive: true);
  });

  test('uploads a local file and fetches the exact bytes by blob id', () async {
    final response = await client.putBlobFromFile(file: source);
    final created = response['newlyCreated'] as Map<String, dynamic>;
    final object = created['blobObject'] as Map<String, dynamic>;
    expect(object['blobId'], 'fixture-blob');
    expect(await client.getBlob(object['blobId'] as String), bytes);
    expect(requests, ['PUT', 'GET']);
  });

  test('downloads exact bytes to disk', () async {
    final destination = File('${temp.path}/download');
    await client.getBlobAsFile(
      blobId: 'fixture-blob',
      destination: destination,
    );
    expect(await destination.readAsBytes(), bytes);
    expect(requests, ['GET']);
  });
}
