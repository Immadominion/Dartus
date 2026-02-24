# Contributing to Dartus

Thank you for your interest in contributing to Dartus! This guide covers setup, architecture, and conventions.

## Development Setup

```bash
# Clone the repository
git clone https://github.com/Immadominion/Dartus.git
cd Dartus

# Install dependencies
dart pub get

# Run tests
dart test

# Run the analyzer (strict mode)
dart analyze --fatal-infos

# Format code
dart format .
```

### Native library (optional)

Direct mode features require the Rust FFI library. Build it with:

```bash
cd native && ./build.sh release && cd ..
```

Without it, tests that require client-side encoding will use the pure-Dart fallback.

## Architecture

```
lib/
  dartus.dart              # Public barrel file — all exports
  src/
    cache/                 # Disk-based LRU blob cache (SHA-256 filenames)
    chain/                 # On-chain readers: SystemStateReader, CommitteeResolver
    client/                # WalrusClient (HTTP), WalrusDirectClient (direct),
                           # WriteBlobFlow, WriteFilesFlow
    constants/             # Network presets (testnet/mainnet package IDs)
    contracts/             # WalrusTransactionBuilder — Sui Move call construction
    crypto/                # BLS12-381 provider interface + bls_dart adapter
    encoding/              # WalrusBlobEncoder (Rust FFI), BCS parser,
                           # BlobEncoder (pure Dart fallback)
    errors/                # Typed error hierarchy (18+ classes)
    files/                 # WalrusFile, WalrusBlob, readers (quilt, blob)
    logging/               # Shared log utilities
    models/                # WalrusApiError, protocol types, storage node types
    network/               # RequestExecutor — shared HTTP with timeout/TLS
    storage_node/          # StorageNodeClient — sliver read/write
    upload_relay/          # UploadRelayClient — relay encoding + tips
    utils/                 # blob ID utils, encoding utils, quilts,
                           # randomness, retry, object data loader
```

### Key design patterns

- **Cache-first reads**: `getBlob` and friends always check the disk cache before hitting the network. After a successful fetch, `cache.put()` is called. Maintain this invariant when adding new download methods.
- **Query builder helper**: Upload methods share `_buildQueryParams` for optional Walrus parameters (`epochs`, `deletable`, `send_object_to`). Extend that helper rather than constructing query strings inline.
- **Centralized HTTP**: All non-streaming HTTP routes go through `RequestExecutor.executeRequest`. Add shared logging or metrics there.
- **JWT uniformity**: Auth flows through `setJwtToken` / `clearJwtToken` at the instance level, with method-level overrides. Avoid introducing custom headers.
- **Error hierarchy**: Errors extend `WalrusClientError`; retryable ones extend `RetryableWalrusClientError`. Add new errors to `lib/src/errors/walrus_errors.dart` and export from `dartus.dart`.

## Running Tests

```bash
# All tests (unit + integration)
dart test

# Specific test file
dart test test/blob_cache_test.dart

# With verbose output
dart test --reporter expanded

# Only unit tests (fast, no network)
dart test --tags unit

# Integration tests (requires network, may be slow)
dart test --tags integration
```

**Live endpoint tests** use `test/test_config.dart` for URLs and known blob IDs. Expect network latency and keep credentials current.

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
   dart format --set-exit-if-changed .
   dart analyze --fatal-infos
   dart test
   ```
5. Commit with clear messages.
6. Push and create a pull request.

## Adding New Features

1. **Add the implementation** in the appropriate `lib/src/` directory.
2. **Export** new public symbols from `lib/dartus.dart`.
3. **Add tests** under `test/`. Prefer unit tests; use integration tests sparingly.
4. **Document** with `///` doc comments and update `README.md` if the feature is user-facing.
5. **Update `CHANGELOG.md`** under the `[Unreleased]` section.

## Reporting Issues

File issues at [github.com/Immadominion/Dartus/issues](https://github.com/Immadominion/Dartus/issues) with:

- Dart/Flutter SDK version
- Platform (macOS, iOS, Android, Linux, Windows)
- Minimal reproduction steps
- Full error output (stack traces, `dart analyze` output)
