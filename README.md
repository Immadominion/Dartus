# Dartus

Dartus is the Dart and Flutter version of the Swift Walrus SDK. Upload, download, caching, streaming, and authentication calls to Walrus behave the same on both platforms.


![Walrus SDK banner](./banner.png)

## Requirements
- Dart ≥ 3.9.4 or Flutter stable 3.35.0 (validated 2025-10-04).
- Publisher and aggregator base URLs for your Walrus deployment.
- iOS builds that rely on insecure HTTP must add ATS exceptions, matching the Swift demo.

## Install
Add Dartus as a local path dependency and fetch packages:

```yaml
dependencies:
  dartus:
    path: ^latest
```

```bash
dart pub get
```

## Quick start
```dart
final client = WalrusClient(
  publisherBaseUrl: Uri.parse('https://publisher.example.com'), // publisher endpoints require HTTPS 
  aggregatorBaseUrl: Uri.parse('https://aggregator.example.com'),
  timeout: const Duration(seconds: 30),
  useSecureConnection: false, // Swift default, set to true for mainnet
);

final response = await client.putBlob(data: imageBytes);
final blobId = _findBlobId(response)!;
final bytes = await client.getBlob(blobId);
await client.close();
```

- Configure a default JWT with `setJwtToken`, override per call with `jwtToken`, and reset with `clearJwtToken`.
- Blobs are cached on disk with SHA-256 filenames; call `close()` to clean up temporary stores.

## Feature parity
- Upload helpers: `putBlob`, `putBlobFromFile`, `putBlobStreaming` (shared query parameters and headers).
- Download helpers: `getBlob`, `getBlobByObjectId`, `getBlobAsFile`, `getBlobAsFileStreaming`, plus `getBlobMetadata` for `HEAD` responses.
- Errors propagate through `WalrusApiError` (`code`, `status`, `message`, `details`, `context`).
- Console logging defaults to `WalrusLogLevel.basic`; switch to `verbose` for request traces or `none` to silence output.

## TLS modes
- `useSecureConnection: false` accepts any certificate, matching Swift’s default testnet behaviour.
- Testnet hosts such as `agg.test.walrus.eosusa.io` use an expired certificate today, so keep insecure mode enabled when targeting them.
- Set `useSecureConnection: true` when endpoints present trusted certificates.

## Tests
- `dart test` runs live integration checks aligned with `WalrusSDKTests.swift`.
- Tests expect network access and valid Walrus endpoints; adjust `test_config.dart` when endpoints rotate.

## Flutter demo
- A parity-focused Flutter app lives in `example/`. Fetch dependencies with `flutter pub get`, generate any missing platform folders via `flutter create .`, then launch with `flutter run`.
- The demo mirrors the iOS sample: pick an image to upload, copy the returned blob ID, and fetch it back with console logs emitted by `WalrusClient`.
