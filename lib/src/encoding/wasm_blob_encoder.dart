/// Blob metadata for Flutter web, computed by Mysten's `walrus-wasm` in a
/// Web Worker.
///
/// Only imported on the web (see `default_blob_encoder.dart`).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import '../models/protocol_types.dart';
import '../utils/blob_id_utils.dart';
import '../utils/encoding_utils.dart' show kEncodingTypeRS2;
import 'blob_encoder.dart';

/// Where Flutter web serves the `walrus-wasm` files bundled with Dartus,
/// relative to the document's base URL (`<base href>` in Flutter's
/// `index.html`), not the current route.
const defaultWalrusWasmPath = 'assets/packages/dartus/assets/walrus_wasm/';

/// The platform's default [BlobEncoder]: [WasmBlobEncoder] on the web,
/// loading its files from [wasmBaseUrl] when given.
BlobEncoder createDefaultBlobEncoder({Uri? wasmBaseUrl}) =>
    WasmBlobEncoder(baseUrl: wasmBaseUrl);

/// Computes blob metadata in the browser with `walrus-wasm` (the encoder the
/// TypeScript SDK uses), so the blob ID matches every other Walrus client.
///
/// The work runs in a module Web Worker: hashing takes about a second for a
/// small file and several seconds for 100 MB, which would otherwise freeze
/// the page. The worker starts on first use and is shared by every encoder
/// with the same [baseUrl].
///
/// [baseUrl] is the folder holding `walrus_wasm.js`, `walrus_wasm_bg.wasm`
/// and `walrus_metadata_worker.js`. It defaults to the copies Flutter bundles
/// with Dartus; it may be on another origin if that origin allows CORS.
class WasmBlobEncoder extends BlobEncoder {
  WasmBlobEncoder({Uri? baseUrl})
    : baseUrl =
          baseUrl ?? Uri.parse(_documentBaseUri).resolve(defaultWalrusWasmPath);

  final Uri baseUrl;

  static final _workers = <String, _MetadataWorker>{};

  _MetadataWorker get _worker {
    final url = baseUrl.resolve('walrus_metadata_worker.js').toString();
    final existing = _workers[url];
    if (existing != null && !existing.failed) return existing;
    return _workers[url] = _MetadataWorker(url);
  }

  @override
  Future<BlobMetadata> computeMetadata(Uint8List data, int numShards) async {
    final (blobId, rootHash) = await _worker.compute(data, numShards);
    return BlobMetadata(
      blobId: blobIdFromBytes(blobId),
      rootHash: rootHash,
      unencodedLength: data.length,
      encodingType: kEncodingTypeRS2,
      nonce: _randomBytes(32),
      blobDigest: await _sha256(data),
    );
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// SHA-256 through WebCrypto, which is far faster than hashing a large
  /// file in compiled Dart.
  static Future<Uint8List> _sha256(Uint8List data) async {
    final digest = await _subtle.digest('SHA-256', data.toJS).toDart;
    return digest.toDart.asUint8List();
  }
}

/// One module worker running `walrus_metadata_worker.js`.
class _MetadataWorker {
  _MetadataWorker(String scriptUrl) : _worker = _spawn(scriptUrl) {
    _worker.onmessage = _onMessage.toJS;
    _worker.onerror = _onError.toJS;
  }

  final _Worker _worker;
  final _pending = <int, Completer<(Uint8List, Uint8List)>>{};
  var _nextId = 0;

  /// Set when the worker could not start (bad URL, CSP, network). The next
  /// encoder call spawns a fresh worker.
  bool failed = false;

  /// A module worker must be same-origin, so start it from a one-line
  /// `blob:` module that imports the real script. That also lets the assets
  /// live on a CDN, and relative imports inside the script keep resolving
  /// against its own URL.
  static _Worker _spawn(String scriptUrl) {
    final source = 'import ${_jsString(scriptUrl)};';
    final blob = _Blob(
      [source.toJS].toJS,
      _BlobOptions(type: 'text/javascript'),
    );
    return _Worker(_Url.createObjectURL(blob), _WorkerOptions(type: 'module'));
  }

  static String _jsString(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  Future<(Uint8List, Uint8List)> compute(Uint8List data, int numShards) {
    final id = _nextId++;
    final completer = _pending[id] = Completer();
    // Transfer a copy, so the caller's bytes stay usable.
    final buffer = Uint8List.fromList(data).buffer.toJS;
    final message = JSObject()
      ..['id'] = id.toJS
      ..['nShards'] = numShards.toJS
      ..['bytes'] = buffer;
    _worker.postMessage(message, [buffer].toJS);
    return completer.future;
  }

  void _onMessage(_MessageEvent event) {
    final data = event.data;
    final id = (data['id']! as JSNumber).toDartInt;
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = data['error'];
    if (error != null) {
      completer.completeError(
        StateError('walrus-wasm failed: ${(error as JSString).toDart}'),
      );
      return;
    }
    final type = (data['type']! as JSString).toDart;
    if (type != 'RS2') {
      completer.completeError(
        StateError('walrus-wasm returned encoding $type, not RS2'),
      );
      return;
    }
    completer.complete((
      (data['blobId']! as JSUint8Array).toDart,
      (data['rootHash']! as JSUint8Array).toDart,
    ));
  }

  void _onError(_ErrorEvent event) {
    failed = true;
    _worker.terminate();
    final reason = event.message;
    final error = StateError(
      'Could not run the walrus-wasm worker'
      '${reason == null || reason.isEmpty ? '' : ': $reason'}',
    );
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }
}

// --- Minimal browser bindings (no package:web dependency) -------------------

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url, _WorkerOptions options);
  external void postMessage(JSAny? message, JSArray<JSAny> transfer);
  external set onmessage(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external void terminate();
}

extension type _WorkerOptions._(JSObject _) implements JSObject {
  external factory _WorkerOptions({String type});
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSObject get data;
}

extension type _ErrorEvent._(JSObject _) implements JSObject {
  external String? get message;
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSString> parts, _BlobOptions options);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

@JS('URL')
extension type _Url._(JSObject _) implements JSObject {
  external static String createObjectURL(_Blob blob);
}

/// Flutter's assets are relative to `<base href>`; `Uri.base` is the page's
/// full URL, which on a deep route like `/v/abc/manage` points elsewhere.
@JS('document.baseURI')
external String get _documentBaseUri;

@JS('crypto.subtle')
external _SubtleCrypto get _subtle;

extension type _SubtleCrypto._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> digest(String algorithm, JSAny data);
}
