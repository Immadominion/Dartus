/// HTTP client for the Walrus Upload Relay.
///
/// The upload relay accepts raw blob data, handles erasure coding
/// server-side, distributes slivers to storage nodes, and returns
/// a [ProtocolMessageCertificate] for on-chain certification.
///
/// Built on `package:http`, so it works on the Dart VM, Flutter mobile and
/// desktop, and Flutter web. Mirrors the TS SDK's `UploadRelayClient` class.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../errors/walrus_errors.dart';
import '../models/protocol_types.dart';
import '../network/request_executor.dart';
import '../utils/upload_policy.dart';

/// Client for interacting with a Walrus Upload Relay.
///
/// Usage:
/// ```dart
/// final relay = UploadRelayClient(
///   host: 'https://upload-relay.testnet.walrus.space',
/// );
///
/// final tipConfig = await relay.tipConfig();
/// final result = await relay.writeBlob(
///   blobId: metadata.blobId,
///   blob: rawData,
///   nonce: metadata.nonce,
///   txDigest: registerDigest,
///   blobObjectId: blobObjectId,
///   deletable: true,
///   requiresTip: tipConfig != null,
/// );
/// // result.certificate → use in certifyBlobTransaction
/// ```
///
/// Pass your own [http.Client] to observe upload progress (for example an
/// `XMLHttpRequest`-based client on the web). A client you pass is never
/// closed by [close].
class UploadRelayClient {
  /// Base URL of the upload relay, without a trailing slash.
  final String host;

  /// How long to wait for response headers, and then for each chunk of the
  /// response body. The upload itself is not limited.
  final Duration timeout;

  /// Optional error callback, called before an error is thrown.
  final void Function(Object error)? onError;

  final http.Client? _providedHttpClient;
  final http.Client _httpClient;
  final RequestExecutor _executor;

  /// Cached tip configuration, loaded lazily.
  UploadRelayTipConfig? _cachedTipConfig;
  bool _tipConfigLoaded = false;

  UploadRelayClient({
    required String host,
    Duration timeout = const Duration(seconds: 120),
    void Function(Object error)? onError,
    http.Client? httpClient,
  }) : this._(host, httpClient, httpClient ?? http.Client(), timeout, onError);

  UploadRelayClient._(
    String host,
    this._providedHttpClient,
    this._httpClient,
    this.timeout,
    this.onError,
  ) : host = host.endsWith('/') ? host.substring(0, host.length - 1) : host,
      _executor = RequestExecutor(_httpClient, timeout);

  /// Closes the HTTP client this relay client created. A client passed to
  /// the constructor is left open.
  void close() {
    if (_providedHttpClient == null) _httpClient.close();
  }

  // -------------------------------------------------------------------------
  // Tip Config
  // -------------------------------------------------------------------------

  /// Fetch the relay's tip configuration.
  ///
  /// Returns `null` if the relay does not require a tip (`"no_tip"` response).
  ///
  /// The result is cached after the first successful fetch.
  ///
  /// Corresponds to TS SDK's `UploadRelayClient.tipConfig()`.
  Future<UploadRelayTipConfig?> tipConfig() async {
    if (_tipConfigLoaded) return _cachedTipConfig;

    final body = await _request('GET', Uri.parse('$host/v1/tip-config'));
    _cachedTipConfig = UploadRelayTipConfig.fromRelayResponse(jsonDecode(body));
    _tipConfigLoaded = true;
    return _cachedTipConfig;
  }

  // -------------------------------------------------------------------------
  // Write Blob
  // -------------------------------------------------------------------------

  /// Upload raw blob data to the relay for encoding and distribution.
  ///
  /// The relay:
  /// 1. Erasure-codes the blob
  /// 2. Distributes slivers to storage nodes
  /// 3. Collects confirmations
  /// 4. Returns a [ProtocolMessageCertificate]
  ///
  /// Query parameters match the TS SDK's `UploadRelayClient.writeBlob()`:
  /// - `blob_id` (required)
  /// - `nonce` (URL-safe base64, when tip is required)
  /// - `tx_id` (transaction digest, when tip is required)
  /// - `deletable_blob_object` (Sui object ID, when deletable)
  /// - `encoding_type` (optional)
  ///
  /// Returns the blob ID and certificate for certification.
  Future<UploadRelayWriteResult> writeBlob({
    required String blobId,
    required Uint8List blob,
    required Uint8List nonce,
    required String txDigest,
    required String blobObjectId,
    required bool deletable,
    bool requiresTip = false,
    String? encodingType,
  }) async {
    requireDeletableUpload(deletable);
    final uri = Uri.parse('$host/v1/blob-upload-relay').replace(
      queryParameters: {
        'blob_id': blobId,
        if (requiresTip) 'nonce': _urlSafeBase64Encode(nonce),
        if (requiresTip) 'tx_id': txDigest,
        if (deletable) 'deletable_blob_object': blobObjectId,
        'encoding_type': ?encodingType,
      },
    );

    final body = await _request('POST', uri, body: blob);

    // {"blob_id": [..], "confirmation_certificate": {"signers": [..],
    //  "serialized_message": [..], "signature": "<url-safe base64>"}}
    final data = jsonDecode(body) as Map<String, dynamic>;
    final certificate = ProtocolMessageCertificate.fromJson(
      data['confirmation_certificate'] as Map<String, dynamic>,
    );
    return UploadRelayWriteResult(blobId: blobId, certificate: certificate);
  }

  // -------------------------------------------------------------------------
  // Internal HTTP
  // -------------------------------------------------------------------------

  Future<String> _request(String method, Uri uri, {Uint8List? body}) async {
    try {
      final response = await _executor.send(
        method: method,
        uri: uri,
        headers: body == null
            ? null
            : const {'Content-Type': 'application/octet-stream'},
        body: body,
      );
      final text = await response.stream.bytesToString();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UploadRelayError(
          statusCode: response.statusCode,
          body: text,
          uri: uri,
        );
      }
      return text;
    } catch (error) {
      onError?.call(error);
      rethrow;
    }
  }

  /// URL-safe base64 encoding (no padding, +/ replaced with -_).
  static String _urlSafeBase64Encode(Uint8List data) =>
      base64Url.encode(data).replaceAll('=', '');
}

/// Result of a successful upload relay write operation.
class UploadRelayWriteResult {
  /// The Walrus blob ID.
  final String blobId;

  /// Certificate proving storage by a quorum of nodes.
  final ProtocolMessageCertificate certificate;

  const UploadRelayWriteResult({
    required this.blobId,
    required this.certificate,
  });

  @override
  String toString() => 'UploadRelayWriteResult(blobId: $blobId)';
}
