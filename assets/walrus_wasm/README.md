# walrus_wasm (vendored)

`walrus_wasm.js` and `walrus_wasm_bg.wasm` are the unmodified `web/` build of
[`@mysten/walrus-wasm`](https://www.npmjs.com/package/@mysten/walrus-wasm) 0.3.1
by Mysten Labs, licensed under Apache-2.0 (see `LICENSE` in this folder). The
source is `packages/walrus-wasm` in https://github.com/MystenLabs/ts-sdks.

Dartus uses it on Flutter web to compute a blob's metadata (blob ID and root
hash) before registering it on chain. The upload relay does the full erasure
coding, so only `BlobEncoder.compute_metadata` is called.

| File | SHA-256 |
|---|---|
| `walrus_wasm.js` | `f7c1d7ff2c00ea69b206bd5f27bfb411e825156e3cc53a42fdc1e43c5af3932e` |
| `walrus_wasm_bg.wasm` | `217756f2693c98d21922e5638b0a7fce2eb86600a9a7112a7678932d24c4c4f9` |

To update, copy `web/walrus_wasm.js` and `web/walrus_wasm_bg.wasm` from a newer
published package, update the version and hashes above, and run the browser
tests (`flutter test --platform chrome test/browser/`), which check blob IDs
against vectors from the native encoder.
