import 'dart:async';
import 'dart:io';

/// All default tests must use fixtures, mocks, or a local HTTP server.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (const bool.fromEnvironment('dart.library.io')) {
    // The test runner executes registered tests after testMain returns.
    // Keep the guard for this test isolate's lifetime, not just registration.
    HttpOverrides.global = _LoopbackOnlyHttp();
  }
  await testMain();
}

class _LoopbackOnlyHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (!_isLoopback(uri.host) ||
          (proxyHost != null && !_isLoopback(proxyHost))) {
        return Future<ConnectionTask<Socket>>.error(
          StateError(
            'External network disabled in test/: $uri. '
            'Use a mock or put the explicit live check in live_test/.',
          ),
        );
      }
      return Socket.startConnect(proxyHost ?? uri.host, proxyPort ?? uri.port);
    };
    return client;
  }

  bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
