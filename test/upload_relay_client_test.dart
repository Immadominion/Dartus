import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('tip config', () {
    Future<UploadRelayTipConfig?> parse(Object body) => UploadRelayClient(
      host: 'https://relay.test/',
      httpClient: MockClient((_) async => http.Response(jsonEncode(body), 200)),
    ).tipConfig();

    test('a constant tip is the same for every size', () async {
      final tip = await parse({
        'send_tip': {
          'address': '0xabc',
          'kind': {'const': 105},
        },
      });
      expect(tip!.address, '0xabc');
      expect(tip.calculateTip(1), BigInt.from(105));
      expect(tip.calculateTip(1 << 30), BigInt.from(105));
    });

    test('a linear tip is priced per started KiB of encoded size', () async {
      final tip = await parse({
        'send_tip': {
          'address': '0xabc',
          'kind': {
            'linear': {'base': 10, 'encoded_size_mul_per_kib': 40},
          },
        },
      });
      // 1 MiB encodes to 70,038,000 bytes on 1000 shards: 68,397 KiB.
      expect(tip!.calculateTip(70038000), BigInt.from(10 + 40 * 68397));
      expect(tip.calculateTip(1024), BigInt.from(50));
      expect(tip.calculateTip(1025), BigInt.from(90));
    });

    test('"no_tip" means no tip', () async {
      expect(await parse('no_tip'), isNull);
    });

    test('a tip above the caller\'s maximum is refused, not capped', () {
      final tip = UploadRelayTipConfig(
        address: '0xabc',
        kind: ConstTipStrategy(amount: BigInt.from(105)),
        max: BigInt.from(100),
      );
      expect(() => tip.calculateTip(1), throwsArgumentError);
    });

    test('is fetched once', () async {
      var calls = 0;
      final relay = UploadRelayClient(
        host: 'https://relay.test',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('"no_tip"', 200);
        }),
      );
      await relay.tipConfig();
      await relay.tipConfig();
      expect(calls, 1);
    });
  });

  group('writeBlob', () {
    final certificate = {
      'signers': [0, 2, 5],
      'serialized_message': [1, 2, 3],
      // URL-safe base64 without padding, as the relay sends it.
      'signature': base64Url
          .encode(List<int>.filled(96, 251))
          .replaceAll('=', ''),
    };

    test('sends the bytes with the relay\'s query parameters', () async {
      late http.Request sent;
      final relay = UploadRelayClient(
        host: 'https://relay.test',
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'blob_id': <int>[],
              'confirmation_certificate': certificate,
            }),
            200,
          );
        }),
      );
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final result = await relay.writeBlob(
        blobId: 'blob-id',
        blob: bytes,
        nonce: Uint8List.fromList(List.filled(32, 255)),
        txDigest: 'digest',
        blobObjectId: '0xb10b',
        deletable: true,
        requiresTip: true,
        encodingType: 'RS2',
      );

      expect(sent.method, 'POST');
      expect(sent.url.path, '/v1/blob-upload-relay');
      expect(sent.url.queryParameters, {
        'blob_id': 'blob-id',
        'nonce': '_' * 42 + '8',
        'tx_id': 'digest',
        'deletable_blob_object': '0xb10b',
        'encoding_type': 'RS2',
      });
      expect(sent.headers['Content-Type'], 'application/octet-stream');
      expect(sent.bodyBytes, bytes);

      expect(result.certificate.signers, [0, 2, 5]);
      expect(result.certificate.serializedMessage, [1, 2, 3]);
      expect(result.certificate.signature, List<int>.filled(96, 251));
    });

    test('leaves out tip and object parameters when not needed', () async {
      late Uri sent;
      final relay = UploadRelayClient(
        host: 'https://relay.test',
        httpClient: MockClient((request) async {
          sent = request.url;
          return http.Response(
            jsonEncode({'confirmation_certificate': certificate}),
            200,
          );
        }),
      );
      await relay.writeBlob(
        blobId: 'blob-id',
        blob: Uint8List(1),
        nonce: Uint8List(32),
        txDigest: 'digest',
        blobObjectId: '0xb10b',
        deletable: false,
      );
      expect(sent.queryParameters, {'blob_id': 'blob-id'});
    });

    test('a refusal becomes an UploadRelayError with the reason', () async {
      Object? reported;
      final relay = UploadRelayClient(
        host: 'https://relay.test',
        onError: (error) => reported = error,
        httpClient: MockClient(
          (_) async => http.Response('tip not found in transaction', 400),
        ),
      );
      final call = relay.writeBlob(
        blobId: 'blob-id',
        blob: Uint8List(1),
        nonce: Uint8List(32),
        txDigest: 'digest',
        blobObjectId: '0xb10b',
        deletable: true,
      );
      await expectLater(
        call,
        throwsA(
          isA<UploadRelayError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.body, 'body', 'tip not found in transaction'),
        ),
      );
      expect(reported, isA<UploadRelayError>());
    });
  });

  test('close leaves a client it was given open', () async {
    var closed = false;
    final client = _ClosingClient(() => closed = true);
    UploadRelayClient(host: 'https://relay.test', httpClient: client).close();
    expect(closed, isFalse);
  });
}

class _ClosingClient extends http.BaseClient {
  _ClosingClient(this.onClose);

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => onClose();
}
