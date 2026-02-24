//! `walrus_ffi` — C-ABI FFI bridge for canonical Walrus encoding.
//!
//! Thin wrapper around the official [`walrus-core`] crate from MystenLabs.
//! This guarantees bit-identical blob IDs, Merkle roots, and slivers with the
//! Walrus network — the same approach used by the TS SDK's `walrus-wasm` bridge.
//!
//! Exposed as a C-ABI dynamic library (`cdylib`) for consumption by the Dartus
//! Dart SDK via `dart:ffi`.

use std::num::NonZeroU16;
use std::slice;

use walrus_core::encoding::{source_symbols_for_n_shards, EncodingConfig, EncodingFactory};
use walrus_core::encoding::{Primary, SliverData};
use walrus_core::metadata::BlobMetadataApi;
use walrus_core::EncodingType;
use walrus_core::SliverIndex;

// ============================================================================
// C-ABI Exports — thin wrappers around walrus-core
// ============================================================================

/// Compute blob metadata without returning slivers.
///
/// Delegates to `walrus-core`'s `EncodingFactory::compute_metadata` which is
/// the same codepath used by the TS SDK's walrus-wasm bridge. This guarantees
/// bit-identical blob IDs with the Walrus network.
///
/// # Safety
///
/// - `data_ptr` must point to `data_len` valid bytes (or be null when `data_len == 0`).
/// - All `out_*` pointers must be non-null and point to writeable memory of
///   the documented size.
///
/// Returns 0 on success, negative on error.
#[no_mangle]
pub unsafe extern "C" fn walrus_compute_metadata(
    n_shards: u16,
    data_ptr: *const u8,
    data_len: usize,
    out_blob_id: *mut u8,           // 32 bytes
    out_root_hash: *mut u8,         // 32 bytes
    out_unencoded_length: *mut u64, // 8 bytes
    out_encoding_type: *mut u8,     // 1 byte
) -> i32 {
    if n_shards == 0
        || out_blob_id.is_null()
        || out_root_hash.is_null()
        || out_unencoded_length.is_null()
        || out_encoding_type.is_null()
    {
        return -1;
    }

    let data: &[u8] = if data_len == 0 || data_ptr.is_null() {
        &[]
    } else {
        slice::from_raw_parts(data_ptr, data_len)
    };

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let n = NonZeroU16::new(n_shards).unwrap();
        let config = EncodingConfig::new(n);
        let encoder = config.get_for_type(EncodingType::RS2);
        encoder.compute_metadata(data)
    }));

    match result {
        Ok(Ok(verified_metadata)) => {
            // Extract blob ID (32 bytes)
            let blob_id = verified_metadata.blob_id();
            std::ptr::copy_nonoverlapping(blob_id.0.as_ptr(), out_blob_id, 32);

            // Extract root hash from metadata
            let root_hash = verified_metadata.metadata().compute_root_hash();
            std::ptr::copy_nonoverlapping(root_hash.bytes().as_ptr(), out_root_hash, 32);

            // Unencoded length
            *out_unencoded_length = verified_metadata.metadata().unencoded_length();

            // Encoding type (RS2 = 1)
            *out_encoding_type = u8::from(verified_metadata.metadata().encoding_type());

            0
        }
        Ok(Err(_)) => -3, // DataTooLargeError
        Err(_) => -2,     // Panic
    }
}

/// Return the encoding parameters for a given shard/blob configuration.
///
/// Used to pre-allocate buffers on the Dart side before calling
/// `walrus_encode_blob`.
///
/// Returns 0 on success.
#[no_mangle]
pub extern "C" fn walrus_encoding_params(
    n_shards: u16,
    blob_len: u64,
    out_primary_symbols: *mut u32,
    out_secondary_symbols: *mut u32,
    out_symbol_size: *mut u32,
    out_primary_sliver_size: *mut u64,
    out_secondary_sliver_size: *mut u64,
) -> i32 {
    let n = match NonZeroU16::new(n_shards) {
        Some(n) => n,
        None => return -1,
    };

    let (primary, secondary) = source_symbols_for_n_shards(n);
    let p = primary.get() as u32;
    let s = secondary.get() as u32;

    let config = EncodingConfig::new(n);
    let encoder = config.get_for_type(EncodingType::RS2);

    let ss = match encoder.symbol_size_for_blob(blob_len) {
        Ok(sz) => sz.get() as u32,
        Err(_) => return -3,
    };

    unsafe {
        if !out_primary_symbols.is_null() {
            *out_primary_symbols = p;
        }
        if !out_secondary_symbols.is_null() {
            *out_secondary_symbols = s;
        }
        if !out_symbol_size.is_null() {
            *out_symbol_size = ss;
        }
        if !out_primary_sliver_size.is_null() {
            // Primary sliver contains `secondary` symbols of `ss` bytes each
            *out_primary_sliver_size = u64::from(s) * u64::from(ss);
        }
        if !out_secondary_sliver_size.is_null() {
            // Secondary sliver contains `primary` symbols of `ss` bytes each
            *out_secondary_sliver_size = u64::from(p) * u64::from(ss);
        }
    }
    0
}

