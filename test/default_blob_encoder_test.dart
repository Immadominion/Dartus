@TestOn('vm')
library;

import 'package:crypto/crypto.dart';
import 'package:dartus/dartus.dart';
import 'package:dartus/direct.dart' show WalrusBlobEncoder;
import 'package:test/test.dart';

import 'support/blob_metadata_vectors.dart';

void main() {
  final encoder = createDefaultBlobEncoder();

  test('the default encoder off the web is the native one', () {
    expect(encoder, isA<WalrusBlobEncoder>());
  });

  // test/browser/wasm_blob_encoder_test.dart checks the web encoder against
  // the same vectors, so both platforms register identical blob IDs.
  for (final vector in blobMetadataVectors) {
    test('native metadata matches the TS SDK: ${vector.name}', () async {
      final data = vector.data();
      final metadata = await encoder.computeMetadata(data, blobMetadataShards);

      expect(metadata.blobId, vector.blobId);
      expect(hex(metadata.rootHash), vector.rootHashHex);
      expect(metadata.unencodedLength, data.length);
      expect(metadata.blobDigest, sha256.convert(data).bytes);
      expect(metadata.nonce, hasLength(32));
    });
  }
}
