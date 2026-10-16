# Security

This document describes current source behavior and known limits of Dartus, reviewed on **October 16, 2026**. Local changes may differ from the published package. It is not an independent security audit or certification of mainnet readiness.

## Report a vulnerability privately

Email the maintainer at **[immadominion@gmail.com](mailto:immadominion@gmail.com)** with a description, affected version or commit, reproduction steps, and likely impact. Omit wallet secrets, real credentials, and other users' private data.

Do not put private vulnerability details in a public GitHub issue. No response-time commitment is claimed here.

## Transport behavior

| Path | Current behavior |
|------|------------------|
| Default `WalrusClient` over HTTPS | Uses `package:http` with platform certificate validation. `useSecureConnection` is a compatibility no-op, regardless of its value. |
| Injected `WalrusClient.httpClient` | Uses the supplied client's transport and certificate policy. Dartus cannot establish its safety. |
| `WalrusDirectClient` storage-node connections | Uses platform certificate validation; the former permissive callback has been removed. Default chain operations use Sui gRPC. |
| Standalone `StorageNodeClient` | Its own default `HttpClient` keeps normal certificate checks. A supplied client may use a different policy. |
| `UploadRelayClient` and `WalrusWriter` | `package:http` with platform certificate validation (the browser on the web). An injected `http.Client` sets its own policy. Chain reads use `package:sui`'s gRPC-web client over HTTPS. |

The SDK accepts HTTP URLs too; certificate validation does not make an HTTP URL encrypted. Use HTTPS for remote services.

`WalrusWriter` hands wallets a transaction to approve; the wallet shows the person what they pay and signs it, and Dartus never holds the person's key. It checks effects and reads the certified Blob object back, but servers that list wallet-stored files must still verify the Blob object on chain themselves. `KeypairTransactionSigner` holds a key in memory and is meant for scripts and tests.

Direct uploads require a BLS provider before payment, verify confirmations against committee keys and the exact epoch/blob/object message, and count each committee node once with its shard weight for quorum. Native metadata comes from walrus-core, including its actual per-pair hashes. The full live direct-write path still needs acceptance testing; these source changes and local checks do not establish a successful mainnet upload.

Wallet writes block concurrent calls. If submission throws without a reliable rejection or a returned digest, the flow reports `WalrusTransactionOutcomeUnknown` and blocks a second payment. Recover using the original digest, or confirm that the original request cannot succeed before resetting. Never classify timeouts or generic error text as a definite rejection. Flow state is not persisted across reloads/restarts. Optional `maxRelayTip` limits the relay fee, not WAL or gas.

## Authentication and logs

`WalrusClient` holds its default JWT in memory and sends it in the `Authorization: Bearer` header on uploads. A per-call token overrides that default, and `clearJwtToken()` clears the client's default reference. This is not secure erasure of all copies of a token.

Do not place private publisher credentials in a browser bundle. An injected HTTP client, publisher, logging callback, or caller can independently retain request information. SDK logging is off by default; review configured logging and endpoint URLs before enabling verbose output. Avoid embedding secrets in URLs.

## Local cache and file downloads

- Native cache filenames are SHA-256 hashes **of blob IDs**. This prevents blob IDs becoming file paths, but is not content verification or encryption. Hashes are deterministic, not secret.
- Cache data is plaintext. Use a directory accessible only to the intended OS user for sensitive application data. Caller-provided output paths and cache directories are trusted inputs; this is not a filesystem sandbox.
- `cacheMaxSize` limits entries, **not total bytes**. A single blob may still be large. Byte-oriented downloads retain the complete payload in memory.
- `getBlobAsFileStreaming` bypasses the byte cache and stages output before replacement. Existing symlinks resolve to regular files and remain intact; permission bits are checked before replacement. Copying an existing file to preserve those bits requires read access and temporary disk space. Ownership, ACLs and hard-link identity are not preserved. Same-filesystem replacement is atomic on POSIX; callers must prevent concurrent path mutations.
- Failed downloads preserve the existing destination. Temporary cleanup is best effort; crash residue requires manual cleanup. No automatic sweep deletes directories by prefix or age. Streaming limits application buffering, not total disk use.
- Cache operations are serialized within one instance. Do not share a cache directory between independent instances. Temporary directories are removed on disposal; explicitly supplied directories remain.

## Timeouts

For `WalrusClient`, `timeout` applies first to waiting for response headers and then to inactivity between response-body events. A stalled body raises `TimeoutException`, with body subscriptions and partial file output cleaned up. An active transfer can exceed the configured interval in total duration. The headers deadline alone does not abort the underlying request.

This contract applies to the HTTP publisher/aggregator client. It should not be assumed to cover every direct-mode, relay, or Sui operation. A timeout is not a content-size limit or a complete denial-of-service defense.

## Public storage and deletion

Do not treat a blob ID as an access-control secret. Walrus storage is not confidential by default; encrypt sensitive content before upload and manage the keys outside the blob. A publisher or storage endpoint can observe the bytes you send unless your application encrypts them first.

Upload entry points and registration builders reject `deletable: false` before submission. HTTP uploads always request `deletable=true`; native and wallet writes enforce the same restriction. This is a breaking change in the local 0.4.0 candidate. Reading existing non-deletable blobs remains supported.

Deletable means the blob can be removed through the relevant protocol operation; it does not automatically schedule deletion or remove copies already downloaded by others.

## What the checks establish

Run from this checkout:

```bash
flutter test --no-pub
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed lib test live_test tool
```

Default tests use injected fixtures or loopback HTTP services. Optional live checks are separate; see [CONTRIBUTING.md](CONTRIBUTING.md). Chrome JavaScript checks cover the HTTP byte API, memory cache and the WASM encoder in a Web Worker. They do not cover the dart2wasm build, live browser wallet approvals, or direct/FFI operation.

Tests establish behavior for their fixtures. Static analysis checks types and lints. `flutter pub outdated` reports available dependency versions; it is **not** a vulnerability audit. These checks do not demonstrate absence of vulnerabilities, full protocol verification, or legal compliance.

Earlier versions of this document listed test totals, clean dependency results, penetration testing, and an FFI safety audit without reproducible reports. Those claims are not carried forward as verified security evidence. There is no independently verified security-audit report linked by this document.
