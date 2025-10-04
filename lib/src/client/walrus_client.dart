import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../cache/blob_cache.dart';
import '../models/walrus_api_error.dart';
import '../network/request_executor.dart';

enum WalrusLogLevel { none, basic, verbose }

enum _WalrusLogKind { info, verbose, warning, error }

/// High-level Walrus API client matching the Swift SDK surface area with
/// built-in console logging controlled through [WalrusLogLevel].
class WalrusClient {
  /// Configures a client with publisher and aggregator endpoints.
  WalrusClient({
    required Uri publisherBaseUrl,
    required Uri aggregatorBaseUrl,
    this.timeout = const Duration(seconds: 30),
    Directory? cacheDirectory,
    int cacheMaxSize = 100,
    bool useSecureConnection = false,
    String? jwtToken,
    HttpClient? httpClient,
    WalrusLogLevel logLevel = WalrusLogLevel.basic,
  }) : publisherBaseUrl = _normalizeBaseUrl(publisherBaseUrl),
       aggregatorBaseUrl = _normalizeBaseUrl(aggregatorBaseUrl),
       cache = BlobCache(cacheDirectory: cacheDirectory, maxSize: cacheMaxSize),
       _jwtToken = jwtToken,
       _useSecureConnection = useSecureConnection,
       _providedHttpClient = httpClient,
       _logLevel = logLevel {
    if (cacheMaxSize <= 0) {
      throw ArgumentError('cacheMaxSize must be greater than zero');
    }

    _httpClient = httpClient ?? HttpClient();
    if (httpClient == null && !_useSecureConnection) {
      _httpClient.badCertificateCallback = (_, __, ___) => true;
    }
    _executor = RequestExecutor(_httpClient, timeout, onVerboseLog: logVerbose);
  }

  final Uri publisherBaseUrl;
  final Uri aggregatorBaseUrl;
  final Duration timeout;
  final BlobCache cache;

  final bool _useSecureConnection;
  final HttpClient? _providedHttpClient;
  WalrusLogLevel _logLevel;
  late final HttpClient _httpClient;
  late final RequestExecutor _executor;

  String? _jwtToken;

  WalrusLogLevel get logLevel => _logLevel;

  /// Updates the log level for subsequent messages.
  void setLogLevel(WalrusLogLevel level) {
    if (_logLevel == level) {
      return;
    }
    _logLevel = level;
    logInfo('Log level changed to ${level.name.toUpperCase()}');
  }

  /// Emits an informational log when [logLevel] allows it.
  void logInfo(String message) {
    _log(_WalrusLogKind.info, message);
  }

  /// Emits a verbose log. Only printed when [logLevel] is [WalrusLogLevel.verbose].
  void logVerbose(String message) {
    _log(_WalrusLogKind.verbose, message);
  }

  /// Emits a warning log when [logLevel] is not [WalrusLogLevel.none].
  void logWarning(String message) {
    _log(_WalrusLogKind.warning, message);
  }

  /// Emits an error log, optionally with [error] and [stackTrace] context.
  void logError(String message, {Object? error, StackTrace? stackTrace}) {
    _log(_WalrusLogKind.error, message, error: error, stackTrace: stackTrace);
  }

  bool _shouldLog(_WalrusLogKind kind) {
    if (_logLevel == WalrusLogLevel.none) {
      return false;
    }
    if (_logLevel == WalrusLogLevel.basic && kind == _WalrusLogKind.verbose) {
      return false;
    }
    return true;
  }

  void _log(
    _WalrusLogKind kind,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_shouldLog(kind)) {
      return;
    }

    final timestamp = DateTime.now().toIso8601String();
    final levelLabel = switch (kind) {
      _WalrusLogKind.info => 'INFO',
      _WalrusLogKind.verbose => 'VERBOSE',
      _WalrusLogKind.warning => 'WARN',
      _WalrusLogKind.error => 'ERROR',
    };

