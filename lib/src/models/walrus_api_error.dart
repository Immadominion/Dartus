import 'package:meta/meta.dart';

/// Represents a Walrus API error payload, matching the Swift SDK contract.
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