/// Encode a blob and write all primary + secondary slivers into caller-allocated
/// buffers, plus the metadata outputs.
///
/// Delegates to `walrus-core`'s `EncodingFactory::encode_with_metadata`.
///
/// `out_primary_slivers` and `out_secondary_slivers` must each point to
/// `n_shards` contiguous sliver buffers. Use `walrus_encoding_params` to
/// determine the sizes.
///
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn walrus_encode_blob(
    n_shards: u16,
    data_ptr: *const u8,
    data_len: usize,
    out_primary_slivers: *mut u8, // n_shards × primary_sliver_size bytes
    out_secondary_slivers: *mut u8, // n_shards × secondary_sliver_size bytes
    out_blob_id: *mut u8,         // 32 bytes
    out_root_hash: *mut u8,       // 32 bytes
    out_unencoded_length: *mut u64, // 8 bytes
    out_encoding_type: *mut u8,   // 1 byte
) -> i32 {
    if n_shards == 0
        || out_primary_slivers.is_null()
        || out_secondary_slivers.is_null()
        || out_blob_id.is_null()
        || out_root_hash.is_null()
        || out_unencoded_length.is_null()
        || out_encoding_type.is_null()
    {
        return -1;
    }

    let data: &[u8] = if data_len == 0 || data_ptr.is_null() {
        &[]
    } else {
        slice::from_raw_parts(data_ptr, data_len)
    };

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let n = NonZeroU16::new(n_shards).unwrap();
        let config = EncodingConfig::new(n);
        let encoder = config.get_for_type(EncodingType::RS2);
        encoder.encode_with_metadata(data.to_vec())
    }));

    match result {
        Ok(Ok((sliver_pairs, verified_metadata))) => {
            // Write primary slivers contiguously.
            // Each sliver_pair.primary.symbols.data() gives the raw sliver bytes.
            if !sliver_pairs.is_empty() {
                let pri_size = sliver_pairs[0].primary.symbols.data().len();
                for (i, pair) in sliver_pairs.iter().enumerate() {
                    let src = pair.primary.symbols.data();
                    assert_eq!(src.len(), pri_size);
                    std::ptr::copy_nonoverlapping(
                        src.as_ptr(),
                        out_primary_slivers.add(i * pri_size),
                        pri_size,
                    );
                }

                // Write secondary slivers contiguously.
                // Note: walrus-core reverses secondary slivers relative to pair index.
                // sliver_pairs[i].secondary is the secondary sliver for pair i.
                let sec_size = sliver_pairs[0].secondary.symbols.data().len();
                for (i, pair) in sliver_pairs.iter().enumerate() {
                    let src = pair.secondary.symbols.data();
                    assert_eq!(src.len(), sec_size);
                    std::ptr::copy_nonoverlapping(
                        src.as_ptr(),
                        out_secondary_slivers.add(i * sec_size),
                        sec_size,
                    );
                }
            }

            // Metadata
            let blob_id = verified_metadata.blob_id();
            std::ptr::copy_nonoverlapping(blob_id.0.as_ptr(), out_blob_id, 32);

            let root_hash = verified_metadata.metadata().compute_root_hash();
            std::ptr::copy_nonoverlapping(root_hash.bytes().as_ptr(), out_root_hash, 32);

            *out_unencoded_length = verified_metadata.metadata().unencoded_length();
            *out_encoding_type = u8::from(verified_metadata.metadata().encoding_type());

            0
        }
        Ok(Err(_)) => -3, // DataTooLargeError
        Err(_) => -2,     // Panic
    }
}

