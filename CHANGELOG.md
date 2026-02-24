# Changelog

All notable changes to Dartus will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-02-24

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
- README rewritten to cover all three operational modes (HTTP, relay, direct)
- Comprehensive error handling documentation added
- `flutter` constraint updated to `>=3.35.0` (was `>=3.0.0`)
- Version bumped to 0.2.0 for major feature additions

### Removed
- `fountain_codes` dependency — replaced by Rust FFI
- `test_destroy_zero.dart` — debugging script removed
- `build_native.sh` — relocated to `native/build.sh`
- Empty `docs/` directory

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
