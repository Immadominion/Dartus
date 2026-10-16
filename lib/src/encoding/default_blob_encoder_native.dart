import 'blob_encoder.dart';
import 'walrus_blob_encoder.dart';

/// The platform's default [BlobEncoder]: the native `walrus_ffi` library
/// (see `WalrusFfiBindings.configure`). [wasmBaseUrl] only applies on the web.
BlobEncoder createDefaultBlobEncoder({Uri? wasmBaseUrl}) => WalrusBlobEncoder();
