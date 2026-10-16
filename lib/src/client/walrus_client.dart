import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../cache/blob_cache.dart';
import '../logging/walrus_logging.dart';
import '../models/walrus_api_error.dart';
import '../network/request_executor.dart';
import '../utils/upload_policy.dart';

// Re-export logging types so consumers importing walrus_client.dart
// get WalrusLogLevel, WalrusLogger, etc. without a separate import.
export '../logging/walrus_logging.dart';

/// High-level Walrus API client for HTTP publisher/aggregator operations
/// with configurable logging via [WalrusLogger].
///
/// Logging is controlled through the [logger] property. Set a log level
/// at construction time, change it at runtime, or provide a custom handler:
///
/// ```dart
/// final client = WalrusClient(
///   publisherBaseUrl: publisherUrl,
///   aggregatorBaseUrl: aggregatorUrl,
///   logLevel: WalrusLogLevel.info,
/// );
///
/// // Adjust at runtime
/// client.logger.level = WalrusLogLevel.debug;
///
/// // Route to your own logging system
/// client.logger.onRecord = (record) {
///   myLogger.log(record.level.name, record.message);
/// };
/// ```
class WalrusClient {
  /// Configures a client with publisher and aggregator endpoints.
  ///
  /// [publisherBaseUrl] is only needed for uploads: a client without one
  /// reads from the aggregator, and its upload methods throw [StateError].
  /// (Apps where people pay with their own wallet store through
  /// `WalrusWriter` and only read through this client.)
  WalrusClient({
    Uri? publisherBaseUrl,
    required Uri aggregatorBaseUrl,
    this.timeout = const Duration(seconds: 30),
    Directory? cacheDirectory,
    int cacheMaxSize = 100,
    // Retained for source compatibility. The package:http path validates TLS
    // via the underlying platform (IOClient on native, the browser on web),
    // so this flag is now a no-op.
    bool useSecureConnection = false,
    String? jwtToken,
    http.Client? httpClient,
    WalrusLogLevel logLevel = WalrusLogLevel.none,
    WalrusLogHandler? onLog,
  }) : publisherBaseUrl = publisherBaseUrl == null
           ? null
           : _normalizeBaseUrl(publisherBaseUrl),
       aggregatorBaseUrl = _normalizeBaseUrl(aggregatorBaseUrl),
       cache = BlobCache(cacheDirectory: cacheDirectory, maxSize: cacheMaxSize),
       _jwtToken = jwtToken,
       _providedHttpClient = httpClient,
       logger = WalrusLogger(level: logLevel, onRecord: onLog) {
    if (cacheMaxSize <= 0) {
      throw ArgumentError('cacheMaxSize must be greater than zero');
    }

    _httpClient = httpClient ?? http.Client();
    _executor = RequestExecutor(_httpClient, timeout, onVerboseLog: logVerbose);
  }

  /// Where uploads go; null for a read-only client.
  final Uri? publisherBaseUrl;
  final Uri aggregatorBaseUrl;

  /// Maximum wait for response headers and maximum idle time between body
  /// events. Active streaming transfers can take longer than this duration.
  /// A stalled transfer throws [TimeoutException] and cancels its body stream.
  final Duration timeout;
  final BlobCache cache;

  /// Logger for this client. Configure [WalrusLogger.level] or
  /// [WalrusLogger.onRecord] to control output.
  final WalrusLogger logger;

  final http.Client? _providedHttpClient;
  late final http.Client _httpClient;
  late final RequestExecutor _executor;

  String? _jwtToken;

  /// The current log level. Shorthand for `logger.level`.
  WalrusLogLevel get logLevel => logger.level;

  /// Updates the log level. Shorthand for setting `logger.level`.
  void setLogLevel(WalrusLogLevel level) {
    if (logger.level == level) return;
    logger.level = level;
    logger.info('Log level changed to ${level.name.toUpperCase()}');
  }

  /// Emits an informational log when [logLevel] allows it.
  void logInfo(String message) => logger.info(message);

  /// Emits a verbose log.
  void logVerbose(String message) => logger.verbose(message);

  /// Emits a warning log.
  void logWarning(String message) => logger.warning(message);

  /// Emits an error log, optionally with [error] and [stackTrace] context.
  void logError(String message, {Object? error, StackTrace? stackTrace}) =>
      logger.error(message, error: error, stackTrace: stackTrace);

  /// Releases the underlying HTTP client and cache resources.
  ///
  /// The [force] flag is retained for source compatibility; `package:http`
  /// closes idle connections on [http.Client.close].
  Future<void> close({bool force = false}) async {
    if (_providedHttpClient == null) {
      _httpClient.close();
    }
    await cache.dispose();
  }

  /// Sets the default JWT token for authenticated requests.
  ///
  /// The [token] will be sent as `Authorization: Bearer {token}` on all
  /// subsequent requests unless overridden by a method-level `jwtToken` parameter.
  ///
  /// ```dart
  /// client.setJwtToken('your-jwt-token');
  /// await client.putBlob(data: bytes); // uses token
  /// await client.putBlob(data: bytes, jwtToken: 'other'); // override
  /// ```
  void setJwtToken(String token) {
    _jwtToken = token;
  }

