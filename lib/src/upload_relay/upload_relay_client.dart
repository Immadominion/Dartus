/// HTTP client for the Walrus Upload Relay.
///
/// The upload relay accepts raw blob data, handles erasure coding
/// server-side, distributes slivers to storage nodes, and returns
/// a [ProtocolMessageCertificate] for on-chain certification.
///
/// Mirrors the TS SDK's `UploadRelayClient` class.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/protocol_types.dart';

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
///   requiresTip: true,
/// );
/// // result.certificate → use in certifyBlobTransaction
/// ```
class UploadRelayClient {
  /// Base URL of the upload relay.
  final String host;

  /// HTTP request timeout.
  final Duration timeout;

  /// Optional error callback.
  final void Function(Object error)? onError;

  /// Cached tip configuration, loaded lazily.
  UploadRelayTipConfig? _cachedTipConfig;
  bool _tipConfigLoaded = false;

  UploadRelayClient({
    required this.host,
    this.timeout = const Duration(seconds: 120),
    this.onError,
  });

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

    final uri = Uri.parse('$host/v1/tip-config');
    final response = await _request('GET', uri);

    final body = jsonDecode(response);
    _cachedTipConfig = UploadRelayTipConfig.fromRelayResponse(body);
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
    final query = <String, String>{'blob_id': blobId};

    if (requiresTip) {
      query['nonce'] = _urlSafeBase64Encode(nonce);
      query['tx_id'] = txDigest;
    }

    if (deletable) {
      query['deletable_blob_object'] = blobObjectId;
    }

    if (encodingType != null) {
      query['encoding_type'] = encodingType;
    }

    final queryString = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    final uri = Uri.parse('$host/v1/blob-upload-relay?$queryString');
    final responseBody = await _request('POST', uri, body: blob);

    final data = jsonDecode(responseBody) as Map<String, dynamic>;

    // Parse response matching TS SDK structure:
    // {
    //   "blob_id": [byte, byte, ...],
    //   "confirmation_certificate": {
    //     "signers": [...],
    //     "serialized_message": [...],
    //     "signature": "<base64>"
    //   }
    // }
    final certJson = data['confirmation_certificate'] as Map<String, dynamic>;
    final certificate = ProtocolMessageCertificate.fromJson(certJson);

    return UploadRelayWriteResult(blobId: blobId, certificate: certificate);
  }

  // -------------------------------------------------------------------------
  // Internal HTTP
  // -------------------------------------------------------------------------

  Future<String> _request(String method, Uri uri, {Uint8List? body}) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;

    try {
      final request = await client.openUrl(method, uri);
      request.headers.set('Content-Type', 'application/octet-stream');

      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = Exception(
          'Upload relay error ${response.statusCode}: $responseBody',
        );
        onError?.call(error);
        throw error;
      }

      return responseBody;
    } catch (e) {
      onError?.call(e);
      rethrow;
    } finally {
      client.close();
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// URL-safe base64 encoding (no padding, +/ replaced with -_).
  static String _urlSafeBase64Encode(Uint8List data) {
    final base64 = base64Encode(data);
    return base64.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  }
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
