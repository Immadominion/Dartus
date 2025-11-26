/// Dart SDK for Walrus decentralized blob storage.
///
/// Dartus provides upload, download, caching, and streaming capabilities
/// for interacting with Walrus storage nodes. Works with pure Dart projects
/// and Flutter apps across mobile, desktop, and web platforms.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:dartus/dartus.dart';
///
/// final client = WalrusClient(
///   publisherBaseUrl: Uri.parse('https://publisher.walrus.com'),
///   aggregatorBaseUrl: Uri.parse('https://aggregator.walrus.com'),
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
/// ## Features
///
/// * Upload: [WalrusClient.putBlob], [WalrusClient.putBlobFromFile], [WalrusClient.putBlobStreaming]
/// * Download: [WalrusClient.getBlob], [WalrusClient.getBlobByObjectId], [WalrusClient.getBlobAsFile]
/// * Metadata: [WalrusClient.getBlobMetadata]
/// * Caching: [BlobCache] with LRU eviction
/// * Authentication: JWT via [WalrusClient.setJwtToken]
/// * Error handling: [WalrusApiError]
library;

export 'src/cache/blob_cache.dart';
export 'src/client/walrus_client.dart';
export 'src/models/walrus_api_error.dart';
