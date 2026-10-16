@TestOn('browser')
library;

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

  test('the default encoder on the web is WasmBlobEncoder', () {
    expect(createDefaultBlobEncoder(), isA<WasmBlobEncoder>());
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
