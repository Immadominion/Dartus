# Changelog

All notable changes to Dartus will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] — unreleased

Local release candidate: storage paid for by the person's own wallet, on Flutter
web and natively.

### Added

- `WalrusWriter`: register, upload through the upload relay, and certify a
  blob with the signer paying WAL, gas and the relay tip. Two wallet
  approvals per write; the Blob object goes to the signer or a `recipient`.
  `WalrusWriteFlow.run` resumes recorded steps in a retained flow.
  `estimate` prices a write;
  `InsufficientWalBalanceError` is raised before the wallet is asked.
- `WalrusWriter.writeFiles`: several files as one quilt (two approvals and
  one storage fee per batch), with a quilt patch ID per file.
  `WalrusClient.getQuiltPatch` reads one file by patch ID.
- `WalletTransaction` (the JSON wallets take for
  `sui:signAndExecuteTransaction`, with WAL and tip intents resolved),
  `WalrusTransactionSigner`, `WalletTransactionSigner` and
  `KeypairTransactionSigner`.
- `WalrusWriter.estimateFiles` prices a batch as the quilt it will become.
- `WalrusClient` can be read-only: `publisherBaseUrl` is optional, and
  uploads without one throw `StateError`.
- `WalrusChainReader`: Walrus system state, Blob objects, created objects
  and balances over Sui gRPC-web.
- `WalrusTransactionBuilder.addRegisterBlob`, paying with exact-amount WAL
  `CoinWithBalance` intents, as the TS SDK's `registerBlob()`.
- Blob metadata on Flutter web from Mysten's `walrus-wasm` 0.3.1 (bundled as
  package assets, Apache-2.0) in a module Web Worker; `createDefaultBlobEncoder`
  picks walrus-wasm on the web and `libwalrus_ffi` natively.
- `WalrusNetwork.walCoinType`, `suiChain`, and a default mainnet relay URL.
- `UploadRelayError` for relay refusals, with status and message.

### Changed (breaking)

- Requires `sui` ^0.5.1 (gRPC-web and GraphQL clients; pointycastle 4).
  Default `WalrusDirectClient` chain operations now use gRPC.
- All upload entry points reject `deletable: false` before submission.
- Native users must rebuild `libwalrus_ffi`: encoding now requires
  `walrus_encode_blob_v2` for complete canonical metadata.
- The deprecated transaction builder `registerBlobTransaction` now throws
  instead of constructing an invalid placeholder transaction. Use
  `registerBlobWithWal` or `addRegisterBlob`.
- Wallet timeouts and lost responses block retry until the original outcome
  is resolved. A custom signer must identify definite declines with
  `WalrusTransactionNotCommitted` or `isDefinitelyNotCommitted`.
- `TipStrategy.calculateTip` and `UploadRelayTipConfig.calculateTip` take the
  **encoded** size; `sendUploadRelayTip` takes `encodedSize`. A tip above
  `max` now throws instead of being capped.
- `WalrusNetwork.defaultUploadRelayUrl` is non-null (mainnet has a relay).
- `WalrusClient.publisherBaseUrl` is nullable.

### Fixed

- Native encoding returns the actual per-pair Merkle hashes from walrus-core;
  a byte-for-byte WASM reference fixture replaces placeholder metadata.
- Direct uploads use one authenticated confirmation per committee node,
  validate shard-weight quorum, the exact signed message and aggregate signature,
  and require BLS
  before payment. Native wallet flows verify registration and certification
  on chain. Default storage-node transport no longer bypasses TLS checks.
- Wallet flows reject concurrent submissions, retain paid metadata on retry,
  validate receipt ownership/content/storage period, and distinguish unknown
  submission outcomes from definite rejection. Optional `maxRelayTip` caps
  the tip at estimate and registration time.
- Streaming replacement preserves checked permission bits and symlink targets
  while staging changes before rename. Cleanup errors cannot mask the result.
  No age-based deletion of unknown staging directories is performed.
- Native build output is untracked and the build script selects only the
  current host's library artifact.
- Linear relay tips were computed from the unencoded size, underpaying the
  mainnet relay, which then refused uploads after WAL had been spent.
- `UploadRelayClient` used `dart:io` and could not run on Flutter web; it now
  uses `package:http` and accepts an `http.Client` (for upload progress).
- Quilt file identifiers are written and read as BCS strings. Aggregators
  could not read Dartus quilts ("invalid identifier"); vectors from
  `@mysten/walrus` now match byte for byte.

- `WalrusClient.getBlobByObjectId` now uses the aggregator's
  `/v1/blobs/by-object-id/{objectId}` route so Sui object IDs are resolved
  correctly, including when the aggregator URL has a base path.
- Cache overwrites preserve unrelated entries and refresh recency. Per-instance
  operation ordering prevents concurrent writes from exceeding capacity or
  racing cleanup; failed writes preserve the previous complete file.
- HTTP response bodies now time out after an idle interval, canceling their
  stream subscription. The existing separate header deadline is retained.
