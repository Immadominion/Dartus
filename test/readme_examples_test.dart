import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../tool/quickstart_examples.dart' as native_example;
import '../tool/quickstart_http.dart' as http_example;

void main() {
  for (final alreadyCertified in [false, true]) {
    test(
      'README HTTP example reads uploaded bytes ($alreadyCertified)',
      () async {
        final bytes = Uint8List.fromList([1, 2, 3]);
        var puts = 0;
        var gets = 0;
        final httpClient = MockClient((request) async {
          if (request.method == 'PUT') {
            puts++;
            expect(request.url.path, '/v1/blobs');
            expect(request.url.queryParameters['deletable'], 'true');
            expect(request.bodyBytes, bytes);
            return http.Response(
              jsonEncode(
                alreadyCertified
                    ? {
                        'alreadyCertified': {'blobId': 'example-blob'},
                      }
                    : {
                        'newlyCreated': {
                          'blobObject': {'blobId': 'example-blob'},
                        },
                      },
              ),
              200,
            );
          }
          gets++;
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/blobs/example-blob');
          return http.Response.bytes(bytes, 200);
        });
        final client = WalrusClient(
          publisherBaseUrl: Uri.parse('https://publisher.example'),
          aggregatorBaseUrl: Uri.parse('https://aggregator.example'),
          httpClient: httpClient,
        );
        addTearDown(() async {
          await client.close();
          httpClient.close();
        });

        expect(await http_example.uploadAndRead(client, bytes), bytes);
        expect(puts, 1);
        expect(gets, 1);
      },
    );
  }

  test('README file example uses the real named-argument API', () async {
    final file = native_example.createTextFile();
    expect(await file.getIdentifier(), 'hello.txt');
    expect(await file.text(), 'Hello, World!');
    expect(await file.getTags(), {'type': 'text'});
  });
}