    final buffer = StringBuffer('[$timestamp] Walrus $levelLabel: $message');
    if (error != null) {
      buffer.write(' → $error');
    }

    stdout.writeln(buffer.toString());
    if (stackTrace != null) {
      stdout.writeln(stackTrace);
    }
  }

  /// Releases the underlying HTTP client and cache resources.
  Future<void> close({bool force = false}) async {
    if (_providedHttpClient == null) {
      _httpClient.close(force: force);
    }
    await cache.dispose();
  }

  /// Sets the default JWT used for subsequent requests.
  void setJwtToken(String token) {
    _jwtToken = token;
  }

  /// Removes any stored JWT so requests become anonymous.
  void clearJwtToken() {
    _jwtToken = null;
  }

  /// Uploads in-memory [data] to `v1/blobs` and returns the Walrus response.
  Future<Map<String, dynamic>> putBlob({
    required Uint8List data,
    String? encodingType,
    int? epochs,
    bool? deletable,
    String? sendObjectTo,
    String? jwtToken,
  }) async {
    logInfo('Uploading ${data.lengthInBytes} bytes to Walrus');
    final uri = _publisherUri(
      'v1/blobs',
      queryParameters: _buildQueryParameters(
        epochs: epochs,
        deletable: deletable,
        sendObjectTo: sendObjectTo,
      ),
    );

    final response = await _executor.send(
      method: 'PUT',
      uri: uri,
      headers: _buildHeaders(jwtToken: jwtToken),
      body: data,
    );

    final result = await _parseJsonResponse(
      response,
      context: 'Error uploading blob',
    );
    logInfo('Upload completed with status ${response.statusCode}');
    return result;
  }

  /// Reads [file] and uploads its bytes via [putBlob].
  Future<Map<String, dynamic>> putBlobFromFile({
    required File file,
    String? encodingType,
    int? epochs,
    bool? deletable,
    String? sendObjectTo,
    String? jwtToken,
  }) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }

    logInfo('Uploading file ${file.path}');
    final bytes = await file.readAsBytes();
    return putBlob(
      data: Uint8List.fromList(bytes),
      encodingType: encodingType,
      epochs: epochs,
      deletable: deletable,
      sendObjectTo: sendObjectTo,
      jwtToken: jwtToken,
    );
  }

  /// Streams [file] contents to the publisher without loading everything into memory.
  Future<Map<String, dynamic>> putBlobStreaming({
    required File file,
    String? encodingType,
    int? epochs,
    bool? deletable,
    String? sendObjectTo,
    String? jwtToken,
  }) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }

    logInfo('Streaming upload for file ${file.path}');
    final uri = _publisherUri(
      'v1/blobs',
      queryParameters: _buildQueryParameters(
        epochs: epochs,
        deletable: deletable,
        sendObjectTo: sendObjectTo,
      ),
    );

    final response = await _executor.send(
      method: 'PUT',
      uri: uri,
      headers: _buildHeaders(jwtToken: jwtToken),
      bodyStream: file.openRead(),
    );

    final result = await _parseJsonResponse(
      response,
      context: 'Error uploading blob',
    );
    logInfo('Streaming upload completed with status ${response.statusCode}');
    return result;
  }

  /// Downloads a blob by Walrus object identifier without using the cache.
  Future<Uint8List> getBlobByObjectId(String objectId) async {
    logInfo('Fetching blob by object ID $objectId');
    final uri = _aggregatorUri('v1/blobs/$objectId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final bytes = await _readBinaryResponse(
      response,
      context: 'Error retrieving blob by object ID: $objectId',
      cacheKey: null,
    );
    logInfo('Received ${bytes.length} bytes for object ID $objectId');
    return bytes;
  }

  /// Loads a blob from the cache or aggregator, caching misses for reuse.
  Future<Uint8List> getBlob(String blobId) async {
    final cached = await cache.get(blobId);
    if (cached != null) {
      logInfo('Cache hit for $blobId');
      return cached;
    }
    logInfo('Cache miss for $blobId; fetching from aggregator');

    final uri = _aggregatorUri('v1/blobs/$blobId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final bytes = await _readBinaryResponse(
      response,
      context: 'Error retrieving blob by blob ID: $blobId',
      cacheKey: blobId,
    );
    logInfo('Fetched ${bytes.length} bytes for blob $blobId');
    return bytes;
  }

  /// Writes a blob to [destination], favouring cached bytes when available.
  Future<void> getBlobAsFile({
    required String blobId,
    required File destination,
  }) async {
    final cached = await cache.get(blobId);
    if (cached != null) {
      logInfo('Cache hit for $blobId; writing to ${destination.path}');
      await _writeBytesToFile(destination, cached);
      return;
    }
    logInfo('Cache miss for $blobId; downloading to ${destination.path}');

    final uri = _aggregatorUri('v1/blobs/$blobId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final bytes = await _readBinaryResponse(
      response,
      context: 'Error retrieving blob as file by blob ID: $blobId',
      cacheKey: blobId,
    );
    await _writeBytesToFile(destination, bytes);
    logInfo(
      'Blob $blobId saved to ${destination.path} (${bytes.length} bytes)',
    );
  }

  /// Streams a blob to [destination] and caches the final bytes.
  Future<void> getBlobAsFileStreaming({
    required String blobId,
    required File destination,
  }) async {
    final cached = await cache.get(blobId);
    if (cached != null) {
      logInfo('Cache hit for $blobId; writing to ${destination.path}');
      await _writeBytesToFile(destination, cached);
      return;
    }
    logInfo('Cache miss for $blobId; streaming to ${destination.path}');

    final uri = _aggregatorUri('v1/blobs/$blobId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final bytes = await _readStreamingResponse(
      response,
      destination: destination,
      context: 'Error retrieving blob as file by blob ID: $blobId',
    );
    try {
      await cache.put(blobId, bytes);
    } catch (error, stackTrace) {
      logError(
        'Failed to cache blob $blobId',
        error: error,
        stackTrace: stackTrace,
      );
    }
    logInfo(
      'Blob $blobId streamed to ${destination.path} (${bytes.length} bytes)',
    );
  }

  /// Issues a `HEAD` request for [blobId] and returns the response headers.
  Future<Map<String, String>> getBlobMetadata(String blobId) async {
    logInfo('Fetching metadata for blob $blobId');
    final uri = _aggregatorUri('v1/blobs/$blobId');
    final response = await _executor.send(method: 'HEAD', uri: uri);

    if (!_isSuccessStatus(response.statusCode)) {
      final body = await response.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        return acc;
      });
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: 'Error retrieving metadata for blob ID: $blobId',
        bodyBytes: body,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }

    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });
    logInfo('Retrieved metadata for blob $blobId');
    return headers;
  }

  Uri _publisherUri(String path, {Map<String, String>? queryParameters}) {
    final resolved = publisherBaseUrl.resolveUri(Uri(path: path));
    if (queryParameters == null || queryParameters.isEmpty) {
      return resolved;
    }
    return resolved.replace(queryParameters: queryParameters);
  }

  Uri _aggregatorUri(String path, {Map<String, String>? queryParameters}) {
    final resolved = aggregatorBaseUrl.resolveUri(Uri(path: path));
    if (queryParameters == null || queryParameters.isEmpty) {
      return resolved;
    }
    return resolved.replace(queryParameters: queryParameters);
  }

  Map<String, String> _buildHeaders({String? jwtToken}) {
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: 'application/octet-stream',
    };

    final token = jwtToken ?? _jwtToken;
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }

    return headers;
  }

  Map<String, String> _buildQueryParameters({
    int? epochs,
    bool? deletable,
    String? sendObjectTo,
  }) {
    final params = <String, String>{};
    if (epochs != null) {
      params['epochs'] = epochs.toString();
    }
    if (deletable != null) {
      params['deletable'] = deletable ? 'true' : 'false';
    }
    if (sendObjectTo != null) {
      params['send_object_to'] = sendObjectTo;
    }
    return params;
  }

  Future<Uint8List> _readBinaryResponse(
    HttpClientResponse response, {
    required String context,
    String? cacheKey,
  }) async {
    final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) {
      acc.addAll(chunk);
      return acc;
    });

    if (!_isSuccessStatus(response.statusCode)) {
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: context,
        bodyBytes: bytes,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }

    final data = Uint8List.fromList(bytes);
    if (cacheKey != null) {
      try {
        await cache.put(cacheKey, data);
      } catch (error, stackTrace) {
        logError(
          'Failed to cache blob $cacheKey',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return data;
  }

  Future<Uint8List> _readStreamingResponse(
    HttpClientResponse response, {
    required File destination,
    required String context,
  }) async {
    final builder = BytesBuilder(copy: false);

    if (!_isSuccessStatus(response.statusCode)) {
      final body = await response.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        return acc;
      });
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: context,
        bodyBytes: body,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }

    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    await response.forEach((chunk) {
      sink.add(chunk);
      builder.add(chunk);
    });
    await sink.close();

    return builder.takeBytes();
  }

  Future<Map<String, dynamic>> _parseJsonResponse(
    HttpClientResponse response, {
    required String context,
  }) async {
    final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) {
      acc.addAll(chunk);
      return acc;
    });

    if (!_isSuccessStatus(response.statusCode)) {
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: context,
        bodyBytes: bytes,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Fall through to error below.
    }

    throw WalrusApiError(
      code: 500,
      status: 'INVALID_RESPONSE',
      message: 'Failed to parse response JSON',
      context: context,
    );
  }

  WalrusApiError _buildErrorFromResponse({
    required int statusCode,
    required String context,
    required List<int> bodyBytes,
    required HttpHeaders headers,
    String? reasonPhrase,
  }) {
    if (bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(bodyBytes));
        if (decoded is Map<String, dynamic>) {
          final errorJson = decoded['error'];
          if (errorJson is Map<String, dynamic>) {
            final code = errorJson['code'] as int? ?? statusCode;
            final status = errorJson['status'] as String? ?? 'UNKNOWN';
            final message = errorJson['message'] as String? ?? '';
            final details = errorJson['details'];
            final error = WalrusApiError(
              code: code,
              status: status,
              message: message,
              details: details is List ? details : const <dynamic>[],
              context: context,
            );
            return _logAndReturnError(error, context);
          }
        }
      } catch (_) {
        // Ignore JSON parse failures.
      }
    }

    final status = statusCode >= 500 ? 'SERVER_ERROR' : 'CLIENT_ERROR';
    final message = reasonPhrase?.isNotEmpty == true
        ? reasonPhrase!
        : 'HTTP $statusCode';
    final error = WalrusApiError(
      code: statusCode,
      status: status,
      message: message,
      context: context,
    );
    return _logAndReturnError(error, context);
  }

  bool _isSuccessStatus(int statusCode) =>
      statusCode >= 200 && statusCode < 300;

  static Uri _normalizeBaseUrl(Uri uri) {
    if (!uri.hasScheme) {
      throw ArgumentError('Base URL must include a scheme');
    }
    if (!uri.hasAuthority) {
      throw ArgumentError('Base URL must include a host');
    }

    final normalizedPath = uri.path.isEmpty
        ? '/'
        : (uri.path.endsWith('/') ? uri.path : '${uri.path}/');
    return uri.replace(path: normalizedPath, query: null, fragment: null);
  }

  WalrusApiError _logAndReturnError(WalrusApiError error, String context) {
    final message = error.message;
    logError(
      'Request failed: $context (status ${error.code})',
      error: message.isNotEmpty ? message : null,
    );
    return error;
  }

  Future<void> _writeBytesToFile(File destination, Uint8List bytes) async {
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      await destination.delete();
    }
    await destination.writeAsBytes(bytes, flush: true);
  }
}
