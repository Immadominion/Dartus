import 'dart:io';

/// Severity levels for SDK log output, ordered from most to least restrictive.
///
/// Set the level on [WalrusLogger] to control which messages are emitted.
/// Only messages at or above the configured level are forwarded to the
/// log handler.
///
/// ```dart
/// // Silence all SDK logging (default)
/// final client = WalrusClient(
///   publisherBaseUrl: publisherUrl,
///   aggregatorBaseUrl: aggregatorUrl,
///   logLevel: WalrusLogLevel.none,
/// );
///
/// // Show informational messages and above
/// client.logger.level = WalrusLogLevel.info;
///
/// // Show everything including network request traces
/// client.logger.level = WalrusLogLevel.verbose;
/// ```
enum WalrusLogLevel implements Comparable<WalrusLogLevel> {
  /// No log output.
  none(0),

  /// Errors only — unrecoverable failures.
  error(1),

  /// Warnings and errors — degraded conditions.
  warning(2),

  /// Informational messages — key operational events (uploads, downloads,
  /// cache hits/misses).
  info(3),

  /// Alias for [info]. Retained for backward compatibility with v0.1.x.
  basic(3),

  /// Debug messages — internal decisions, transaction building,
  /// retry attempts.
  debug(4),

  /// Verbose trace — every HTTP request/response, sliver operations,
  /// encoding details.
  verbose(5);

  const WalrusLogLevel(this.priority);

  /// Numeric priority. Higher values include more output.
  final int priority;

  @override
  int compareTo(WalrusLogLevel other) => priority.compareTo(other.priority);

  /// Returns `true` when a message at this level should be emitted given
  /// the configured [threshold].
  bool isEnabledFor(WalrusLogLevel threshold) =>
      threshold != none && priority <= threshold.priority;
}

/// A single log record produced by the SDK.
class WalrusLogRecord {
  const WalrusLogRecord({
    required this.level,
    required this.message,
    required this.time,
    this.error,
    this.stackTrace,
  });

  final WalrusLogLevel level;
  final String message;
  final DateTime time;
  final Object? error;
  final StackTrace? stackTrace;

  @override
  String toString() {
    final label = level.name.toUpperCase();
    final ts = time.toIso8601String();
    final buf = StringBuffer('[$ts] Dartus $label: $message');
    if (error != null) buf.write(' → $error');
    return buf.toString();
  }
}

/// Callback signature for custom log handlers.
///
/// Return a function matching this signature to [WalrusLogger.onRecord]
/// to route SDK logs into your application's logging system.
///
/// ```dart
/// client.logger.onRecord = (record) {
///   myAppLogger.log(record.level.name, record.message);
/// };
/// ```
typedef WalrusLogHandler = void Function(WalrusLogRecord record);

/// Configurable logger for the Dartus SDK.
///
/// Each [WalrusClient] and [WalrusDirectClient] owns a [WalrusLogger]
/// accessible via its `logger` property. Configure it at construction
/// time or later:
///
/// ```dart
/// final client = WalrusClient(
///   publisherBaseUrl: publisherUrl,
///   aggregatorBaseUrl: aggregatorUrl,
///   logLevel: WalrusLogLevel.info, // show info messages and above
/// );
///
/// // Change at runtime
/// client.logger.level = WalrusLogLevel.debug;
///
/// // Route to a custom handler instead of stderr
/// client.logger.onRecord = (record) {
///   print('${record.level}: ${record.message}');
/// };
///
/// // Silence completely
/// client.logger.level = WalrusLogLevel.none;
/// ```
class WalrusLogger {
  /// Creates a logger with the given initial [level].
  ///
  /// By default, logs are written to [stderr] using the built-in
  /// formatter. Set [onRecord] to override this.
  WalrusLogger({this.level = WalrusLogLevel.none, this.onRecord});

  /// The minimum severity for emitted log records.
  WalrusLogLevel level;

  /// Optional custom handler. When `null`, records are printed to [stderr].
  WalrusLogHandler? onRecord;

  void _emit(
    WalrusLogLevel msgLevel,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!msgLevel.isEnabledFor(level)) return;

    final record = WalrusLogRecord(
      level: msgLevel,
      message: message,
      time: DateTime.now(),
      error: error,
      stackTrace: stackTrace,
    );

    if (onRecord != null) {
      onRecord!(record);
    } else {
      stderr.writeln(record);
      if (stackTrace != null) stderr.writeln(stackTrace);
    }
  }

  /// Log an error.
  void error(String message, {Object? error, StackTrace? stackTrace}) => _emit(
    WalrusLogLevel.error,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  /// Log a warning.
  void warning(String message) => _emit(WalrusLogLevel.warning, message);

  /// Log an informational message.
  void info(String message) => _emit(WalrusLogLevel.info, message);

  /// Log a debug message.
  void debug(String message) => _emit(WalrusLogLevel.debug, message);

  /// Log a verbose trace message.
  void verbose(String message) => _emit(WalrusLogLevel.verbose, message);
}
