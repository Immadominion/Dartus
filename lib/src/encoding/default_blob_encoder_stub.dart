import 'blob_encoder.dart';

/// No encoder is available on this platform.
BlobEncoder createDefaultBlobEncoder({Uri? wasmBaseUrl}) =>
    throw UnsupportedError(
      'Dartus has no blob encoder for this platform. Pass a BlobEncoder.',
    );
