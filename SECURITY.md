# Security

Dartus 0.4.0 · Updated October 18, 2026.

## Report a vulnerability

Email **[immadominion@gmail.com](mailto:immadominion@gmail.com)** with the affected version, reproduction steps and likely impact. Keep vulnerability details private until addressed. Do not include wallet secrets, credentials or other users' private data.

## Connections and credentials

Default HTTPS clients validate certificates. Injected HTTP clients control their own transport policy. HTTP URLs are accepted but are not encrypted; use HTTPS for remote services. `WalrusClient.useSecureConnection` is retained for compatibility and has no effect.

Publisher JWTs are held in memory and sent in the upload's `Authorization: Bearer` header. `clearJwtToken()` clears the client's reference, not all copies of a token. Keep private publisher credentials out of browser bundles and URLs. Logging is off by default; review custom log handlers and verbose output for sensitive data.

## Wallet transactions

`WalletTransactionSigner` delegates signing to the connected wallet. `KeypairTransactionSigner` holds a key in memory and is intended for scripts and tests. Servers that accept uploaded files should independently verify the Blob object's owner and certification on Sui.

Wallet flows prevent concurrent submissions. An uncertain submission raises `WalrusTransactionOutcomeUnknown` and blocks another submission until resolved with the original transaction digest or confirmation that the original request cannot succeed. Do not classify timeouts or generic errors as definite rejection. Flow state is not persisted across reloads or restarts; check prior transactions before starting another flow. `maxRelayTip` limits the relay fee, not storage fees or gas.

Direct storage-node uploads require an initialized BLS provider and verify confirmations against the committee's keys and the expected message.

## Cache and downloads

- Cache data is plaintext. Blob-ID hashes used as filenames provide neither encryption nor content verification. Use a private directory for sensitive local data. Output paths and cache directories are trusted inputs.
- `cacheMaxSize` limits entries, not bytes. Byte-oriented downloads hold the complete payload in memory. Cache operations are serialized per instance; do not share a directory between independent instances.
- Streaming downloads bypass the cache and stage output before replacement. Existing symlinks remain intact and their targets are replaced; permission bits are checked and preserved. This requires read access and space for a temporary copy. Ownership, ACLs and hard-link identity are not preserved. Prevent concurrent changes to destination paths.
- Failed streaming downloads preserve the previous destination. Temporary cleanup is best effort; crash residue requires manual cleanup. Streaming limits buffering, not disk use. Cache disposal removes temporary directories but keeps explicitly supplied directories.

`WalrusClient.timeout` applies to response headers and then to inactivity between body events. An active transfer can take longer overall. The header timeout does not abort the underlying request. These limits do not apply to every relay or chain operation.

## Public storage and deletion

Walrus content is public by default. A blob ID is not an access-control secret. Encrypt sensitive content before upload and manage encryption keys separately.

Upload APIs require deletable blobs and reject `deletable: false` before submission. Existing non-deletable blobs remain readable. Deletable blobs are not deleted automatically, and deletion cannot remove copies already downloaded by others.
