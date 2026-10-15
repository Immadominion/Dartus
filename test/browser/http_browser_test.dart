@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public HTTP API uploads, reads, and caches bytes in the browser',
    () async {
      final bytes = Uint8List.fromList(utf8.encode('Dartus browser smoke'));
      final requests = <String>[];
      final transport = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'PUT') {
          expect(request.url.path, '/v1/blobs');
          expect(request.url.queryParameters['deletable'], 'true');
          expect(request.bodyBytes, bytes);
          return http.Response(
            jsonEncode({
              'newlyCreated': {
                'blobObject': {'blobId': 'browser-blob'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/blobs/browser-blob');
        return http.Response.bytes(bytes, 200);
      });
      final client = WalrusClient(
        publisherBaseUrl: Uri.parse('https://publisher.invalid'),
        aggregatorBaseUrl: Uri.parse('https://aggregator.invalid'),
        httpClient: transport,
      );
      addTearDown(client.close);
      addTearDown(transport.close);

      final uploaded = await client.putBlob(data: bytes, deletable: true);
      expect(uploaded['newlyCreated'], {
        'blobObject': {'blobId': 'browser-blob'},
      });
      expect(await client.getBlob('browser-blob'), bytes);
      expect(await client.getBlob('browser-blob'), bytes);
      expect(requests, ['PUT /v1/blobs', 'GET /v1/blobs/browser-blob']);
      expect(await client.cache.get('browser-blob'), bytes);
    },
  );
}
