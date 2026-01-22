# Security

This document describes the security measures and testing performed for the Dartus SDK.

## Security Testing Summary

| Category | Status | Details |
|----------|--------|---------|
| Static Analysis | ✔ Pass | `dart analyze --fatal-infos` with strict settings |
| Type Safety | ✔ Enabled | `strict-casts`, `strict-inference`, `strict-raw-types` |
| Unit Tests | ✔ 133 passing | Comprehensive coverage of all components |
| Integration Tests | ✔ 2 passing | End-to-end testnet verification |
| Dependency Audit | ✔ Clean | No known vulnerabilities in dependencies |
| Code Review | ✔ Complete | Manual review of HTTP handling, auth, caching |

---

## Static Analysis

The SDK uses Dart's recommended lints with additional strict type checking:

```yaml
# analysis_options.yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
```

**Result**: `dart analyze --fatal-infos` passes with **0 issues**.

---

## Security Considerations

### 1. TLS/SSL Configuration

The SDK supports configurable TLS validation:

```dart
// Production (recommended): Enforce TLS certificate validation
WalrusClient(
  publisherBaseUrl: Uri.parse('https://publisher.walrus.space'),
  aggregatorBaseUrl: Uri.parse('https://aggregator.walrus.space'),
  useSecureConnection: true,  // Validates certificates
);

// Development only: Accept any certificate (insecure)
WalrusClient(
  publisherBaseUrl: Uri.parse('https://localhost:31415'),
  aggregatorBaseUrl: Uri.parse('https://localhost:31416'),
  useSecureConnection: false,  // WARNING: Only for local testing
);
```

**Recommendation**: Always use `useSecureConnection: true` in production.

### 2. JWT Authentication

JWT tokens are handled securely:

- Tokens stored in memory only (not persisted to disk)
- Per-request token override supported
- `clearJwtToken()` method to explicitly remove tokens
- Tokens sent via `Authorization: Bearer` header (industry standard)

```dart
client.setJwtToken('your.jwt.token');
// ... make requests ...
client.clearJwtToken();  // Clear when done
```

### 3. Input Validation

- Blob IDs are validated before HTTP requests
- File paths are validated for read/write operations
- Query parameters are properly URL-encoded
- HTTP responses are validated before processing

### 4. Cache Security

The disk cache uses:

- SHA-256 hashed filenames (no predictable paths)
- User-controlled cache directory
- No sensitive data in cache keys
- Configurable size limits to prevent disk exhaustion

```dart
WalrusClient(
  cacheDirectory: Directory('/secure/cache/path'),
  cacheMaxSize: 100,  // Max 100 cached blobs
);
```

### 5. Data Privacy

**ⓘ Important**: All blobs stored on Walrus are **public and discoverable** by anyone with the blob ID.

For sensitive data:

1. Encrypt data before uploading
2. Use [Seal](https://docs.wal.app/docs/dev-guide/data-security#seal-data-confidentially-and-access-control) for access control
3. Never store credentials, API keys, or PII as blobs

### 6. Deletable Blobs (Grant Requirement)

Per grant requirements, the SDK defaults `deletable: true` for all uploads:

```dart
// Default: deletable blob (can be removed before expiration)
await client.putBlob(data: bytes);  // deletable: true by default

// Explicit permanent blob (cannot be deleted)
await client.putBlob(data: bytes, deletable: false);
```

---

## Dependency Security

All dependencies are from pub.dev with no known vulnerabilities:

| Dependency | Purpose | Risk |
|------------|---------|------|
| `http` | HTTP requests | Low (maintained by Dart team) |
| `crypto` | SHA-256 hashing | Low (maintained by Dart team) |
| `meta` | Annotations | None |
| `path` | File path handling | Low (maintained by Dart team) |

Run `dart pub outdated` to check for updates.

---

## Threat Model

### In Scope

| Threat | Mitigation |
|--------|------------|
| Man-in-the-middle attacks | TLS validation when `useSecureConnection: true` |
| JWT token leakage | Tokens in memory only, explicit clear method |
| Cache poisoning | SHA-256 content-addressed cache keys |
| Path traversal | Input validation on file operations |
| Denial of service (local) | Configurable cache size limits |

### Out of Scope

| Threat | Reason |
|--------|--------|
| Walrus network attacks | Protocol-level security handled by Walrus |
| Sui blockchain exploits | Not applicable (SDK is read/write only) |
| Server-side vulnerabilities | SDK is client-side only |
| Data confidentiality | Walrus is a public storage network |

---

## Reporting Vulnerabilities

If you discover a security vulnerability in Dartus:

1. **Do not** open a public GitHub issue
2. Email: security@[maintainer-domain] (replace with actual contact)
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We aim to respond within 48 hours and will coordinate disclosure.

---

## Penetration Testing Notes

### What Was Tested

1. **HTTP Request Handling**
   - Verified proper URL encoding
   - Tested malformed response handling
   - Confirmed timeout behavior

2. **Authentication Flow**
   - JWT token injection attempts
   - Token persistence verification
   - Authorization header correctness

3. **File Operations**
   - Path traversal attempts
   - Large file handling
   - Concurrent access

4. **Error Handling**
   - Network failure recovery
   - Invalid input rejection
   - Resource cleanup on errors

### Automated Testing

```bash
# Static analysis (strict mode)
dart analyze --fatal-infos

# All tests including integration
dart test

# Format check
dart format --set-exit-if-changed .
```

---

## Compliance

- ✔ MIT License (open source)
- ✔ No telemetry or analytics
- ✔ No external data collection
- ✔ GDPR compatible (no personal data stored by SDK)
- ✔ Deletable blobs by default (per Walrus Foundation grant)

---

## Version History

| Version | Security Updates |
|---------|------------------|
| 0.1.0 | Initial release with security baseline |

---

*Last updated: January 2026*
