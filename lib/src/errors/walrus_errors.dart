/// Error types for the Walrus SDK, mirroring the TypeScript SDK's error hierarchy.
///
/// The TS SDK defines two error hierarchies:
///
/// 1. **Client-level errors** (`WalrusClientError` and subtypes) — raised
///    when the Walrus client encounters logical failures (insufficient
///    confirmations, behind-epoch, inconsistent blob, etc.).
///
/// 2. **Storage-node HTTP errors** (`StorageNodeError` and subtypes) — raised
///    when a storage node returns an unexpected HTTP status code.
///
/// Retryable errors extend [RetryableWalrusClientError]. The client can
/// catch these, reset cached state, and retry the operation (e.g. after an
/// epoch change).
library;

// ---------------------------------------------------------------------------
// Client-Level Errors
// ---------------------------------------------------------------------------

/// Base exception for all Walrus SDK client errors.
class WalrusClientError implements Exception {
  final String message;

  const WalrusClientError([this.message = '']);

  @override
  String toString() =>
      message.isEmpty ? 'WalrusClientError' : 'WalrusClientError: $message';
}

/// A [WalrusClientError] subclass that indicates the operation may succeed
/// if retried (e.g. after an epoch change or transient node failure).
class RetryableWalrusClientError extends WalrusClientError {
  const RetryableWalrusClientError([super.message]);

  @override
  String toString() => message.isEmpty
      ? 'RetryableWalrusClientError'
      : 'RetryableWalrusClientError: $message';
}

/// Thrown when the client could not retrieve the status of a blob from any
/// storage node.
class NoBlobStatusReceivedError extends WalrusClientError {
  const NoBlobStatusReceivedError([super.message]);
}

/// Thrown when the client could not retrieve a verified blob status for
/// the blob (i.e. no status reached a validity threshold from quorum).
class NoVerifiedBlobStatusReceivedError extends WalrusClientError {
  const NoVerifiedBlobStatusReceivedError([super.message]);
}

/// Thrown when the client could not retrieve blob metadata from any
/// storage node. Retryable because the metadata may appear once the
/// blob is fully registered and propagated.
class NoBlobMetadataReceivedError extends RetryableWalrusClientError {
  const NoBlobMetadataReceivedError([super.message]);
}

/// Thrown when the client could not retrieve enough slivers to
/// reconstruct the blob. Retryable because nodes may come back online.
class NotEnoughSliversReceivedError extends RetryableWalrusClientError {
  const NotEnoughSliversReceivedError([super.message]);
}

/// Thrown when the client could not collect enough storage confirmations
/// to certify the blob. Retryable because confirmations may still arrive.
class NotEnoughBlobConfirmationsError extends RetryableWalrusClientError {
  const NotEnoughBlobConfirmationsError([super.message]);
}

/// Thrown when the client detects it is behind the current epoch, e.g.
/// during an epoch change. The client should reset cached state and retry.
class BehindCurrentEpochError extends RetryableWalrusClientError {
  const BehindCurrentEpochError([super.message]);
}

/// Thrown when a blob is not certified or determined to not exist.
/// Retryable because blob certification may still be in progress.
class BlobNotCertifiedError extends RetryableWalrusClientError {
  const BlobNotCertifiedError([super.message]);
}

/// Thrown when a blob was determined to be incorrectly encoded.
/// NOT retryable — the blob data itself is invalid.
class InconsistentBlobError extends WalrusClientError {
  const InconsistentBlobError([super.message]);
}

/// Thrown when a blob is blocked by a quorum of storage nodes.
/// NOT retryable — the content is legally restricted.
class BlobBlockedError implements Exception {
  final String message;

  const BlobBlockedError([this.message = '']);

  @override
  String toString() =>
      message.isEmpty ? 'BlobBlockedError' : 'BlobBlockedError: $message';
}

/// Thrown when no WAL coin with sufficient balance can be found.
class InsufficientWalBalanceError extends WalrusClientError {
  final String ownerAddress;
  final BigInt requiredAmount;

  const InsufficientWalBalanceError({
    required this.ownerAddress,
    required this.requiredAmount,
    String message = '',
  }) : super(message);

  @override
  String toString() => message.isEmpty
      ? 'InsufficientWalBalanceError: Need $requiredAmount WAL for $ownerAddress'
      : 'InsufficientWalBalanceError: $message';
}

// ---------------------------------------------------------------------------
// Storage Node HTTP Errors
// ---------------------------------------------------------------------------

/// Base exception for storage node interaction failures.
class StorageNodeError implements Exception {
  final String message;

