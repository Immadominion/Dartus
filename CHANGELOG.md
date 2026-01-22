# Changelog

All notable changes to Dartus will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-01-20

### Added

- Initial release with full Walrus API parity
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