- Streaming file downloads write chunks with backpressure into a temporary
  sibling directory, replace the destination only after success, and clean up
  after stream or filesystem failures. Error diagnostics are capped at 64 KiB.
- All four automatic WAL coin selection/merge paths follow pagination, ignore
  duplicate coin IDs, and reject missing or repeated continuation cursors.
- README examples now use the current imports and named arguments. Security
  documentation distinguishes source checks from audits and records current
  current transport, upload-policy and live-verification limits.

### Changed

- `getBlobAsFileStreaming` bypasses both byte-cache reads and writes to avoid
  buffering entire downloads. Use `getBlobAsFile` when cache reuse is wanted.
- Declared Dart minimum is now 3.11, matching the existing hosted `bls_dart`
  dependency. Shortened the package description to satisfy metadata guidance.
- Default tests are deterministic and block external native HTTP requests;
  live checks moved to explicitly selected `live_test/` files. Added local
  regressions, checked documentation examples, Chrome JavaScript runtime tests,
  and a GitHub Actions workflow for formatting, analysis, native and web tests.

## [0.3.0] - 2026-06-20

Makes Dartus work on **Flutter Web** in HTTP mode. Contains breaking changes
for direct-mode and custom-HTTP-client users (see below).

### Changed (breaking)

- **Web-safe public API split.** `package:dartus/dartus.dart` is now free of
  `dart:ffi` and is the web-safe HTTP surface. The direct-mode + Rust FFI
  surface (`WalrusDirectClient`, `WriteBlobFlow`, `WriteFilesFlow`,
  `WalrusBlobEncoder`, `WalrusFfiBindings`) moved to a new entry point,
  `package:dartus/direct.dart`. Direct-mode users must import
  `package:dartus/direct.dart`.
- `WalrusClient`'s `httpClient` parameter now takes a `package:http`
  `http.Client` instead of a `dart:io` `HttpClient`. `useSecureConnection`
  is now a no-op (TLS is handled by the platform).
- `BlobCache.put()` now returns `File?` (`null` on web) instead of `File`.

### Fixed

- HTTP mode now builds and runs on Flutter Web. Removed two web-blocking
  `dart:io` crashes: `BlobCache` falls back to an in-memory store on web
  (previously `Unsupported operation: _Namespace`), and the HTTP transport
  (`RequestExecutor`, `WalrusClient`) moved from `dart:io` `HttpClient` to
  `package:http` (`BrowserClient` on web, `IOClient` on native).
- Clarified `RetryableWalrusClientError` docs: these are thrown only by
  `WalrusDirectClient` (direct mode); recover via `reset()` or
  `retryOnPossibleEpochChange()`. HTTP-mode `WalrusClient` surfaces failures
  as `WalrusApiError`.

## [0.2.0] - 2026-03-25

### Added

#### Direct Mode Client (`WalrusDirectClient`)
- `WalrusDirectClient` — wallet-integrated client for direct storage-node interaction
- `WalrusDirectClient.fromNetwork()` — create from `WalrusNetwork.testnet` or `.mainnet` preset
- `readBlob()` — read and decode blobs directly from storage nodes
- `getBlob()` — get a `WalrusBlob` handle with `.bytes()`, `.text()`, `.json()`, `.files()`
- `getFiles()` — read files by blob or quilt ID
- `writeBlob()` — full write flow: encode → register → upload → certify
- `writeFiles()` — write multiple files as a quilt
- `writeQuilt()` — write a quilt from raw `QuiltBlob` entries
- `getBlobMetadata()` — fetch metadata from storage nodes
- `getSlivers()` — fetch primary slivers from storage nodes
- `getSecondarySliver()` — fetch a specific secondary sliver
- `getVerifiedBlobStatus()` — quorum-verified blob status
- `getBlobObjectInfo()` — read on-chain blob object info (certified epoch, end epoch, etc.)
- `resolveBlobId()` — resolve Sui object ID (`0x...`) to base64 blob ID with certification check
- `getOwnedBlobs()` — list blob objects owned by a wallet address
- `lookupBlobObjectId()` — find a blob's Sui object ID from its blob ID
- `storageCost()` — calculate WAL storage cost
- `systemState()` / `stakingState()` — read on-chain protocol state

#### Step-by-Step Write Flows
- `WriteBlobFlow` — encode → register → upload → certify (for dApp wallets)
- `WriteFilesFlow` — multi-file quilt write flow

#### Transaction Builders
- `registerBlobTransaction()` — build a blob registration transaction
- `certifyBlobTransaction()` — build a blob certification transaction
- `deleteBlobTransaction()` — build a blob deletion transaction
- `readBlobAttributes()` / `writeBlobAttributes()` — on-chain metadata attributes

#### File Abstractions
- `WalrusFile` — file with identifier, tags, content; `.bytes()`, `.text()`, `.json()`, `.getIdentifier()`, `.getTags()`
- `WalrusBlob` — blob handle with `.asFile()`, `.files()` (quilt reading), `.bytes()`, `.exists()`
- `QuiltReader` / `QuiltFileReader` — read multi-file quilts
- `BlobReader` — stream blob content from storage nodes

