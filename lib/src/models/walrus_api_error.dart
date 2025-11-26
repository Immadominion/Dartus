import 'package:meta/meta.dart';

/// An error returned by the Walrus API or encountered during a request.
///
/// All Dartus methods throw [WalrusApiError] when requests fail. The error
/// contains structured information about what went wrong and where.
///
/// ## Fields
///
/// * [code]: HTTP status code (e.g., `404`, `500`) or API-specific error code
/// * [status]: Error category like `CLIENT_ERROR`, `SERVER_ERROR`, or server-provided value
/// * [message]: Human-readable description of the error
/// * [details]: Optional array of additional error details from the server
/// * [context]: Describes which operation failed (e.g., "Error uploading blob")
///
/// ## Example
///
/// ```dart
/// try {
///   final data = await client.getBlob('invalid-id');
/// } on WalrusApiError catch (e) {
///   if (e.code == 404) {
///     print('Blob not found: ${e.message}');
///   } else if (e.code >= 500) {
///     print('Server error: ${e.status}');
///   }
///   print('Context: ${e.context}');
/// }
/// ```
///
/// ## Common Error Codes
///
/// * `404`: Blob not found
/// * `500`: Internal server error
/// * `TimeoutException`: Request exceeded configured timeout
@immutable
class WalrusApiError implements Exception {
  const WalrusApiError({
    required this.code,
    required this.status,
    required this.message,
    this.details = const <dynamic>[],
    this.context = '',
  });

  /// HTTP status code or API-specific error code.
  final int code;

  /// API status string such as `CLIENT_ERROR` or server-provided value.
  final String status;

  /// Human-readable failure message.
  final String message;

  /// Optional details array forwarded from the backend.
  final List<dynamic> details;

  /// Context string describing the call site that raised the error.
  final String context;

  @override
  String toString() {
    final buffer = StringBuffer();
    if (context.isNotEmpty) {
      buffer.write('$context: ');
    }
    buffer.write('HTTP $code - $status: $message');
    if (details.isNotEmpty) {
      buffer.write(' (Details: $details)');
    }
    return buffer.toString();
  }
}