  const StorageNodeError([this.message = '']);

  @override
  String toString() =>
      message.isEmpty ? 'StorageNodeError' : 'StorageNodeError: $message';
}

/// A storage node returned an unexpected HTTP status code.
class StorageNodeApiError extends StorageNodeError {
  /// HTTP status code from the storage node, or `null` for connection errors.
  final int? statusCode;

  /// Raw response body, if available.
  final String? responseBody;

  const StorageNodeApiError({
    this.statusCode,
    this.responseBody,
    String message = '',
  }) : super(message);

  /// Factory that maps HTTP status codes to specific error subclasses,
  /// matching the TS SDK's `StorageNodeAPIError.generate()`.
  factory StorageNodeApiError.fromResponse({
    required int statusCode,
    String? responseBody,
    String? message,
  }) {
    final msg =
        message ??
        (responseBody != null && responseBody.isNotEmpty
            ? '$statusCode: $responseBody'
            : '$statusCode status code');

    // Check for BlobNotRegisteredError (400 with NOT_REGISTERED reason)
    if (statusCode == 400 && responseBody != null) {
      if (responseBody.contains('NOT_REGISTERED')) {
        return BlobNotRegisteredError(msg);
      }
      return BadRequestError(msg);
    }

    return switch (statusCode) {
      401 => AuthenticationError(msg),
      403 => PermissionDeniedError(msg),
      404 => NotFoundError(msg),
      409 => ConflictError(msg),
      422 => UnprocessableEntityError(msg),
      429 => RateLimitError(msg),
      451 => LegallyUnavailableError(msg),
      >= 500 => InternalServerError(statusCode, msg),
      _ => StorageNodeApiError(
        statusCode: statusCode,
        responseBody: responseBody,
        message: msg,
      ),
    };
  }

  @override
  String toString() =>
      message.isEmpty ? 'StorageNodeApiError($statusCode)' : message;
}

/// Connection-level errors (timeout, DNS, etc.) — no HTTP status code.
class StorageNodeConnectionError extends StorageNodeApiError {
  const StorageNodeConnectionError([String message = 'Connection error'])
    : super(statusCode: null, message: message);
}

/// Connection timeout.
class StorageNodeConnectionTimeoutError extends StorageNodeApiError {
  const StorageNodeConnectionTimeoutError([
    String message = 'Request timed out',
  ]) : super(statusCode: null, message: message);
}

/// The user explicitly aborted the request.
class UserAbortError extends StorageNodeApiError {
  const UserAbortError([String message = 'Request was aborted'])
    : super(statusCode: null, message: message);
}

/// 400 Bad Request.
class BadRequestError extends StorageNodeApiError {
  const BadRequestError([String message = ''])
    : super(statusCode: 400, message: message);
}

/// 400 Bad Request — blob not yet registered on-chain.
///
/// This is an important error because the TS SDK retries metadata writes
/// when encountering it (the blob may not have been indexed yet).
class BlobNotRegisteredError extends StorageNodeApiError {
  const BlobNotRegisteredError([String message = ''])
    : super(statusCode: 400, message: message);
}

/// 401 Unauthorized.
class AuthenticationError extends StorageNodeApiError {
  const AuthenticationError([String message = ''])
    : super(statusCode: 401, message: message);
}

/// 403 Forbidden.
class PermissionDeniedError extends StorageNodeApiError {
  const PermissionDeniedError([String message = ''])
    : super(statusCode: 403, message: message);
}

/// 404 Not Found.
class NotFoundError extends StorageNodeApiError {
  const NotFoundError([String message = ''])
    : super(statusCode: 404, message: message);
}

/// 409 Conflict.
class ConflictError extends StorageNodeApiError {
  const ConflictError([String message = ''])
    : super(statusCode: 409, message: message);
}

/// 422 Unprocessable Entity.
class UnprocessableEntityError extends StorageNodeApiError {
  const UnprocessableEntityError([String message = ''])
    : super(statusCode: 422, message: message);
}

/// 429 Too Many Requests.
class RateLimitError extends StorageNodeApiError {
  const RateLimitError([String message = ''])
    : super(statusCode: 429, message: message);
}

/// 451 Unavailable For Legal Reasons.
class LegallyUnavailableError extends StorageNodeApiError {
  const LegallyUnavailableError([String message = ''])
    : super(statusCode: 451, message: message);
}

/// 5xx Internal Server Error.
class InternalServerError extends StorageNodeApiError {
  const InternalServerError([int statusCode = 500, String message = ''])
    : super(statusCode: statusCode, message: message);
}