#### Client-Side Encoding (Rust FFI)
- `WalrusBlobEncoder` — RS2 erasure coding using `libwalrus_ffi` (Rust `walrus-core`)
- `WalrusFfiBindings` — Dart FFI bindings for `walrus_compute_metadata`, `walrus_encode_blob`, `walrus_decode_blob`
- Removed `fountain_codes` dependency — FFI is now required, no pure-Dart fallback

#### Storage Node Client
- `StorageNodeClient` — HTTP client for storage node APIs (sliver read/write, metadata, confirmation)
- BCS serialization for sliver data and blob metadata

#### Upload Relay
- `UploadRelayClient` — upload via relay server with configurable tip strategies
- `ConstTipStrategy` / `LinearTipStrategy` — tip configuration

#### Error Hierarchy
- 18+ typed error classes mirroring the TypeScript SDK
- `RetryableWalrusClientError` base class for errors that may resolve after `client.reset()`
- Storage-node HTTP errors: `BadRequestError`, `NotFoundError`, `AuthenticationError`, `RateLimitError`, etc.
- `BlobNotCertifiedError`, `BehindCurrentEpochError`, `InconsistentBlobError`, `InsufficientWalBalanceError`

#### Utilities
- `blobIdFromInt()` / `blobIdToInt()` — blob ID format conversions (verified against TS SDK)
- `encodeQuilt()` — encode multiple blobs into quilt format
- `computeBlobId()` — compute blob ID from root hash
- `weightedShuffle()` — weighted random shuffle for storage node selection
- `retry()` / `retryOnPossibleEpochChange()` — retry utilities

#### Network Configuration
- `WalrusNetwork.testnet` / `WalrusNetwork.mainnet` enum
- `testnetWalrusPackageConfig` / `mainnetWalrusPackageConfig` with pre-configured IDs
- `WalrusPackageConfig` — walrus package ID, system/staking/exchange object IDs

### Changed

#### Logging System
- **Breaking**: Logging is now silent by default (`WalrusLogLevel.none`). Previously defaulted to `basic`.
  Set `logLevel: WalrusLogLevel.info` to restore previous behavior.
- Extracted logging into standalone `WalrusLogger` class — accessible via `client.logger`
- Expanded log levels: `none`, `error`, `warning`, `info`, `basic` (alias for info), `debug`, `verbose`
- Added `WalrusLogHandler` callback for custom log routing (integrate with your own logger)
- Added `WalrusLogRecord` structured log records with timestamp, level, message, error, stackTrace
- Added `onLog` parameter to both `WalrusClient` and `WalrusDirectClient` constructors
- Logs now output to `stderr` instead of `stdout` (standard practice for libraries)
- Replaced internal debug `print()` statements with proper `debug`-level logging

#### General
- README rewritten to cover all three operational modes (HTTP, relay, direct)
- Comprehensive error handling documentation added
- `flutter` constraint updated to `>=3.35.0` (was `>=3.0.0`)
- Added `sui: ^0.3.7`, `bls_dart: ^0.1.2`, `ffi: ^2.1.4`, `http: ^1.2.0` dependencies
- Test suite expanded from 8 files to 30 files (473+ tests)
- Added `issue_tracker`, `documentation` URLs and `topics` to pubspec

### Removed
- `fountain_codes` dependency — replaced by Rust FFI
- `test_destroy_zero.dart` — debugging script removed
- `build_native.sh` — relocated to `native/build.sh`
- Empty `docs/` directory
- Bare `print('[Dartus DEBUG]...')` statements — now routed through `WalrusLogger`

### Notes
- Phase 2/3 tests (5 test files) require `flutter test` instead of `dart test` due to
  `package:sui` → `dart:ui` dependency. All 473 tests pass with `flutter test`.

## [0.1.2] - 2026-03-11

### Added
- Include generated API documentation (`doc/api/`) in the published package
- Updated banner with Walrus Foundation logo

## [0.1.1] - 2026-02-06

### Added

- Documentation: Added "Storage Costs (SUI & WAL)" section explaining the publisher payment model
- Clarified that Dartus is an HTTP client and does not handle wallet/token operations

### Notes

- No code changes; documentation-only release

## [0.1.0] - 2026-01-20

### Added

- Initial release with Walrus HTTP API support
- Upload methods: `putBlob`, `putBlobFromFile`, `putBlobStreaming` (default `deletable=true`)
- Download methods: `getBlob`, `getBlobByObjectId`, `getBlobAsFile`, `getBlobAsFileStreaming`
- Metadata retrieval: `getBlobMetadata` for HEAD requests
- Disk-based blob cache with LRU eviction and SHA-256 filenames
- JWT authentication support with instance and per-call tokens
- Configurable TLS validation via `useSecureConnection`
- Built-in logging with levels: `none`, `basic`, `verbose`
- Flutter demo app with upload and fetch flows
- Live integration tests against Walrus testnet endpoints

### Notes

- Blobs are created as deletable by default; pass `deletable: false` to create permanent blobs

