# Dartus

![Walrus SDK banner](./banner.png)

[![pub package](https://img.shields.io/pub/v/dartus.svg)](https://pub.dev/packages/dartus)
[![pub points](https://img.shields.io/pub/points/dartus)](https://pub.dev/packages/dartus/score)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Dartus is a Dart/Flutter SDK for [Walrus](https://walrus.xyz) blob storage. It provides wallet-paid writes through an upload relay (Flutter web and native), publisher uploads, aggregator downloads, wallet transaction builders, quilts, and native erasure coding.

## Choose an API

| API | Import | Runtime and requirements |
|-----|--------|--------------------------|
| Wallet writes: `WalrusWriter.write` / `writeFiles` | `package:dartus/dartus.dart` | Native or Flutter web; the signer's wallet pays (WAL for storage, SUI for gas and the relay tip); upload relay; Sui gRPC-web |
| HTTP bytes: `WalrusClient.putBlob` / `getBlob` / `getQuiltPatch` | `package:dartus/dartus.dart` | Native or Flutter web; publisher and aggregator endpoints |
| HTTP files: `putBlobFromFile`, `putBlobStreaming`, `getBlobAsFile`, `getBlobAsFileStreaming` | `package:dartus/dartus.dart` | Native only; uses `dart:io` files |
| Relay/direct: `WalrusDirectClient` and write flows | `package:dartus/direct.dart` | Native only; Sui client, wallet for writes, and valid encoding metadata |
| Built-in encoding: `WalrusBlobEncoder` | `package:dartus/direct.dart` | Native `libwalrus_ffi` required for encoding and decoding |

The HTTP publisher operator pays on-chain storage costs and may require authentication or charge for its service. `WalrusWriter` and the direct and relay writes use the user's wallet for SUI gas and WAL storage costs. A relay accepts the raw blob, but registration still needs valid metadata; the built-in metadata encoder uses FFI too.

This checkout prepares 0.4.0. The native direct client now uses Sui gRPC, validates TLS certificates, and verifies storage confirmations with BLS. Its full live write path still needs acceptance testing; unit tests and read-only network checks do not establish mainnet readiness. See [SECURITY.md](SECURITY.md).

All upload APIs require deletable blobs. Passing `deletable: false` fails before submission; existing non-deletable blobs remain readable.

## Installation

Use Flutter with bundled Dart **>=3.11.0 <4.0.0** for this checkout and its dependencies.

```yaml
dependencies:
  dartus: ^0.3.0
```

If your app imports Sui types directly, also declare `sui: ^0.5.1` under dependencies. Then run:

```bash
flutter pub get
```

The installation example above targets the previously published 0.3.0. The 0.4.0 changes in this checkout are not published yet. Use a local path dependency when testing these changes:

```yaml
dependencies:
  dartus:
    path: ../Dartus
```

The path must point from your app to this checkout. Chrome tests cover the HTTP byte API, memory cache and the WASM encoder running in a worker. They use the JavaScript Flutter build; native direct/FFI APIs remain unavailable in browsers.

## HTTP quick start

```dart
import 'dart:typed_data';

import 'package:dartus/dartus.dart';

WalrusClient createHttpClient() => WalrusClient(
  publisherBaseUrl: Uri.parse('https://publisher.walrus-testnet.walrus.space'),
  aggregatorBaseUrl: Uri.parse('https://aggregator.walrus-testnet.walrus.space'),
);

Future<Uint8List> uploadAndRead(WalrusClient client, Uint8List bytes) async {
  final response = await client.putBlob(data: bytes, deletable: true);
  final created = response['newlyCreated'] as Map<String, dynamic>?;
  final object = created?['blobObject'] as Map<String, dynamic>?;
  final certified = response['alreadyCertified'] as Map<String, dynamic>?;
  final blobId = object?['blobId'] ?? certified?['blobId'];
  if (blobId is! String || blobId.isEmpty) {
    throw const FormatException('Publisher did not return a blob ID');
  }
  return client.getBlob(blobId);
}
```

Create the client once, pass your bytes to `uploadAndRead`, and `await client.close()` when finished. Endpoint availability and browser CORS permissions depend on the publisher/aggregator. For an authenticated publisher, set `jwtToken` on the client or upload call; keep private service credentials out of browser bundles.

The exact functions live in [tool/quickstart_http.dart](tool/quickstart_http.dart). Their upload/read behavior is tested with an injected HTTP client for both `newlyCreated` and `alreadyCertified` responses. These tests do not perform a public upload.

### Downloads, caching, and timeouts

- `getBlob(blobId)` and `getBlobAsFile(...)` use the byte cache: files on native, memory in the browser. Cache capacity counts entries, not bytes.
- `getBlobByObjectId(objectId)` downloads through `/v1/blobs/by-object-id/<objectId>`.
- `getBlobAsFileStreaming(...)` reads from the aggregator without using the byte cache. It stages chunks with backpressure and replaces the destination only after success. Existing symlinks remain links and their targets are replaced; permission bits are checked and preserved. This copies the old file once and requires read access and temporary disk space. Ownership, ACLs and hard-link identity are not preserved. Cleanup is best effort; abandoned staging directories require manual cleanup. Prevent concurrent changes to destination paths.
- `timeout` defaults to 30 seconds: one deadline for response headers, then an inactivity timeout between response-body events. A progressing transfer can take longer than 30 seconds overall. A stalled body raises `TimeoutException`; an HTTP error response raises `WalrusApiError` after its body is read. The headers deadline alone does not abort an underlying request.
- `BlobCache.cleanup()` clears stored data and permits reuse. `dispose()` waits for pending cache work, removes temporary storage, and rejects later operations. Explicitly supplied cache directories are kept on disposal.

For native streaming downloads, import `dart:io` and use:

```dart
Future<void> downloadToFile(
  WalrusClient client,
  String blobId,
  File destination,
) => client.getBlobAsFileStreaming(blobId: blobId, destination: destination);
```

## Wallet writes (Flutter web and native)

`WalrusWriter` stores a blob with every cost paid by the person's wallet: WAL for storage, SUI for gas and the upload relay's tip. There is no publisher and no server key. A write takes two approvals:
1. register the blob and pay for it;
2. the bytes go to Mysten's upload relay;
3. certify it.

The `Blob` object belongs to the signer, or to a `recipient` you name.

```dart
final writer = WalrusWriter(network: WalrusNetwork.testnet);
final estimate = await writer.estimate(size: bytes.length, epochs: 5);
final result = await writer.write(
  bytes,
  epochs: 5,
  signer: WalletTransactionSigner(
    address: account.address,
    execute: (tx) async => (await wallet.signAndExecuteTransaction(tx.json)).digest,
  ),
  onStage: (stage) => print(stage), // encoding, registering, uploading, certifying
);
print('${result.blobId} is owned by ${result.blob.owner}');
```

- **Wallets:** a wallet receives `tx.json`, the serialized form `@mysten/sui`'s dApp Kit hands to `sui:signAndExecuteTransaction`. WAL and the SUI tip are already resolved against the signer's coins and address balance, and the wallet adds gas. `sui_wallet_web` provides `signAndExecuteTransaction` for Flutter web. Scripts and tests can use `KeypairTransactionSigner`.
- **Several files:** `writeFiles` stores a batch as one Walrus quilt: one blob, so two approvals and one storage fee for the whole batch. Every blob pays for at least about 64 MB of encoded storage, so this is far cheaper for small files. Each file gets a patch ID; read it with `WalrusClient.getQuiltPatch(patchId)`. The relay accepts one blob per paid transaction, so a quilt is the way to batch.
- **Retrying:** retain the `WalrusWriteFlow` from `writeFlow(...)` (or `writeFilesFlow`). `run(signer)` resumes a recorded registration after a failed upload. A definite wallet decline is retryable when the signer throws `WalrusTransactionNotCommitted` or its `isDefinitelyNotCommitted` callback identifies an explicit rejection. A timeout or lost response raises `WalrusTransactionOutcomeUnknown` and blocks resubmission. Check wallet history, then supply the original digest via `registered` / `certified`; call `confirmNotCommitted()` only when the original request cannot succeed. This state is in memory: a page reload loses it, so check prior transactions before starting a new flow. Too little WAL fails before approval.
- **Relay budget:** set `WalrusWriter(maxRelayTip: BigInt.from(...))` in MIST to reject a relay tip above your limit before approval. Estimates are refreshed when building registration; gas and WAL are separate costs.
- **On the web:** blob metadata comes from Mysten's `walrus-wasm`, running in a Web Worker so the page stays responsive. Flutter bundles the files from `assets/walrus_wasm/` (Apache-2.0; see its README). If your page sends a Content-Security-Policy, allow `worker-src blob:`, `script-src 'self' 'wasm-unsafe-eval'`, and `connect-src` for the Sui full node and the relay. Natively, metadata comes from `libwalrus_ffi` (see below).
- **Chain reads:** these use Sui's gRPC-web API (`package:sui` 0.5), with CORS open for browsers. `WalrusChainReader` also exposes balances, Blob objects and system state.
- **Mainnet:** `WalrusNetwork.mainnet`, with Mysten's mainnet relay (its tip is priced per encoded KiB).

More in [tool/quickstart_wallet.dart](tool/quickstart_wallet.dart). Servers that list what people stored should check the Blob object on Sui (certified, owned by the right address) rather than trust the browser.

## Native encoding setup

From the Dartus repository root, build the included Rust crate:

```bash
cd native
./build.sh release
```

Set a custom library path if it is not found automatically:

```bash
export WALRUS_FFI_LIB=/absolute/path/to/libwalrus_ffi.dylib
```

**Rebuild the native library when upgrading to 0.4.0.** The new `walrus_encode_blob_v2` symbol returns full canonical metadata; old binaries cannot satisfy it. Use the appropriate `.so` or `.dll` library on other supported native targets. There is **no pure-Dart fallback**. `WalrusBlobEncoder.isNativeAvailable` checks availability; encoding/decoding throws `StateError` if the library cannot load. A custom `BlobEncoder` or precomputed metadata can serve certain relay paths, but does not make the native-only `direct.dart` entry point browser-compatible.

Direct storage-node writes also require an initialized `BlsProvider`. If using `BlsDartProvider`, initialize `bls_dart`'s `RustLib` and its separate native library before constructing the client. A missing provider is rejected before registration; callers must initialize their chosen backend. Wallet/relay writes use the relay's certificate and do not require this local BLS provider.

## Native API examples

These functions are checked against the current API in [tool/quickstart_examples.dart](tool/quickstart_examples.dart). They have not been used to submit live transactions as part of the documentation checks.

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/direct.dart';
import 'package:sui/sui.dart';

WalrusDirectClient createNativeClient() => WalrusDirectClient.fromNetwork(
  network: WalrusNetwork.testnet,
  encoder: WalrusBlobEncoder(),
);

Future<Uint8List> readDirect(WalrusDirectClient client, String blobId) =>
    client.readBlob(blobId: blobId);

Future<WriteBlobResult> writeDirect(
  WalrusDirectClient client,
  SuiAccount signer,
) => client.writeBlob(
  blob: utf8.encode('Hello Walrus!'),
  epochs: 3,
  signer: signer,
  deletable: true,
);
```

Call `client.close()` when finished with the native client. `fromNetwork` uses the network's default relay where configured; its override parameter is named `uploadRelay`. A configured encoder is needed for direct decoding and for metadata when it is not provided separately.

### Separate wallet signing from the write flow

The flow runs in a native app. Supply an adapter that signs and executes a `Transaction` and returns the result map, including `digest` and typed `objectChanges`, or explicitly pass the registered `blobObjectId` in the upload options. Merely building the certify transaction does not execute it.

```dart
Future<void> writeWithWallet(
  WalrusDirectClient client,
  String owner,
  Future<Map<String, dynamic>> Function(Transaction) signAndExecute,
) async {
  final flow = await client.writeBlobFlow(blob: utf8.encode('Hello Walrus!'));
  await flow.encode();
  final registerTx = await flow.register(
    WriteBlobFlowRegisterOptions(epochs: 3, owner: owner, deletable: true),
  );
  final txResult = await signAndExecute(registerTx);
  final digest = txResult['digest'];
  if (digest is! String) {
    throw const FormatException('Wallet did not return a transaction digest');
  }
  await flow.upload(
    WriteBlobFlowUploadOptions(digest: digest, txResult: txResult),
  );
  await signAndExecute(flow.certify());
}
```

`WriteBlobFlowRegisterOptions` takes `owner`, not `signer`. `register()` returns a future and must be awaited. Upload options take `digest` plus `txResult` or an explicit `blobObjectId`.

### Files and quilts

`WalrusFile.from` uses named arguments:

```dart
WalrusFile createTextFile() => WalrusFile.from(
  contents: utf8.encode('Hello, World!'),
  identifier: 'hello.txt',
  tags: {'type': 'text'},
);
```

Use `writeFiles` (direct mode) or `WalrusWriter.writeFiles` (wallet writes) to upload a list as a quilt, and `getBlob` / `WalrusBlob.files()` or `WalrusClient.getQuiltPatch` to read a quilt. Local `WalrusFile.bytes()`, `.text()`, `.json()`, and `.getTags()` expose the content and metadata.

## TLS, authentication, and upload policy

The default `WalrusClient` transport uses platform TLS validation for HTTPS. Its `useSecureConnection` argument is retained for source compatibility and has no effect. If you inject `httpClient`, its transport policy applies. HTTP URLs are still allowed and are not encrypted.

This differs from `WalrusDirectClient`: its shared storage-node client currently accepts invalid certificates. Setting an HTTP client's compatibility flag does not fix that direct-mode behavior.

HTTP uploads default to `deletable: true`, but callers can pass `false`. Direct write APIs require an explicit value and also permit `false`. Defaults are not enforcement of a deletable-only policy. Review [SECURITY.md](SECURITY.md) before handling sensitive data or relying on deletion.

## Testing this checkout

Run from the Dartus repository root:

```bash
flutter pub get
flutter test --no-pub
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed lib test live_test tool
```

The default suite is deterministic and blocks external HTTP requests; controlled loopback servers and injected responses are allowed. Use Flutter's runner because some exported dependencies require `dart:ui`. Plain `dart test` works for isolated pure-Dart suites, but does not run the entire package.

Browser checks (Chrome must be installed): HTTP, memory cache, and `walrus-wasm` metadata against TS SDK vectors:

```bash
flutter test --no-pub --platform chrome test/browser/ test/cache_regression_test.dart
```

Optional live reads are outside `test/`. Set `DARTUS_LIVE_AGGREGATOR`, `DARTUS_LIVE_BLOB_ID`, and `DARTUS_LIVE_EXPECTED_TEXT` to an existing fixture, then run:

```bash
flutter test --no-pub live_test/http_live_read_test.dart --tags integration
```

A live wallet write spends real WAL and SUI from a throwaway key you provide (a single blob and a three-file quilt, about 0.001 WAL on testnet):

```bash
DARTUS_RUN_LIVE_WRITES=true DARTUS_LIVE_NETWORK=testnet \
DARTUS_LIVE_ED25519_SEED=<32-byte hex seed> \
flutter test --no-pub live_test/wallet_write_live_test.dart
```

Live publisher upload checks require separate explicit opt-in and a writable endpoint. See [CONTRIBUTING.md](CONTRIBUTING.md) for those commands and the expected environment. No live upload is part of CI. Passing tests or analysis is not a security audit or proof of a working mainnet transaction.

## Examples and API documentation

- The Flutter HTTP example lives in [example/](example/).
- [Dartus-Demo](https://github.com/Immadominion/Dartus-Demo) demonstrates the broader API; its direct paths have the same readiness limits described above.
- [Published API reference](https://pub.dev/documentation/dartus/latest/) describes the hosted release. Run `dart doc` for this checkout's API docs.
- [Contribution setup](CONTRIBUTING.md), [changelog](CHANGELOG.md), and [issue tracker](https://github.com/Immadominion/Dartus/issues).

## License

MIT — see [LICENSE](LICENSE).
