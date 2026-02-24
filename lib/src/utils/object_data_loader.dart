/// A batched, caching object loader for Sui on-chain data.
///
/// Mirrors the TypeScript SDK's `SuiObjectDataLoader` from
/// `utils/object-loader.ts`, which uses the `dataloader` npm package
/// to batch and cache `getObject` / `getObjects` calls.
///
/// This implementation provides:
/// - **Caching**: Objects fetched once are stored in-memory and returned
///   from cache on subsequent lookups.
/// - **Batch loading**: Multiple concurrent `load()` calls are coalesced
///   into a single `getObjects` multiget RPC call.
/// - **Dynamic field support**: `loadFieldObject` resolves dynamic fields
///   by deriving the field ID from a parent + name + type key.
library;

import 'dart:async';

import 'package:sui/sui.dart';

/// A batched, caching Sui object loader.
///
/// Usage:
/// ```dart
/// final loader = SuiObjectDataLoader(suiClient: client);
///
/// // Load a single object (cached after first fetch).
/// final obj = await loader.load('0x...');
///
/// // Load multiple objects in a single multiget call.
/// final objs = await loader.loadMany(['0x...', '0x...']);
///
/// // Clear cache to force re-fetch.
/// loader.clearAll();
/// ```
class SuiObjectDataLoader {
  final SuiClient _suiClient;

  /// In-memory cache: object ID -> fetched object data.
  final Map<String, SuiObjectResponse> _cache = {};

  /// Pending load requests batched together.
  ///
  /// When the first `load()` call is made in a microtask cycle,
  /// subsequent calls within the same cycle are batched together.
  /// At the end of the microtask, all pending IDs are fetched in
  /// a single `multiGetObjects()` RPC call.
  List<_PendingLoad>? _pendingBatch;
  bool _batchScheduled = false;

  /// Cache for dynamic field ID resolution.
  final Map<String, String> _dynamicFieldCache = {};

  SuiObjectDataLoader({required SuiClient suiClient}) : _suiClient = suiClient;

  /// Load a single object by ID.
  ///
  /// Returns cached data if available; otherwise queues a batch fetch.
  Future<SuiObjectResponse> load(String objectId) async {
    // Check cache first.
    final cached = _cache[objectId];
    if (cached != null) return cached;

    // Queue for batch loading.
    return _queueLoad(objectId);
  }

  /// Load multiple objects by ID.
  ///
  /// Returns a list of results in the same order as [objectIds].
  /// Cached objects are returned immediately; uncached objects are
  /// fetched in a single multiget call.
  Future<List<SuiObjectResponse>> loadMany(List<String> objectIds) async {
    // Separate cached from uncached.
    final results = List<SuiObjectResponse?>.filled(objectIds.length, null);
    final uncachedIndices = <int>[];
    final uncachedIds = <String>[];

    for (var i = 0; i < objectIds.length; i++) {
      final cached = _cache[objectIds[i]];
      if (cached != null) {
        results[i] = cached;
      } else {
        uncachedIndices.add(i);
        uncachedIds.add(objectIds[i]);
      }
    }

    if (uncachedIds.isEmpty) {
      return results.cast<SuiObjectResponse>();
    }

    // Fetch uncached objects in a single RPC call.
    final fetched = await _fetchObjects(uncachedIds);
    for (var i = 0; i < uncachedIndices.length; i++) {
      results[uncachedIndices[i]] = fetched[i];
    }

    return results.cast<SuiObjectResponse>();
  }

  /// Load multiple objects and throw if any are missing or errored.
  ///
  /// Returns a list of results in the same order as [objectIds].
  /// Throws [StateError] if any object could not be loaded.
  Future<List<SuiObjectResponse>> loadManyOrThrow(
    List<String> objectIds,
  ) async {
    final results = await loadMany(objectIds);
    for (var i = 0; i < results.length; i++) {
      final obj = results[i];
      if (obj.data == null) {
        throw StateError(
          'Object ${objectIds[i]} not found or errored: '
          '${obj.error?.code ?? "unknown error"}',
        );
      }
    }
    return results;
  }

  /// Load a dynamic field object by parent, field name, and type.
  ///
  /// Caches the resolved dynamic field ID so subsequent calls for
  /// the same parent + name + type are instant lookups.
  ///
  /// Mirrors the TS SDK's `SuiObjectDataLoader.loadFieldObject()`.
  Future<SuiObjectResponse> loadFieldObject({
    required String parentId,
    required String name,
    required String type,
  }) async {
    final cacheKey = '$parentId:$name:$type';
    final cachedFieldId = _dynamicFieldCache[cacheKey];

    if (cachedFieldId != null) {
      return load(cachedFieldId);
    }

    // Fetch the dynamic field to get its object ID.
    final dynamicField = await _suiClient.getDynamicFieldObject(
      parentId,
      type,
      name,
    );

    final fieldObjectId = dynamicField.data?.objectId;
    if (fieldObjectId == null) {
      throw StateError(
        'Dynamic field ($name : $type) not found on object $parentId',
      );
    }

    _dynamicFieldCache[cacheKey] = fieldObjectId;
    return load(fieldObjectId);
  }

  /// Clear all cached objects.
  void clearAll() {
    _cache.clear();
    _dynamicFieldCache.clear();
  }

  /// Clear a single cached object.
  void clear(String objectId) {
    _cache.remove(objectId);
  }

  /// Number of objects currently cached.
  int get cacheSize => _cache.length;

  // -------------------------------------------------------------------------
  // Internal batching
  // -------------------------------------------------------------------------

  /// Queue a single object ID for batch loading.
  Future<SuiObjectResponse> _queueLoad(String objectId) {
    _pendingBatch ??= [];

    // Check if this ID is already queued.
    for (final pending in _pendingBatch!) {
      if (pending.objectId == objectId) {
        return pending.completer.future;
      }
    }

    final completer = Completer<SuiObjectResponse>();
    _pendingBatch!.add(_PendingLoad(objectId, completer));

    // Schedule the batch flush on the next microtask if not already.
    if (!_batchScheduled) {
      _batchScheduled = true;
      Future.microtask(_flushBatch);
    }

    return completer.future;
  }

  /// Flush all pending loads in a single multiget RPC call.
  Future<void> _flushBatch() async {
    _batchScheduled = false;
    final batch = _pendingBatch;
    _pendingBatch = null;

    if (batch == null || batch.isEmpty) return;

    final ids = batch.map((p) => p.objectId).toList();

    try {
      final results = await _fetchObjects(ids);

      for (var i = 0; i < batch.length; i++) {
        batch[i].completer.complete(results[i]);
      }
    } catch (e, st) {
      for (final pending in batch) {
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(e, st);
        }
      }
    }
  }

  /// Fetch objects from the Sui RPC, caching results.
  Future<List<SuiObjectResponse>> _fetchObjects(List<String> ids) async {
    final results = await _suiClient.multiGetObjects(
      ids,
      options: SuiObjectDataOptions(
        showContent: true,
        showType: true,
        showOwner: true,
      ),
    );

    // Cache results.
    for (var i = 0; i < ids.length; i++) {
      _cache[ids[i]] = results[i];
    }

    return results;
  }
}

/// Internal pending load request.
class _PendingLoad {
  final String objectId;
  final Completer<SuiObjectResponse> completer;

  _PendingLoad(this.objectId, this.completer);
}
