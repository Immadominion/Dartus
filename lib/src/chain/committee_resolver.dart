/// Resolves the current Walrus storage committee from on-chain state.
///
/// Reads staking pools to discover storage node endpoints and
/// shard assignments, constructing a [CommitteeInfo] usable by
/// [WalrusDirectClient] for direct-mode writes.
///
/// Mirrors the TS SDK's `#getActiveCommittee()` / `#getCommittee()`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sui/sui.dart';

import '../constants/walrus_constants.dart';
import '../models/storage_node_types.dart';
import 'system_state_reader.dart';

/// Resolves the committee from on-chain staking state.
///
/// Usage:
/// ```dart
/// final resolver = CommitteeResolver(
///   suiClient: SuiClient(SuiUrls.testnet),
///   config: testnetWalrusPackageConfig,
/// );
///
/// final committee = await resolver.getActiveCommittee();
/// ```
class CommitteeResolver {
  final SuiClient _suiClient;
  final SystemStateReader _stateReader;

  /// Cached committee info.
  CommitteeInfo? _committee;

  CommitteeResolver({
    required SuiClient suiClient,
    required WalrusPackageConfig config,
    SystemStateReader? stateReader,
  }) : _suiClient = suiClient,
       _stateReader =
           stateReader ??
           SystemStateReader(suiClient: suiClient, config: config);

  /// Access the underlying state reader.
  SystemStateReader get stateReader => _stateReader;

  /// Clear cached committee. Call after epoch changes.
  void reset() {
    _committee = null;
    _stateReader.reset();
  }

  /// Resolve the active committee from on-chain state.
  ///
  /// Flow (mirrors TS SDK):
  /// 1. Read staking state → get committee VecMap + epoch + n_shards
  /// 2. Extract node IDs from committee keys
  /// 3. Fetch staking pool objects by node IDs
  /// 4. Extract `node_info.network_address` from each pool
  /// 5. Build [CommitteeInfo] with shard→node mapping
  ///
  /// Results are cached. Call [reset] to force re-resolution.
  Future<CommitteeInfo> getActiveCommittee() async {
    if (_committee != null) return _committee!;

    final stakingState = await _stateReader.stakingState();
    _committee = await _resolveCommittee(
      committeeMembers: stakingState.committeeMembers,
      nShards: stakingState.nShards,
      epoch: stakingState.epoch,
    );

    return _committee!;
  }

  /// Resolve a committee from a given member map.
  ///
  /// Unlike [getActiveCommittee], this does not use cached state and
  /// accepts an arbitrary committee map (e.g., `previousCommittee`
  /// from staking state during epoch transitions).
  ///
  /// Mirrors TS SDK's `#getCommittee(committee)`.
  Future<CommitteeInfo> resolveCommitteeFromMembers(
    Map<String, List<int>> committeeMembers,
  ) async {
    final stakingState = await _stateReader.stakingState();
    return _resolveCommittee(
      committeeMembers: committeeMembers,
      nShards: stakingState.nShards,
      epoch: stakingState.epoch,
    );
  }

  /// Resolve a committee from a VecMap of node IDs → shard indices.
  Future<CommitteeInfo> _resolveCommittee({
    required Map<String, List<int>> committeeMembers,
    required int nShards,
    required int epoch,
  }) async {
    final nodeIds = committeeMembers.keys.toList();

    if (nodeIds.isEmpty) {
      throw StateError('Committee has no members');
    }

    // Fetch staking pool objects for all committee members.
    // The TS SDK uses `#objectLoader.loadManyOrThrow(nodeIds, StakingPool)`.
    // In the Walrus protocol, committee node IDs ARE staking pool object IDs.
    final pools = await _fetchStakingPools(nodeIds);

    // Build shard → node mapping.
    final byShardIndex = <int, StorageNodeInfo>{};

    for (var i = 0; i < nodeIds.length; i++) {
      final nodeId = nodeIds[i];
      final pool = pools[nodeId];

      if (pool == null) {
        // Skip nodes whose pools couldn't be fetched.
        continue;
      }

      final shardIndices = committeeMembers[nodeId] ?? [];

      final node = StorageNodeInfo(
        nodeId: nodeId,
        endpointUrl: pool.networkUrl,
        shardIndices: shardIndices,
        publicKey: pool.publicKey,
      );

      for (final shardIndex in shardIndices) {
        byShardIndex[shardIndex] = node;
      }
    }

    return CommitteeInfo(
      numShards: nShards,
      epoch: epoch,
      nodeByShardIndex: byShardIndex,
    );
  }