// ============================================================================
// Decode — reconstruct blob from primary slivers
// ============================================================================

/// Decode (reconstruct) a blob from a subset of primary slivers.
///
/// Delegates to `walrus-core`'s `EncodingFactory::decode` which uses
/// the same RS2 (reed-solomon-simd) decoder as the Walrus network.
///
/// # Arguments
///
/// - `n_shards`: number of shards in the committee
/// - `blob_size`: original unencoded blob length in bytes
/// - `sliver_data_ptr`: contiguous buffer of all slivers concatenated;
///   each sliver is `sliver_size` bytes
/// - `sliver_indices_ptr`: array of `sliver_count` u16 shard indices
/// - `sliver_count`: number of slivers provided (must be ≥ source_symbols_primary)
/// - `sliver_size`: bytes per sliver (= secondary_symbols × symbol_size, from
///   `walrus_encoding_params`)
/// - `out_blob_ptr`: caller-allocated buffer of at least `blob_size` bytes
/// - `out_blob_len`: receives the actual number of bytes written
///
/// Returns 0 on success, negative on error:
/// - -1: invalid arguments (null pointers, n_shards=0)
/// - -2: panic
/// - -3: decode failed (not enough slivers, corrupt data)
///
/// # Safety
///
/// All pointer arguments must be valid and point to the documented sizes.
#[no_mangle]
pub unsafe extern "C" fn walrus_decode_blob(
    n_shards: u16,
    blob_size: u64,
    sliver_data_ptr: *const u8,
    sliver_indices_ptr: *const u16,
    sliver_count: u32,
    sliver_size: u64,
    out_blob_ptr: *mut u8,
    out_blob_len: *mut u64,
) -> i32 {
    if n_shards == 0
        || sliver_data_ptr.is_null()
        || sliver_indices_ptr.is_null()
        || sliver_count == 0
        || sliver_size == 0
        || out_blob_ptr.is_null()
        || out_blob_len.is_null()
    {
        return -1;
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let n = NonZeroU16::new(n_shards).unwrap();
        let config = EncodingConfig::new(n);
        let encoder = config.get_for_type(EncodingType::RS2);

        let symbol_size = encoder
            .symbol_size_for_blob(blob_size)
            .map_err(|_| "invalid blob size")?;

        // Reconstruct SliverData<Primary> from the flat buffers.
        let indices = slice::from_raw_parts(sliver_indices_ptr, sliver_count as usize);
        let all_bytes = slice::from_raw_parts(
            sliver_data_ptr,
            (sliver_count as u64 * sliver_size) as usize,
        );
        let ss = sliver_size as usize;

        let slivers: Vec<SliverData<Primary>> = (0..sliver_count as usize)
            .map(|i| {
                let raw = &all_bytes[i * ss..(i + 1) * ss];
                let index = SliverIndex(indices[i]);
                SliverData::<Primary>::new(raw, symbol_size, index)
            })
            .collect();

        encoder
            .decode(blob_size, slivers)
            .map_err(|_| "decode failed")
    }));

    match result {
        Ok(Ok(decoded)) => {
            let len = decoded.len().min(blob_size as usize);
            std::ptr::copy_nonoverlapping(decoded.as_ptr(), out_blob_ptr, len);
            *out_blob_len = len as u64;
            0
        }
        Ok(Err(_)) => -3,
        Err(_) => -2,
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }

    #[test]
    fn test_source_symbols_1000() {
        let n = NonZeroU16::new(1000).unwrap();
        let (p, s) = source_symbols_for_n_shards(n);
        assert_eq!(p.get(), 334, "primary symbols for 1000 shards");
        assert_eq!(s.get(), 667, "secondary symbols for 1000 shards");
    }

    #[test]
    fn test_source_symbols_10() {
        let n = NonZeroU16::new(10).unwrap();
        let (p, s) = source_symbols_for_n_shards(n);
        assert_eq!(p.get(), 4, "primary symbols for 10 shards");
        assert_eq!(s.get(), 7, "secondary symbols for 10 shards");
    }

    #[test]
    fn test_encoding_deterministic() {
        let data = vec![42u8; 512];
        let n = NonZeroU16::new(10).unwrap();
        let config = EncodingConfig::new(n);
        let enc = config.get_for_type(EncodingType::RS2);

        let meta1 = enc.compute_metadata(&data).unwrap();
        let meta2 = enc.compute_metadata(&data).unwrap();

        assert_eq!(
            meta1.blob_id(),
            meta2.blob_id(),
            "encoding must be deterministic"
        );
    }

    #[test]
    fn test_c_api_compute_metadata_small_blob() {
        let data: Vec<u8> = (0u8..10).collect();
        let mut blob_id = [0u8; 32];
        let mut root_hash = [0u8; 32];
        let mut unencoded_len: u64 = 0;
        let mut enc_type: u8 = 0;

        let ret = unsafe {
            walrus_compute_metadata(
                1000,
                data.as_ptr(),
                data.len(),
                blob_id.as_mut_ptr(),
                root_hash.as_mut_ptr(),
                &mut unencoded_len,
                &mut enc_type,
            )
        };

        assert_eq!(ret, 0, "C API should return success");
        assert_eq!(unencoded_len, 10);
        assert_eq!(enc_type, 1); // RS2
        eprintln!("blob_id: {}", hex(&blob_id));
        eprintln!("root_hash: {}", hex(&root_hash));
    }

    #[test]
    fn test_c_api_matches_direct_walrus_core() {
        let data: Vec<u8> = (0u8..100).collect();

        // Direct walrus-core call
        let n = NonZeroU16::new(10).unwrap();
        let config = EncodingConfig::new(n);
        let enc = config.get_for_type(EncodingType::RS2);
        let direct_meta = enc.compute_metadata(&data).unwrap();

        // C API call
        let mut blob_id = [0u8; 32];
        let mut root_hash = [0u8; 32];
        let mut unencoded_len: u64 = 0;
        let mut enc_type: u8 = 0;

        let ret = unsafe {
            walrus_compute_metadata(
                10,
                data.as_ptr(),
                data.len(),
                blob_id.as_mut_ptr(),
                root_hash.as_mut_ptr(),
                &mut unencoded_len,
                &mut enc_type,
            )
        };

        assert_eq!(ret, 0);
        assert_eq!(&blob_id, direct_meta.blob_id().0.as_slice());
        assert_eq!(
            &root_hash,
            direct_meta
                .metadata()
                .compute_root_hash()
                .bytes()
                .as_slice()
        );
        assert_eq!(unencoded_len, 100);
    }

    #[test]
    fn test_c_api_null_safety() {
        let ret = unsafe {
            walrus_compute_metadata(
                0, // invalid
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(ret, -1, "should reject n_shards=0");
    }

    #[test]
    fn test_encoding_params() {
        let mut p = 0u32;
        let mut s = 0u32;
        let mut ss = 0u32;
        let mut pri_size = 0u64;
        let mut sec_size = 0u64;

        let ret = walrus_encoding_params(
            1000,
            0, // empty blob
            &mut p,
            &mut s,
            &mut ss,
            &mut pri_size,
            &mut sec_size,
        );

        assert_eq!(ret, 0);
        assert_eq!(p, 334);
        assert_eq!(s, 667);
    }

    #[test]
    fn test_c_api_encode_blob() {
        let data: Vec<u8> = (0u8..100).collect();
        let n_shards: u16 = 10;

        // Get params first
        let mut p = 0u32;
        let mut s = 0u32;
        let mut ss = 0u32;
        let mut pri_sliver_size = 0u64;
        let mut sec_sliver_size = 0u64;

        walrus_encoding_params(
            n_shards,
            data.len() as u64,
            &mut p,
            &mut s,
            &mut ss,
            &mut pri_sliver_size,
            &mut sec_sliver_size,
        );

        let n = n_shards as usize;
        let total_pri = n * pri_sliver_size as usize;
        let total_sec = n * sec_sliver_size as usize;

        let mut pri_buf = vec![0u8; total_pri];
        let mut sec_buf = vec![0u8; total_sec];
        let mut blob_id = [0u8; 32];
        let mut root_hash = [0u8; 32];
        let mut unencoded_len: u64 = 0;
        let mut enc_type: u8 = 0;

        let ret = unsafe {
            walrus_encode_blob(
                n_shards,
                data.as_ptr(),
                data.len(),
                pri_buf.as_mut_ptr(),
                sec_buf.as_mut_ptr(),
                blob_id.as_mut_ptr(),
                root_hash.as_mut_ptr(),
                &mut unencoded_len,
                &mut enc_type,
            )
        };

        assert_eq!(ret, 0);
        assert_eq!(unencoded_len, 100);
        assert_eq!(enc_type, 1);

        // Verify blob_id matches compute_metadata
        let mut meta_blob_id = [0u8; 32];
        let mut meta_root_hash = [0u8; 32];
        let mut meta_len: u64 = 0;
        let mut meta_enc: u8 = 0;

        unsafe {
            walrus_compute_metadata(
                n_shards,
                data.as_ptr(),
                data.len(),
                meta_blob_id.as_mut_ptr(),
                meta_root_hash.as_mut_ptr(),
                &mut meta_len,
                &mut meta_enc,
            );
        }

        assert_eq!(
            blob_id, meta_blob_id,
            "encode_blob and compute_metadata must produce same blob_id"
        );
        assert_eq!(
            root_hash, meta_root_hash,
            "encode_blob and compute_metadata must produce same root_hash"
        );

        // Verify slivers are non-trivial (not all zeros)
        assert!(
            !pri_buf.iter().all(|&b| b == 0),
            "primary slivers should not be all zeros"
        );
    }

    #[test]
    fn test_empty_blob() {
        let data: &[u8] = &[];
        let mut blob_id = [0u8; 32];
        let mut root_hash = [0u8; 32];
        let mut unencoded_len: u64 = 0;
        let mut enc_type: u8 = 0;

        let ret = unsafe {
            walrus_compute_metadata(
                10,
                data.as_ptr(),
                data.len(),
                blob_id.as_mut_ptr(),
                root_hash.as_mut_ptr(),
                &mut unencoded_len,
                &mut enc_type,
            )
        };

        assert_eq!(ret, 0);
        assert_eq!(unencoded_len, 0);
        eprintln!("empty blob_id (10 shards): {}", hex(&blob_id));
    }

    #[test]
    fn test_encode_decode_roundtrip() {
        let data: Vec<u8> = (0u8..200).collect();
        let n_shards: u16 = 10;

        // Get encoding params.
        let mut p = 0u32;
        let mut _s = 0u32;
        let mut _ss = 0u32;
        let mut pri_sliver_size = 0u64;
        let mut _sec_sliver_size = 0u64;

        walrus_encoding_params(
            n_shards,
            data.len() as u64,
            &mut p,
            &mut _s,
            &mut _ss,
            &mut pri_sliver_size,
            &mut _sec_sliver_size,
        );

        let n = n_shards as usize;
        let total_pri = n * pri_sliver_size as usize;
        let total_sec = n * _sec_sliver_size as usize;

        let mut pri_buf = vec![0u8; total_pri];
        let mut sec_buf = vec![0u8; total_sec];
        let mut blob_id = [0u8; 32];
        let mut root_hash = [0u8; 32];
        let mut unencoded_len: u64 = 0;
        let mut enc_type: u8 = 0;

        // Encode.
        let ret = unsafe {
            walrus_encode_blob(
                n_shards,
                data.as_ptr(),
                data.len(),
                pri_buf.as_mut_ptr(),
                sec_buf.as_mut_ptr(),
                blob_id.as_mut_ptr(),
                root_hash.as_mut_ptr(),
                &mut unencoded_len,
                &mut enc_type,
            )
        };
        assert_eq!(ret, 0);

        // Feed only the first `p` primary slivers (minimum required).
        let sliver_count = p;
        let indices: Vec<u16> = (0..sliver_count as u16).collect();
        let sliver_bytes: Vec<u8> = (0..sliver_count as usize)
            .flat_map(|i| {
                pri_buf[i * pri_sliver_size as usize..(i + 1) * pri_sliver_size as usize].to_vec()
            })
            .collect();

        let mut out_blob = vec![0u8; data.len()];
        let mut out_len: u64 = 0;

        // Decode.
        let ret = unsafe {
            walrus_decode_blob(
                n_shards,
                data.len() as u64,
                sliver_bytes.as_ptr(),
                indices.as_ptr(),
                sliver_count,
                pri_sliver_size,
                out_blob.as_mut_ptr(),
                &mut out_len,
            )
        };

        assert_eq!(ret, 0, "decode should succeed");
        assert_eq!(out_len, data.len() as u64, "decoded length should match");
        assert_eq!(
            &out_blob[..data.len()],
            &data[..],
            "decoded data should match original"
        );
    }
}
