/// HTTP client for direct Walrus storage node interaction.
///
/// Mirrors the TypeScript SDK's `StorageNodeClient` class from
/// `storage-node/client.ts`. Each instance targets a single storage
/// node and exposes methods for metadata and sliver read/write plus
/// confirmation retrieval.
///
/// Used by [WalrusDirectClient] in direct mode (Phase 3) to
/// distribute encoded slivers and collect storage confirmations.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors/walrus_errors.dart';
import '../models/storage_node_types.dart';
import '../utils/retry.dart';

/// Client for a single Walrus storage node's HTTP API.
///
/// Usage:
/// ```dart
/// final node = StorageNodeClient(
///   baseUrl: 'https://node-1.walrus-testnet.walrus.space',
/// );
///
/// // Write metadata + slivers
/// await node.storeBlobMetadata(blobId: blobId, metadata: metadataBytes);
/// await node.storeSliver(
///   blobId: blobId,
///   sliverPairIndex: 0,
///   sliverType: SliverType.primary,
///   sliver: sliverBytes,
/// );
///
/// // Get confirmation
/// final confirmation = await node.getPermanentBlobConfirmation(blobId: blobId);
/// ```
class StorageNodeClient {
  /// Base URL of the storage node API (e.g. `https://node.walrus.space`).
  final String baseUrl;

  /// HTTP request timeout.
  final Duration timeout;

  /// Number of retry attempts for failed requests.
  final int maxRetries;

  /// Delay between retries (doubled on each retry).
  final Duration retryDelay;

  /// Shared HTTP client – reused across requests for connection pooling.
  late final HttpClient _httpClient;

  StorageNodeClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.retryDelay = const Duration(milliseconds: 500),
    HttpClient? httpClient,
  }) {
    _httpClient = httpClient ?? HttpClient();
    // Only set timeouts when we own the client.
    // When a shared client is passed in, its timeouts are already configured.
    if (httpClient == null) {
      _httpClient.connectionTimeout = timeout;
      _httpClient.idleTimeout = const Duration(seconds: 15);
    }
  }

  /// Close the underlying HTTP client. Call when the node client is no longer
  /// needed to free sockets.
  void close() {
    _httpClient.close();
  }

  // -------------------------------------------------------------------------
  // Blob Metadata
  // -------------------------------------------------------------------------

  /// Retrieve blob metadata from this node.
  ///
  /// `GET /v1/blobs/{blobId}/metadata`
  ///
  /// Returns raw BCS-encoded metadata bytes.
  Future<Uint8List> getBlobMetadata({required String blobId}) async {
    final uri = _uri('/v1/blobs/$blobId/metadata');
    return _requestBytes('GET', uri);
  }

  /// Store blob metadata on this node.
  ///
  /// `PUT /v1/blobs/{blobId}/metadata`
  ///
  /// [metadata] is the BCS-encoded `BlobMetadataV1` bytes.
  ///
  /// Retries up to 3 times with 1 s delay if the node returns
  /// `BlobNotRegisteredError` (the on-chain registration may not have
  /// propagated to every node yet, matching the TS SDK behaviour).
  Future<void> storeBlobMetadata({
    required String blobId,
    required Uint8List metadata,
  }) async {
    final uri = _uri('/v1/blobs/$blobId/metadata');
    await retry<void>(
      () => _requestBytes('PUT', uri, body: metadata),
      count: 3,
      delay: const Duration(seconds: 1),
      condition: (e) => e is BlobNotRegisteredError,
    );
  }

  // -------------------------------------------------------------------------
  // Sliver Read / Write
  // -------------------------------------------------------------------------

  /// Retrieve a sliver from this node.
  ///
  /// `GET /v1/blobs/{blobId}/slivers/{sliverPairIndex}/{sliverType}`
  ///
  /// Returns raw sliver bytes.
  Future<Uint8List> getSliver({
    required String blobId,
    required int sliverPairIndex,
    required SliverType sliverType,
  }) async {
    final uri = _uri(
      '/v1/blobs/$blobId/slivers/$sliverPairIndex/${sliverType.value}',
    );
    return _requestBytes('GET', uri);
  }

  /// Store a sliver on this node.
  ///
  /// `PUT /v1/blobs/{blobId}/slivers/{sliverPairIndex}/{sliverType}`
  ///
  /// [sliver] is the raw sliver data bytes.
  Future<void> storeSliver({
    required String blobId,
    required int sliverPairIndex,
    required SliverType sliverType,
    required Uint8List sliver,
  }) async {
    final uri = _uri(
      '/v1/blobs/$blobId/slivers/$sliverPairIndex/${sliverType.value}',
    );
    await _requestBytes('PUT', uri, body: sliver);
  }

  // -------------------------------------------------------------------------
  // Confirmations
  // -------------------------------------------------------------------------

  /// Get a permanent blob confirmation from this node.
  ///
  /// `GET /v1/blobs/{blobId}/confirmation/permanent`
  ///
  /// Returns [StorageConfirmation] with the node's BLS signature.
  Future<StorageConfirmation> getPermanentBlobConfirmation({
    required String blobId,
  }) async {
    final uri = _uri('/v1/blobs/$blobId/confirmation/permanent');
    final body = await _requestString('GET', uri);
    final json = jsonDecode(body) as Map<String, dynamic>;
    // Navigate: { success: { code, data: { signed: { ... } } } }
    final signed = json['success']?['data']?['signed'] as Map<String, dynamic>?;
    if (signed == null) {
      throw FormatException('Unexpected confirmation response format: $body');
    }
    return StorageConfirmation.fromJson(signed);
  }

  /// Get a deletable blob confirmation from this node.
  ///
  /// `GET /v1/blobs/{blobId}/confirmation/deletable/{objectId}`
  ///
  /// Returns [StorageConfirmation] with the node's BLS signature.
  Future<StorageConfirmation> getDeletableBlobConfirmation({
    required String blobId,
    required String objectId,
  }) async {
    final uri = _uri('/v1/blobs/$blobId/confirmation/deletable/$objectId');
    final body = await _requestString('GET', uri);
    final json = jsonDecode(body) as Map<String, dynamic>;
    // Navigate: { success: { code, data: { signed: { ... } } } }
    final signed = json['success']?['data']?['signed'] as Map<String, dynamic>?;
    if (signed == null) {
      throw FormatException('Unexpected confirmation response format: $body');
    }
    return StorageConfirmation.fromJson(signed);
  }

  // -------------------------------------------------------------------------
  // Blob Status
  // -------------------------------------------------------------------------

  /// Get the status of a blob on this node.
  ///
  /// `GET /v1/blobs/{blobId}/status`
  Future<BlobStatus> getBlobStatus({required String blobId}) async {
    final uri = _uri('/v1/blobs/$blobId/status');
    final body = await _requestString('GET', uri);
    final json = jsonDecode(body);
    // Navigate: { success: { data: <status> } }
    dynamic data = json;
    if (json is Map && json['success'] is Map) {
      data = (json['success'] as Map)['data'];
    }
    return _parseBlobStatus(data);
  }

  BlobStatus _parseBlobStatus(dynamic json) {
    if (json is String) {
      if (json == 'nonexistent') return const BlobStatusNonexistent();
    }
    if (json is Map<String, dynamic>) {
      if (json.containsKey('invalid')) {
        final data = json['invalid'];
        return BlobStatusInvalid(
          event: data is Map<String, dynamic>
              ? data['event'] as Map<String, dynamic>?
              : null,
        );
      }
      if (json.containsKey('permanent')) {
        final data = json['permanent'] as Map<String, dynamic>;
        return BlobStatusPermanent(
          endEpoch: data['endEpoch'] as int,
          isCertified: data['isCertified'] as bool? ?? false,
          initialCertifiedEpoch: data['initialCertifiedEpoch'] as int?,
          deletableCounts: data['deletableCounts'] is Map<String, dynamic>
              ? DeletableCounts.fromJson(
                  data['deletableCounts'] as Map<String, dynamic>,
                )
              : null,
          statusEvent: data['statusEvent'] is Map<String, dynamic>
              ? StatusEvent.fromJson(
                  data['statusEvent'] as Map<String, dynamic>,
                )
              : null,
        );
      }
      if (json.containsKey('deletable')) {
        final data = json['deletable'] as Map<String, dynamic>;
        return BlobStatusDeletable(
          initialCertifiedEpoch: data['initialCertifiedEpoch'] as int?,
          deletableCounts: data['deletableCounts'] is Map<String, dynamic>
              ? DeletableCounts.fromJson(
                  data['deletableCounts'] as Map<String, dynamic>,
                )
              : null,
        );
      }
    }
    throw FormatException('Unknown blob status format: $json');
  }

  // -------------------------------------------------------------------------
  // Internal HTTP
  // -------------------------------------------------------------------------

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Uint8List> _requestBytes(
    String method,
    Uri uri, {
    Uint8List? body,
  }) async {
    // Retry loop with exponential backoff.
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final request = await _httpClient.openUrl(method, uri);
        request.headers.set('Content-Type', 'application/octet-stream');

        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        }

        final response = await request.close();
        final responseBytes = await _collectBytes(response);

        if (response.statusCode < 200 || response.statusCode >= 300) {
          final bodyText = utf8.decode(responseBytes, allowMalformed: true);
          throw StorageNodeApiError.fromResponse(
            statusCode: response.statusCode,
            responseBody: bodyText,
          );
        }

        return responseBytes;
      } catch (e) {
        lastError = e;
        // Only retry on connection / timeout errors, not API errors
        // (those are deterministic). BlobNotRegisteredError retries are
        // handled at a higher level (storeBlobMetadata).
        if (e is StorageNodeApiError) rethrow;
        if (attempt < maxRetries) {
          // Exponential backoff: delay * 2^attempt.
          final backoff = retryDelay * (1 << attempt);
          await Future<void>.delayed(backoff);
        }
      }
    }

    throw lastError ??
        StorageNodeConnectionError(
          'Request to $uri failed after $maxRetries retries',
        );
  }

  Future<String> _requestString(
    String method,
    Uri uri, {
    Uint8List? body,
  }) async {
    final bytes = await _requestBytes(method, uri, body: body);
    return utf8.decode(bytes);
  }

  Future<Uint8List> _collectBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  @override
  String toString() => 'StorageNodeClient(baseUrl: $baseUrl)';
}
