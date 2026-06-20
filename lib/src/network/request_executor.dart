import 'dart:async';

import 'package:http/http.dart' as http;

/// Sends HTTP requests through `package:http`.
///
/// `package:http`'s default [http.Client] resolves to an `IOClient` on native
/// platforms and a `BrowserClient` on web, so the same code path runs in the
/// browser with no app-side changes.
class RequestExecutor {
  RequestExecutor(
    this._httpClient,
    this._timeout, {
    void Function(String message)? onVerboseLog,
  }) : _onVerboseLog = onVerboseLog;

  final http.Client _httpClient;
  final Duration _timeout;
  final void Function(String message)? _onVerboseLog;

  Future<http.StreamedResponse> send({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    List<int>? body,
    Stream<List<int>>? bodyStream,
  }) async {
    if (body != null && bodyStream != null) {
      throw ArgumentError('Provide either body or bodyStream, not both.');
    }

    final String description = '${method.toUpperCase()} $uri';
    _onVerboseLog?.call('→ $description');

    final http.BaseRequest request;
    if (bodyStream != null) {
      final streamed = http.StreamedRequest(method, uri);
      if (headers != null) streamed.headers.addAll(headers);
      // Pump the source stream into the request body, then close the sink.
      unawaited(
        bodyStream
            .forEach(streamed.sink.add)
            .then(
              (_) => streamed.sink.close(),
              onError: (Object error, StackTrace stackTrace) {
                streamed.sink.addError(error, stackTrace);
                streamed.sink.close();
              },
            ),
      );
      request = streamed;
    } else {
      final plain = http.Request(method, uri);
      if (headers != null) plain.headers.addAll(headers);
      if (body != null) plain.bodyBytes = body;
      request = plain;
    }

    final response = await _httpClient.send(request).timeout(_timeout);
    _onVerboseLog?.call('← ${response.statusCode} $description');
    return response;
  }
}