  /// Clears the instance-level JWT token.
  ///
  /// Subsequent requests will be unauthenticated unless a method-level
  /// `jwtToken` parameter is provided.
  void clearJwtToken() {
    _jwtToken = null;
  }

  /// Uploads in-memory [data] to the Walrus publisher.
  ///
  /// Returns a JSON response containing the blob ID and metadata.
  ///
  /// Optional parameters:
  /// * [epochs]: Storage duration in epochs
  /// * [deletable]: Must be `true` or omitted; non-deletable uploads are rejected
  /// * [sendObjectTo]: SUI address to send the blob object
  /// * [jwtToken]: Per-call JWT override (overrides instance token)
  ///
  /// Throws [WalrusApiError] on network or server errors.
  ///
  /// ```dart
  /// final response = await client.putBlob(
  ///   data: imageBytes,
  ///   epochs: 10,
  ///   deletable: true,
  /// );
  /// final blobId = response['newlyCreated']['blobObject']['blobId'];
  /// ```
  Future<Map<String, dynamic>> putBlob({
    required Uint8List data,
    String? encodingType,
    int? epochs,
    bool? deletable,
    String? sendObjectTo,
    String? jwtToken,
  }) async {
    requireDeletableUpload(deletable);
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
    requireDeletableUpload(deletable);
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
    requireDeletableUpload(deletable);
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
    final uri = _aggregatorUri('v1/blobs/by-object-id/$objectId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final bytes = await _readBinaryResponse(
      response,
      context: 'Error retrieving blob by object ID: $objectId',
      cacheKey: null,
    );
    logInfo('Received ${bytes.length} bytes for object ID $objectId');
    return bytes;
  }

  /// Loads one file of a quilt by its quilt patch ID (as returned by
  /// `WalrusWriter.writeFiles`), from the cache or the aggregator's
  /// `/v1/blobs/by-quilt-patch-id/` route. A patch ID names fixed bytes, so
  /// results are cached like blobs.
  Future<Uint8List> getQuiltPatch(String patchId) async {
    final cached = await cache.get(patchId);
    if (cached != null) {
      logInfo('Cache hit for quilt patch $patchId');
      return cached;
    }
    final uri = _aggregatorUri('v1/blobs/by-quilt-patch-id/$patchId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final bytes = await _readBinaryResponse(
      response,
      context: 'Error retrieving quilt patch: $patchId',
      cacheKey: patchId,
    );
    logInfo('Fetched ${bytes.length} bytes for quilt patch $patchId');
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

  /// Streams a blob to [destination] without loading it into the byte cache.
  ///
  /// This method always reads from the aggregator and bypasses cache reads and
  /// writes to keep memory bounded. Use [getBlobAsFile] for cached downloads.
  /// The destination is replaced only after the complete download succeeds;
  /// failed downloads preserve an existing file; temporary cleanup is best effort.
  /// Existing symlinks must resolve to a regular file and are left intact.
  /// Replacement copies the old file once to preserve permission bits, requiring
  /// read access and temporary disk space. Unsupported permission preservation
  /// fails before replacement. Ownership, ACLs, and hard-link identity are not
  /// preserved. Same-filesystem replacement is atomic on POSIX; callers must
  /// prevent concurrent modifications of destination paths.
  Future<void> getBlobAsFileStreaming({
    required String blobId,
    required File destination,
  }) async {
    logInfo('Streaming $blobId to ${destination.path} without byte caching');

    final uri = _aggregatorUri('v1/blobs/$blobId');
    final response = await _executor.send(method: 'GET', uri: uri);
    final byteCount = await _readStreamingResponse(
      response,
      destination: destination,
      context: 'Error retrieving blob as file by blob ID: $blobId',
    );
    logInfo('Blob $blobId streamed to ${destination.path} ($byteCount bytes)');
  }

  /// Issues a `HEAD` request for [blobId] and returns the response headers.
  Future<Map<String, String>> getBlobMetadata(String blobId) async {
    logInfo('Fetching metadata for blob $blobId');
    final uri = _aggregatorUri('v1/blobs/$blobId');
    final response = await _executor.send(method: 'HEAD', uri: uri);

    if (!_isSuccessStatus(response.statusCode)) {
      final body = await response.stream.toBytes();
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: 'Error retrieving metadata for blob ID: $blobId',
        bodyBytes: body,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }
    await response.stream.drain<void>();
    final headers = Map<String, String>.from(response.headers);
    logInfo('Retrieved metadata for blob $blobId');
    return headers;
  }

  Uri _publisherUri(String path, {Map<String, String>? queryParameters}) {
    final publisher = publisherBaseUrl;
    if (publisher == null) {
      throw StateError(
        'This WalrusClient has no publisherBaseUrl, so it can only read. '
        'Pass one to upload through a publisher, or use WalrusWriter.',
      );
    }
    final resolved = publisher.resolveUri(Uri(path: path));
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
      'content-type': 'application/octet-stream',
    };

    final token = jwtToken ?? _jwtToken;
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
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
    requireDeletableUpload(deletable);
    params['deletable'] = 'true';
    if (sendObjectTo != null) {
      params['send_object_to'] = sendObjectTo;
    }
    return params;
  }

