/// Tests for [walrus_errors.dart] — typed error hierarchy.
library;

import 'package:dartus/src/errors/walrus_errors.dart';
import 'package:test/test.dart';

void main() {
  group('WalrusClientError', () {
    test('is an Exception', () {
      const error = WalrusClientError('test');
      expect(error, isA<Exception>());
      expect(error.message, 'test');
      expect(error.toString(), contains('test'));
    });

    test('empty message shows class name', () {
      const error = WalrusClientError();
      expect(error.toString(), 'WalrusClientError');
    });
  });

  group('RetryableWalrusClientError', () {
    test('is a WalrusClientError', () {
      const error = RetryableWalrusClientError('oops');
      expect(error, isA<WalrusClientError>());
    });
  });

  group('Client error subtypes', () {
    test('NoBlobStatusReceivedError', () {
      const e = NoBlobStatusReceivedError('no status');
      expect(e, isA<WalrusClientError>());
      expect(e, isNot(isA<RetryableWalrusClientError>()));
    });

    test('NoVerifiedBlobStatusReceivedError', () {
      const e = NoVerifiedBlobStatusReceivedError('unverified');
      expect(e, isA<WalrusClientError>());
    });

    test('NoBlobMetadataReceivedError is retryable', () {
      const e = NoBlobMetadataReceivedError('no meta');
      expect(e, isA<RetryableWalrusClientError>());
    });

    test('NotEnoughSliversReceivedError is retryable', () {
      const e = NotEnoughSliversReceivedError('not enough');
      expect(e, isA<RetryableWalrusClientError>());
    });

    test('NotEnoughBlobConfirmationsError is retryable', () {
      const e = NotEnoughBlobConfirmationsError('few');
      expect(e, isA<RetryableWalrusClientError>());
    });

    test('BehindCurrentEpochError is retryable', () {
      const e = BehindCurrentEpochError('old epoch');
      expect(e, isA<RetryableWalrusClientError>());
    });

    test('BlobNotCertifiedError is retryable', () {
      const e = BlobNotCertifiedError('not certified');
      expect(e, isA<RetryableWalrusClientError>());
    });

    test('InconsistentBlobError', () {
      const e = InconsistentBlobError('inconsistent');
      expect(e, isA<WalrusClientError>());
    });

    test('BlobBlockedError', () {
      const e = BlobBlockedError('blocked');
      expect(e, isA<Exception>());
    });

    test('InsufficientWalBalanceError', () {
      final e = InsufficientWalBalanceError(
        ownerAddress: '0xabc',
        requiredAmount: BigInt.from(1000),
        message: 'not enough WAL',
      );
      expect(e, isA<WalrusClientError>());
      expect(e.ownerAddress, '0xabc');
      expect(e.requiredAmount, BigInt.from(1000));
    });
  });

  group('StorageNodeApiError.fromResponse', () {
    test('400 returns BadRequestError', () {
      final e = StorageNodeApiError.fromResponse(
        statusCode: 400,
        responseBody: 'bad request',
      );
      expect(e, isA<BadRequestError>());
      expect(e.statusCode, 400);
    });

    test('400 with NOT_REGISTERED returns BlobNotRegisteredError', () {
      final e = StorageNodeApiError.fromResponse(
        statusCode: 400,
        responseBody: '{"reason": "NOT_REGISTERED"}',
      );
      expect(e, isA<BlobNotRegisteredError>());
      expect(e, isA<StorageNodeApiError>());
    });

    test('401 returns AuthenticationError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 401);
      expect(e, isA<AuthenticationError>());
    });

    test('403 returns PermissionDeniedError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 403);
      expect(e, isA<PermissionDeniedError>());
    });

    test('404 returns NotFoundError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 404);
      expect(e, isA<NotFoundError>());
    });

    test('409 returns ConflictError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 409);
      expect(e, isA<ConflictError>());
    });

    test('422 returns UnprocessableEntityError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 422);
      expect(e, isA<UnprocessableEntityError>());
    });

    test('429 returns RateLimitError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 429);
      expect(e, isA<RateLimitError>());
    });

    test('451 returns LegallyUnavailableError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 451);
      expect(e, isA<LegallyUnavailableError>());
    });

    test('500 returns InternalServerError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 500);
      expect(e, isA<InternalServerError>());
      expect((e as InternalServerError).statusCode, 500);
    });

    test('502 returns InternalServerError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 502);
      expect(e, isA<InternalServerError>());
    });

    test('unknown status returns generic StorageNodeApiError', () {
      final e = StorageNodeApiError.fromResponse(statusCode: 418);
      expect(e.runtimeType, StorageNodeApiError);
      expect(e.statusCode, 418);
    });

    test('custom message overrides body', () {
      final e = StorageNodeApiError.fromResponse(
        statusCode: 404,
        responseBody: 'raw body',
        message: 'custom message',
      );
      expect(e.toString(), 'custom message');
    });
  });

  group('Connection errors', () {
    test('StorageNodeConnectionError has null statusCode', () {
      const e = StorageNodeConnectionError('DNS fail');
      expect(e.statusCode, isNull);
      expect(e, isA<StorageNodeApiError>());
    });

    test('StorageNodeConnectionTimeoutError', () {
      const e = StorageNodeConnectionTimeoutError();
      expect(e.statusCode, isNull);
    });

    test('UserAbortError', () {
      const e = UserAbortError();
      expect(e.statusCode, isNull);
    });
  });
}
