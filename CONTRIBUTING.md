# Contributing to Dartus

Thank you for your interest in contributing to Dartus! This guide covers setup, architecture, and conventions.

Check the [issue tracker](https://github.com/Immadominion/Dartus/issues) for open work before starting, and agree on scope in the issue first.

## Development Setup

Use Flutter with bundled Dart **>=3.11.0 <4.0.0**. CI uses Flutter **3.44.2**, matching the locally verified toolchain.

```bash
# Clone the repository
git clone https://github.com/Immadominion/Dartus.git
cd Dartus

# Install dependencies
flutter pub get

# Build the native encoder required by the complete suite (requires Rust)
bash native/build.sh release

# Run the complete deterministic suite
flutter test --no-pub

# Run the analyzer (strict mode)
dart analyze --fatal-infos

# Format code
dart format .
```

### Native library (required for the complete test suite)

Native encoding and the complete test suite require the Rust FFI library built for your operating system. Install Rust with Cargo and a native C/C++ toolchain; CI uses Rust **1.95.0**. From the repository root, build with:

```bash
bash native/build.sh release
```

Rebuild after upgrading to 0.4.0; the old library lacks `walrus_encode_blob_v2`.

The loader finds the library under `native/walrus_ffi/target/release/`. `WALRUS_FFI_LIB` can select an explicit library path. A macOS `.dylib` cannot satisfy Linux's `.so` requirement; CI builds the Linux library before running the full suite. HTTP-only fixture tests and browser tests do not require the native encoder. An unavailable encoder does not fall back to a protocol-compatible Dart implementation.

## Architecture

```
lib/
  dartus.dart              # HTTP client, wallet writes and shared types
  direct.dart              # Direct client, write flows, native encoding
  src/
    cache/                 # Disk cache on native; memory cache on web
    chain/                 # On-chain readers: SystemStateReader, CommitteeResolver
    client/                # WalrusClient (HTTP), WalrusDirectClient (direct),
                           # WriteBlobFlow, WriteFilesFlow
    constants/             # Network presets (testnet/mainnet package IDs)
    contracts/             # WalrusTransactionBuilder — Sui Move call construction
    crypto/                # BLS12-381 provider interface + bls_dart adapter
    encoding/              # WalrusBlobEncoder (Rust FFI), WasmBlobEncoder
                           # (web), BCS parser, encoding abstractions
    errors/                # Typed error hierarchy (18+ classes)
    files/                 # WalrusFile, WalrusBlob, readers (quilt, blob)
    logging/               # Shared log utilities
    models/                # WalrusApiError, protocol types, storage node types
    network/               # RequestExecutor — shared HTTP with timeout/TLS
    storage_node/          # StorageNodeClient — sliver read/write
    upload_relay/          # UploadRelayClient — relay encoding + tips
    wallet/                # WalrusWriter, signers, WalrusChainReader (gRPC)
    utils/                 # blob ID utils, encoding utils, quilts,
                           # randomness, retry, object data loader
```

### Key design patterns

- **Cache policy**: `getBlob` and `getBlobAsFile` use the byte cache. `getBlobByObjectId` bypasses it. `getBlobAsFileStreaming` also bypasses cache reads and writes so large files are not accumulated in memory.
- **Query builder helper**: Upload methods share `_buildQueryParameters` for optional Walrus parameters (`epochs`, `deletable`, `send_object_to`). Extend that helper rather than constructing query strings inline.
- **Centralized HTTP**: HTTP requests go through `RequestExecutor.send`. Response bodies are consumed by `WalrusClient`.
- **JWT uniformity**: Auth flows through `setJwtToken` / `clearJwtToken` at the instance level, with method-level overrides. Avoid introducing custom headers.
- **Error hierarchy**: HTTP mode surfaces `WalrusApiError`. Direct mode uses `WalrusClientError` and `RetryableWalrusClientError`; its protocol state can be refreshed with `WalrusDirectClient.reset()`.

## Running Tests

```bash
# Specific local test file
flutter test test/blob_cache_test.dart

# With verbose output
flutter test test/blob_cache_test.dart --reporter expanded

# Full deterministic suite (no external network requests or uploads)
flutter test --no-pub

# Browser runtime checks (JavaScript, requires Chrome)
flutter test --no-pub --platform chrome test/browser/ test/cache_regression_test.dart
```

Use Flutter for the full suite: direct-mode dependencies require `dart:ui`. `dart test` alone is not the full validation command.

**Network boundary:** default tests live in `test/` and use fixtures, injected clients, or loopback servers. `test/flutter_test_config.dart` blocks external native HTTP requests during `flutter test`. Browser tests use mocked HTTP. Test discovery, rather than `--tags unit`, selects the complete deterministic suite.

Opt-in live tests live separately in `live_test/`. A read check requires `DARTUS_LIVE_AGGREGATOR`, `DARTUS_LIVE_BLOB_ID`, and `DARTUS_LIVE_EXPECTED_TEXT`, then:

```bash
flutter test --no-pub live_test/http_live_read_test.dart --tags integration
```

The upload check requires `DARTUS_LIVE_PUBLISHER`, `DARTUS_LIVE_AGGREGATOR`, and explicit `DARTUS_RUN_LIVE_WRITES=true`; it does not need the read fixture's blob ID or expected text. Use an authorized test publisher; it writes a deletable blob for one epoch:

```bash
flutter test --no-pub live_test/http_live_upload_test.dart --tags live-write
```

A read-only native gRPC smoke check reads system state, committee and pricing from
both public network presets. It performs no transactions:

```bash
DARTUS_RUN_LIVE_READS=true flutter test --no-pub live_test/direct_grpc_read_test.dart
```

An optional native BLS check uses deterministic public signature fixtures and
requires the separate `bls_dart` native library (it makes no network requests):

```bash
DARTUS_BLS_LIBRARY=/absolute/path/to/libbls_dart.dylib \
  flutter test --no-pub live_test/native_bls_provider_test.dart
```

Use the appropriate library filename for your platform. This is separate from
Dartus's `libwalrus_ffi` encoder library.

The wallet write check spends WAL and SUI from a throwaway key (`DARTUS_RUN_LIVE_WRITES=true`, `DARTUS_LIVE_ED25519_SEED`, optional `DARTUS_LIVE_NETWORK`):

```bash
flutter test --no-pub live_test/wallet_write_live_test.dart --tags live-write
```

Each live command fails on missing configuration or request errors. None runs in CI. A passing mock suite is not evidence of a live mainnet roundtrip. Browser tests run the dart2js build, including `walrus-wasm` metadata in a Web Worker; they do not cover dart2wasm or native encoding.

## Code Style

- Follow [Effective Dart](https://dart.dev/effective-dart) guidelines.
- Run `dart format .` before committing.
- Ensure `dart analyze --fatal-infos` reports zero issues.
- The `analysis_options.yaml` enables `strict-casts`, `strict-inference`, and `strict-raw-types`.
- Document all public APIs with `///` doc comments. Include code examples for complex methods.
- Prefix private helpers with `_`.

## Commit Conventions

Use clear, descriptive commit messages:

```
feat: add getOwnedBlobs method to WalrusDirectClient
fix: handle empty committee response in CommitteeResolver
docs: update README installation section
test: add blob cache eviction edge cases
refactor: extract shared query builder into utils
chore: update bls_dart dependency to published version
```

## Pull Requests

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/my-feature`).
3. Make your changes with tests.
4. Ensure all checks pass:
   ```bash
   dart format --output=none --set-exit-if-changed lib test live_test tool
   dart analyze --fatal-infos
   flutter test --no-pub
   flutter test --no-pub --platform chrome test/browser/ test/cache_regression_test.dart
   ```
   Report exact commands and any failures. Run live tests only when deliberately validating that network behavior.
5. Commit with clear messages.
6. Push and create a pull request.

## Adding New Features

1. **Add the implementation** in the appropriate `lib/src/` directory.
2. **Export** HTTP-safe symbols from `lib/dartus.dart`; put native/direct-mode symbols in `lib/direct.dart`.
3. **Add tests** under `test/`. Prefer unit tests; use integration tests sparingly.
4. **Document** with `///` doc comments and update `README.md` if the feature is user-facing.
5. **Update `CHANGELOG.md`** under the `[Unreleased]` section.

## Reporting Issues

File issues at [github.com/Immadominion/Dartus/issues](https://github.com/Immadominion/Dartus/issues) with:

- Dart/Flutter SDK version
- Platform (macOS, iOS, Android, Linux, Windows, web)
- Minimal reproduction steps
- Full error output (stack traces, `dart analyze` output)

Remove credentials and private data from reports. Explain which work you did and credit collaborators or substantial assistance in your PR.
