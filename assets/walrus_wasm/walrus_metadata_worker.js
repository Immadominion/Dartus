// Part of Dartus (MIT). Computes Walrus blob metadata with walrus-wasm off the
// page's main thread, so the interface keeps responding while a large file is
// hashed (about a second for small files, several for 100 MB).
//
// Request:  { id, nShards, bytes: ArrayBuffer }
// Response: { id, blobId: Uint8Array, rootHash: Uint8Array, length, type }
//        or { id, error: string }
import init, { BlobEncoder } from './walrus_wasm.js';

const ready = init();

self.onmessage = async ({ data: { id, nShards, bytes } }) => {
  try {
    await ready;
    const encoder = new BlobEncoder(nShards);
    try {
      const [blobId, rootHash, length, type] = encoder.compute_metadata(
        new Uint8Array(bytes),
      );
      self.postMessage({
        id,
        blobId: Uint8Array.from(blobId),
        rootHash: Uint8Array.from(rootHash.Digest),
        length,
        type,
      });
    } finally {
      encoder.free();
    }
  } catch (error) {
    self.postMessage({ id, error: String(error?.message ?? error) });
  }
};
