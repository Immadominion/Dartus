/// Dart SDK for Walrus decentralized blob storage.
///
/// Dartus provides upload, download, caching, and streaming capabilities
/// for interacting with Walrus storage nodes. It supports three modes:
/// HTTP (publisher/aggregator), relay (upload relay + wallet signing),
/// and direct (client-side encoding + storage node interaction).
///
/// Works with pure Dart projects and Flutter apps on mobile,
/// desktop, and (HTTP mode) web platforms.
///
/// ## Quick Start — HTTP Mode
///
/// ```dart
/// import 'package:dartus/dartus.dart';
///
/// final client = WalrusClient(
///   publisherBaseUrl: Uri.parse('https://publisher.walrus-testnet.walrus.space'),
///   aggregatorBaseUrl: Uri.parse('https://aggregator.walrus-testnet.walrus.space'),
/// );
///
/// // Upload
/// final response = await client.putBlob(data: imageBytes);
///
/// // Download (with automatic caching)
/// final data = await client.getBlob(blobId);
///
/// await client.close();
/// ```
///
/// ## Quick Start — Direct Mode
///
/// ```dart
/// import 'package:dartus/dartus.dart';
///
/// final client = WalrusDirectClient.fromNetwork(
///   network: WalrusNetwork.testnet,
/// );
///
/// // Read a blob
/// final data = await client.readBlob(blobId: blobId);
///
/// // Get a high-level handle
/// final blob = await client.getBlob(blobId: blobId);
/// final text = await blob.text();
///
/// client.close();
/// ```
///
/// ## Features
///
/// ### Phase 1 — HTTP Publisher/Aggregator
/// * Upload: [WalrusClient.putBlob], [WalrusClient.putBlobFromFile], [WalrusClient.putBlobStreaming]
/// * Download: [WalrusClient.getBlob], [WalrusClient.getBlobByObjectId], [WalrusClient.getBlobAsFile]
/// * Metadata: [WalrusClient.getBlobMetadata]
/// * Caching: [BlobCache] with LRU eviction
/// * Authentication: JWT via [WalrusClient.setJwtToken]
/// * Error handling: [WalrusApiError]
///
/// ### Phase 2 — Wallet Integration & Upload Relay
/// * Wallet-integrated uploads: [WalrusDirectClient]
/// * Multi-step dApp flow: [WriteBlobFlow]
/// * Upload relay: [UploadRelayClient]
/// * Transaction building: [WalrusTransactionBuilder]
/// * Network constants: [WalrusNetwork], [WalrusPackageConfig]
///
/// ### Phase 3 — Full Direct Mode (Client-Side Encoding)
/// * Client-side erasure coding: [WalrusBlobEncoder]
/// * Storage node interaction: [StorageNodeClient]
/// * Encoding utilities: [EncodingUtils]
/// * Storage node types: [StorageNodeInfo], [SliverData], [EncodedBlob]
///
/// ### Phase 4 — BLS12-381 Cryptography
/// * BLS provider interface: [BlsProvider]
/// * Published implementation: [BlsDartProvider] via `bls_dart` package
library;

// Phase 1 — HTTP Publisher/Aggregator
export 'src/cache/blob_cache.dart';
export 'src/client/walrus_client.dart';
export 'src/models/walrus_api_error.dart';

// Phase 2 — Wallet Integration & Upload Relay
export 'src/chain/committee_resolver.dart';
export 'src/chain/system_state_reader.dart';
export 'src/client/walrus_direct_client.dart';
export 'src/client/write_blob_flow.dart';
export 'src/constants/walrus_constants.dart';
export 'src/contracts/transaction_builder.dart';
export 'src/encoding/blob_encoder.dart';
export 'src/models/protocol_types.dart';
export 'src/upload_relay/upload_relay_client.dart';

// Phase 3 — Full Direct Mode (Client-Side Encoding)
export 'src/encoding/walrus_blob_encoder.dart';
export 'src/encoding/walrus_ffi_bindings.dart';
export 'src/errors/walrus_errors.dart';
export 'src/models/storage_node_types.dart';
export 'src/storage_node/storage_node_client.dart';
export 'src/utils/encoding_utils.dart';
export 'src/utils/randomness.dart';
export 'src/utils/retry.dart';

// Phase 3+ — File Abstractions, Quilts, Blob ID Utilities, Readers
export 'src/client/write_files_flow.dart';
export 'src/encoding/bcs_parser.dart';
export 'src/files/blob.dart';
export 'src/files/file.dart';
export 'src/files/readers/blob_reader.dart';
export 'src/files/readers/quilt_file_reader.dart';
export 'src/files/readers/quilt_reader.dart';
export 'src/utils/blob_id_utils.dart';
export 'src/utils/object_data_loader.dart';
export 'src/utils/quilts.dart';

// BLS12-381 interface (Phase 4)
export 'src/crypto/bls_dart_provider.dart';
export 'src/crypto/bls_provider.dart';
