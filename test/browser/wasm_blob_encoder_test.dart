@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:crypto/crypto.dart';
import 'package:dartus/dartus.dart';
import 'package:dartus/src/encoding/wasm_blob_encoder.dart'
    show WasmBlobEncoder;
import 'package:test/test.dart';

import '../support/blob_metadata_vectors.dart';

void main() {
  // The test runner only serves test/, so a hybrid VM helper serves the
  // vendored files; an app gets them from Flutter's asset bundle instead.
  late Uri assets;
  late BlobEncoder encoder;

  setUpAll(() async {
    final channel = spawnHybridUri('serve_wasm_assets.dart');
    assets = Uri.parse(await channel.stream.first as String);
    encoder = createDefaultBlobEncoder(wasmBaseUrl: assets);
  });

  for (final vector in blobMetadataVectors) {
    test('walrus-wasm metadata matches the TS SDK: ${vector.name}', () async {
      final data = vector.data();
      final metadata = await encoder.computeMetadata(data, blobMetadataShards);

      expect(metadata.blobId, vector.blobId);
      expect(hex(metadata.rootHash), vector.rootHashHex);
      expect(metadata.unencodedLength, data.length);
      expect(metadata.encodingType, 1);
      expect(metadata.blobDigest, sha256.convert(data).bytes);
      expect(metadata.nonce, hasLength(32));
    });
  }

  test('each call draws a fresh relay nonce', () async {
    final data = blobMetadataVectors.first.data();
    final a = await encoder.computeMetadata(data, blobMetadataShards);
    final b = await encoder.computeMetadata(data, blobMetadataShards);
    expect(a.nonce, isNot(b.nonce));
  });

  test(
    'wallet flow immutable bytes work with the worker and WebCrypto',
    () async {
      final vector = blobMetadataVectors.last;
      final data = vector.data().asUnmodifiableView();
      final metadata = await encoder.computeMetadata(data, blobMetadataShards);
      expect(metadata.blobId, vector.blobId);
      expect(hex(metadata.rootHash), vector.rootHashHex);
      expect(metadata.blobDigest, sha256.convert(data).bytes);
      expect(metadata.unencodedLength, data.length);
    },
  );

  test('the default encoder on the web is WasmBlobEncoder', () {
    expect(createDefaultBlobEncoder(), isA<WasmBlobEncoder>());
  });

  test('assets resolve against <base href>, not a deep route', () {
    final document = globalContext['document']! as JSObject;
    final history = globalContext['history']! as JSObject;
    final before = Uri.base.toString();
    final base = document.callMethod<JSObject>(
      'createElement'.toJS,
      'base'.toJS,
    )..['href'] = Uri.base.resolve('/app/').toString().toJS;
    (document['head']! as JSObject).callMethod<JSAny?>('prepend'.toJS, base);
    history.callMethodVarArgs<JSAny?>('pushState'.toJS, [
      null,
      ''.toJS,
      '/app/v/abc/manage'.toJS,
    ]);
    addTearDown(() {
      base.callMethod<JSAny?>('remove'.toJS);
      history.callMethodVarArgs<JSAny?>('replaceState'.toJS, [
        null,
        ''.toJS,
        before.toJS,
      ]);
    });

    expect(
      WasmBlobEncoder().baseUrl,
      Uri.base.resolve('/app/assets/packages/dartus/assets/walrus_wasm/'),
    );
  });

  test('an HTML page in place of the scripts fails instead of hanging', () {
    final spa = createDefaultBlobEncoder(wasmBaseUrl: assets.resolve('spa/'));
    expect(
      spa
          .computeMetadata(blobMetadataVectors.first.data(), 1000)
          .timeout(const Duration(seconds: 20)),
      throwsA(isA<StateError>()),
    );
  });

  test('a worker that never gets ready fails after the start timeout', () {
    final silent = WasmBlobEncoder(
      baseUrl: assets.resolve('silent/'),
      startTimeout: const Duration(seconds: 2),
    );
    expect(
      silent.computeMetadata(blobMetadataVectors.first.data(), 1000),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('did not start'),
        ),
      ),
    );
  });

  test('a worker that cannot start fails with a clear error', () {
    final broken = createDefaultBlobEncoder(
      wasmBaseUrl: assets.resolve('missing/'),
    );
    expect(
      broken.computeMetadata(blobMetadataVectors.first.data(), 1000),
      throwsA(isA<StateError>()),
    );
  });
}