  /// Fetch staking pool objects by their IDs and extract node info.
  ///
  /// Mirrors TS SDK's `#stakingPool(committee)`.
  Future<Map<String, _StakingPoolInfo>> _fetchStakingPools(
    List<String> nodeIds,
  ) async {
    final result = <String, _StakingPoolInfo>{};

    // Batch fetch in chunks of 50 (Sui RPC limit).
    const maxPerBatch = 50;
    for (var i = 0; i < nodeIds.length; i += maxPerBatch) {
      final end = (i + maxPerBatch > nodeIds.length)
          ? nodeIds.length
          : i + maxPerBatch;
      final batch = nodeIds.sublist(i, end);

      final responses = await _suiClient.multiGetObjects(
        batch,
        options: SuiObjectDataOptions(showContent: true),
      );

      for (var j = 0; j < batch.length; j++) {
        final nodeId = batch[j];
        final resp = responses[j];

        if (resp.error != null || resp.data?.content == null) {
          continue;
        }

        final pool = _parseStakingPool(resp.data!.content!);
        if (pool != null) {
          result[nodeId] = pool;
        }
      }
    }

    return result;
  }

  /// Parse a StakingPool Move object to extract node_info.
  ///
  /// StakingPool fields include `node_info` which has:
  /// - `name`: string
  /// - `node_id`: address
  /// - `network_address`: string (hostname:port or domain)
  ///
  /// Mirrors TS SDK's `StakingPool.node_info` field.
  _StakingPoolInfo? _parseStakingPool(dynamic content) {
    try {
      final fields = _extractFields(content);
      final nodeInfo = fields['node_info'];

      if (nodeInfo is! Map<String, dynamic>) return null;

      final nodeInfoFields = nodeInfo.containsKey('fields')
          ? nodeInfo['fields'] as Map<String, dynamic>
          : nodeInfo;

      final networkAddress = nodeInfoFields['network_address'] as String?;
      final nodeId = nodeInfoFields['node_id'] as String?;

      if (networkAddress == null || nodeId == null) return null;

      // Extract BLS public key from node_info.public_key.
      // On-chain this is a `group_ops::Element<G1>` stored as raw bytes.
      Uint8List? publicKey;
      final pkField = nodeInfoFields['public_key'];
      if (pkField != null) {
        publicKey = _extractPublicKeyBytes(pkField);
      }

      // The TS SDK prepends `https://` to the network_address.
      final url = networkAddress.startsWith('http')
          ? networkAddress
          : 'https://$networkAddress';

      return _StakingPoolInfo(
        nodeId: nodeId,
        networkUrl: url,
        publicKey: publicKey,
      );
    } catch (_) {
      return null;
    }
  }

  /// Extract 'fields' from Move struct content.
  ///
  /// Handles both `SuiMoveObject` (typed class from the `sui` package)
  /// and raw `Map<String, dynamic>` (e.g. from dynamic field responses).
  Map<String, dynamic> _extractFields(dynamic content) {
    // SuiMoveObject from sui package — access .fields directly.
    if (content is SuiMoveObject) {
      final f = content.fields;
      if (f is Map<String, dynamic>) return f;
      return {};
    }
    if (content is Map<String, dynamic>) {
      if (content.containsKey('fields')) {
        final fields = content['fields'];
        if (fields is Map<String, dynamic>) return fields;
      }
      return content;
    }
    return {};
  }

  /// Extract BLS12-381 G1 public key bytes from an on-chain
  /// `group_ops::Element<G1>` field.
  ///
  /// The Move `Element` type serializes as `{ bytes: <base64 | List<int>> }`.
  /// RPC can return it nested under `fields` or directly. We handle:
  /// - `{ fields: { bytes: "base64String" } }`
  /// - `{ fields: { bytes: [int, ...] } }`
  /// - `{ bytes: "base64String" }`
  /// - `{ bytes: [int, ...] }`
  Uint8List? _extractPublicKeyBytes(dynamic pkField) {
    try {
      dynamic bytesValue;

      if (pkField is Map<String, dynamic>) {
        if (pkField.containsKey('fields')) {
          final inner = pkField['fields'];
          if (inner is Map<String, dynamic>) {
            bytesValue = inner['bytes'];
          }
        }
        bytesValue ??= pkField['bytes'];
      }

      if (bytesValue == null) return null;

      if (bytesValue is String) {
        // Base64-encoded bytes.
        return Uint8List.fromList(base64Decode(bytesValue));
      } else if (bytesValue is List) {
        return Uint8List.fromList(bytesValue.cast<int>());
      }
    } catch (_) {
      // Silently skip malformed public keys.
    }
    return null;
  }
}

/// Internal: Parsed staking pool node info.
class _StakingPoolInfo {
  final String nodeId;
  final String networkUrl;

  /// BLS12-381 G1 public key (48 bytes compressed), if available.
  final Uint8List? publicKey;

  const _StakingPoolInfo({
    required this.nodeId,
    required this.networkUrl,
    this.publicKey,
  });
}
