import 'dart:async';
import 'dart:io';

class RequestExecutor {
  RequestExecutor(
    this._httpClient,
    this._timeout, {
    void Function(String message)? onVerboseLog,
  }) : _onVerboseLog = onVerboseLog;

  final HttpClient _httpClient;
  final Duration _timeout;
  final void Function(String message)? _onVerboseLog;

  Future<HttpClientResponse> send({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    List<int>? body,
    Stream<List<int>>? bodyStream,
  }) async {
    final request = await _httpClient.openUrl(method, uri);
    headers?.forEach(request.headers.set);

    if (body != null && bodyStream != null) {
      throw ArgumentError('Provide either body or bodyStream, not both.');
    }

    if (body != null) {
      request.add(body);
    } else if (bodyStream != null) {
      await request.addStream(bodyStream);
    }

    final String description = '${method.toUpperCase()} $uri';
    _onVerboseLog?.call('→ $description');
    final response = await request.close().timeout(_timeout);
    _onVerboseLog?.call('← ${response.statusCode} $description');
    return response;
  }
}
