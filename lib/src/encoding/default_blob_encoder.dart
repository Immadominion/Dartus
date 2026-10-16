/// The platform's default [BlobEncoder], chosen at compile time:
/// `walrus-wasm` in a Web Worker on the web, the native `walrus_ffi` library
/// elsewhere. On the web, `wasmBaseUrl` overrides where the `walrus-wasm`
/// files are served from (by default, Flutter's bundled package assets).
///
/// The native branch is the only place this barrel-safe library reaches
/// `dart:ffi`, and conditional imports keep it out of web builds.
library;

export 'default_blob_encoder_stub.dart'
    if (dart.library.js_interop) 'wasm_blob_encoder.dart'
    if (dart.library.ffi) 'default_blob_encoder_native.dart';
