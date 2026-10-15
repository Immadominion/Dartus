# Security

This document describes current source behavior and known limits of Dartus, reviewed on **October 9, 2026**. Local changes may differ from the published package. It is not an independent security audit or certification of mainnet readiness.

## Report a vulnerability privately

Email the maintainer at **[immadominion@gmail.com](mailto:immadominion@gmail.com)** with a description, affected version or commit, reproduction steps, and likely impact. Omit wallet secrets, real credentials, and other users' private data.

Do not put private vulnerability details in a public GitHub issue. GitHub private vulnerability reporting is not enabled for this repository as of the review date. No response-time commitment is claimed here.

## Transport behavior

| Path | Current behavior |
|------|------------------|
| Default `WalrusClient` over HTTPS | Uses `package:http` with platform certificate validation. `useSecureConnection` is a compatibility no-op, regardless of its value. |
| Injected `WalrusClient.httpClient` | Uses the supplied client's transport and certificate policy. Dartus cannot establish its safety. |
| `WalrusDirectClient` storage-node connections | Its shared `HttpClient` accepts invalid certificates through `badCertificateCallback`, leaving these connections vulnerable to interception. |
| Standalone `StorageNodeClient` / `UploadRelayClient` | Their own default `HttpClient` keeps normal certificate checks. A supplied storage-node client may use a different policy. |

The SDK accepts HTTP URLs too; certificate validation does not make an HTTP URL encrypted. Use HTTPS for remote services. The HTTP compatibility flag does not change the direct client's insecure certificate behavior.

Direct operation also needs further validation of its Sui transport, registration/certification flow, BLS configuration, and encoded metadata. API examples and unit tests do not establish that those paths can safely complete a mainnet upload.

## Authentication and logs

`WalrusClient` holds its default JWT in memory and sends it in the `Authorization: Bearer` header on uploads. A per-call token overrides that default, and `clearJwtToken()` clears the client's default reference. This is not secure erasure of all copies of a token.

Do not place private publisher credentials in a browser bundle. An injected HTTP client, publisher, logging callback, or caller can independently retain request information. SDK logging is off by default; review configured logging and endpoint URLs before enabling verbose output. Avoid embedding secrets in URLs.

## Local cache and file downloads

- Native cache filenames are SHA-256 hashes **of blob IDs**. This prevents blob IDs becoming file paths, but is not content verification or encryption. Hashes are deterministic, not secret.
- Cache data is plaintext. Use a directory accessible only to the intended OS user for sensitive application data. Caller-provided output paths and cache directories are trusted inputs; this is not a filesystem sandbox.
- `cacheMaxSize` limits entries, **not total bytes**. A single blob may still be large. Byte-oriented downloads retain the complete payload in memory.
- `getBlobAsFileStreaming` bypasses the byte cache and writes to a temporary file, replacing the destination after success. Failed downloads discard partial output. This limits application buffering but does not impose a maximum download size or disk quota.
- Cache operations are serialized within one instance. Do not share a cache directory between independent instances. Temporary directories are removed on disposal; explicitly supplied directories remain.

## Timeouts

For `WalrusClient`, `timeout` applies first to waiting for response headers and then to inactivity between response-body events. A stalled body raises `TimeoutException`, with body subscriptions and partial file output cleaned up. An active transfer can exceed the configured interval in total duration. The headers deadline alone does not abort the underlying request.

This contract applies to the HTTP publisher/aggregator client. It should not be assumed to cover every direct-mode, relay, or Sui operation. A timeout is not a content-size limit or a complete denial-of-service defense.

## Public storage and deletion

Do not treat a blob ID as an access-control secret. Walrus storage is not confidential by default; encrypt sensitive content before upload and manage the keys outside the blob. A publisher or storage endpoint can observe the bytes you send unless your application encrypts them first.

HTTP upload methods currently default to `deletable: true`, but permit callers to pass `false`. Direct write APIs require an explicit deletion choice and also accept `false`. The SDK therefore **does not enforce a deletable-only policy**. A default value alone does not establish grant compliance.

Deletable means the blob can be removed through the relevant protocol operation; it does not automatically schedule deletion or remove copies already downloaded by others. Changing the defaults or enforcing a restriction requires a coordinated behavior and release decision.

## What the checks establish

Run from this checkout:

```bash
flutter test --no-pub
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed lib test live_test tool
```

Default tests use injected fixtures or loopback HTTP services. Optional live checks are separate; see [CONTRIBUTING.md](CONTRIBUTING.md). Browser checks cover the HTTP byte API and memory cache in Chrome JavaScript, not direct/FFI operation or WebAssembly.

Tests establish behavior for their fixtures. Static analysis checks types and lints. `flutter pub outdated` reports available dependency versions; it is **not** a vulnerability audit. These checks do not demonstrate absence of vulnerabilities, full protocol verification, or legal compliance.

Earlier versions of this document listed test totals, clean dependency results, penetration testing, and an FFI safety audit without reproducible reports. Those claims are not carried forward as verified security evidence. There is no independently verified security-audit report linked by this document.