  Future<Uint8List> _readBinaryResponse(
    http.StreamedResponse response, {
    required String context,
    String? cacheKey,
  }) async {
    final bytes = await response.stream.toBytes();

    if (!_isSuccessStatus(response.statusCode)) {
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: context,
        bodyBytes: bytes,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }

    final data = bytes;
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

  Future<int> _readStreamingResponse(
    http.StreamedResponse response, {
    required File destination,
    required String context,
  }) async {
    if (!_isSuccessStatus(response.statusCode)) {
      // Limit diagnostic buffering too: error bodies can also be large.
      final builder = BytesBuilder(copy: false);
      const maxErrorBytes = 64 * 1024;
      await for (final chunk in response.stream) {
        final remaining = maxErrorBytes - builder.length;
        builder.add(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
        if (builder.length == maxErrorBytes) break;
      }
      throw _buildErrorFromResponse(
        statusCode: response.statusCode,
        context: context,
        bodyBytes: builder.takeBytes(),
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
      );
    }

    Directory? stagingDirectory;
    // Own the subscription before opening the file, so even an asynchronous
    // open failure cancels the body. StreamIterator pauses between chunks.
    final body = StreamIterator<List<int>>(response.stream);
    final firstChunk = body.moveNext();
    // Observe an early body failure while filesystem setup is pending. Awaiting
    // firstChunk below still propagates it; this prevents an unhandled error.
    unawaited(
      firstChunk.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      await destination.parent.create(recursive: true);
      final destinationType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      var target = destination;
      int? originalMode;
      if (destinationType != FileSystemEntityType.notFound) {
        if (destinationType != FileSystemEntityType.file &&
            destinationType != FileSystemEntityType.link) {
          throw FileSystemException(
            'Streaming destination must be a regular file or a link to one',
            destination.path,
          );
        }
        // Resolve links before choosing the staging parent, so the final
        // rename stays on the target filesystem and leaves the link intact.
        // Broken links fail here without replacing the link itself.
        target = File(await destination.resolveSymbolicLinks());
        final targetStat = await target.stat();
        if (targetStat.type != FileSystemEntityType.file) {
          throw FileSystemException(
            'Streaming destination must resolve to a regular file',
            destination.path,
          );
        }
        originalMode = targetStat.mode & 0xfff;
      }
      stagingDirectory = await target.parent.createTemp('.dartus-download-');
      final partial = File(
        '${stagingDirectory.path}${Platform.pathSeparator}blob',
      );
      if (originalMode != null) {
        // Dart has no portable chmod API. Copy the existing file's metadata,
        // then truncate only this private staging copy. Platforms that do not
        // preserve its permission bits fail safely before replacement.
        await target.copy(partial.path);
        if (((await partial.stat()).mode & 0xfff) != originalMode) {
          throw FileSystemException(
            'Cannot preserve streaming destination permissions',
            destination.path,
          );
        }
      }
      final file = await partial.open(mode: FileMode.write);
      var byteCount = 0;
      try {
        var hasNext = await firstChunk;
        while (hasNext) {
          final chunk = body.current;
          await file.writeFrom(chunk);
          byteCount += chunk.length;
          hasNext = await body.moveNext();
        }
        await file.flush();
      } finally {
        await file.close();
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          destinationType) {
        throw FileSystemException(
          'Streaming destination changed during download',
          destination.path,
        );
      }
      if (originalMode != null) {
        final resolvedPath = await destination.resolveSymbolicLinks();
        final partialMode = (await partial.stat()).mode & 0xfff;
        // Read the target's mode last, immediately before replacement, so a
        // permission change during the download is not silently reverted.
        final targetStat = await target.stat();
        if (resolvedPath != target.path ||
            targetStat.type != FileSystemEntityType.file ||
            (targetStat.mode & 0xfff) != originalMode ||
            partialMode != originalMode) {
          throw FileSystemException(
            'Streaming destination or permissions changed during download',
            destination.path,
          );
        }
      }
      // Never copy into the live destination: a disk/write error there would
      // destroy its previous contents. Same-filesystem rename is atomic on
      // POSIX. Callers must prevent concurrent changes to destination paths.
      await partial.rename(target.path);
      return byteCount;
    } finally {
      try {
        await body.cancel();
      } finally {
        if (stagingDirectory != null) {
          try {
            await stagingDirectory.delete(recursive: true);
          } catch (error, stackTrace) {
            // Cleanup is best effort; even a user-supplied logging callback
            // must not replace a successful download or its original error.
            try {
              logError(
                'Failed to remove staging directory ${stagingDirectory.path}',
                error: error,
                stackTrace: stackTrace,
              );
            } catch (_) {}
          }
        }
      }
    }
  }

  Future<Map<String, dynamic>> _parseJsonResponse(
    http.StreamedResponse response, {
    required String context,
  }) async {
    final bytes = await response.stream.toBytes();

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
    required Map<String, String> headers,
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
