@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/direct.dart';
import 'package:test/test.dart';

void main() {
  test('FFI rejects dimensions that would truncate at the native boundary', () {
    final ffi = WalrusFfiBindings.instance();
    for (final shards in [-1, 0, 65536, 65537]) {
      expect(
        () => ffi.computeMetadata(shards, Uint8List(0)),
        throwsArgumentError,
      );
      expect(() => ffi.encodeBlob(shards, Uint8List(0)), throwsArgumentError);
    }
    expect(() => ffi.encodingParams(4, -1), throwsArgumentError);
  });

  test(
    'direct uploads carry canonical metadata including every sliver hash',
    () {
      // Independent output from Mysten walrus-wasm 0.3.1, serialized with
      // @mysten/bcs using the official BlobMetadata schema.
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/native_metadata_wasm.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final data = Uint8List.fromList((fixture['data'] as List).cast<int>());
      final result = WalrusBlobEncoder().encodeBlob(
        data,
        fixture['numShards'] as int,
      );
      final expectedHex = fixture['metadataHex'] as String;
      final metadataHex = result.metadataBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(metadataHex, expectedHex);
      expect(result.blobIdBytes, fixture['blobId']);
      expect(result.rootHash, fixture['rootHash']);
      final parsed = parseBlobMetadataResponse(
        Uint8List.fromList([...result.blobIdBytes, ...result.metadataBytes]),
      );
      expect(parsed.unencodedLength, data.length);
      expect(result.primarySlivers, hasLength(4));
      expect(result.secondarySlivers, hasLength(4));
    },
  );
}
