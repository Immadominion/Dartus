/// Reads Walrus on-chain state from the Sui blockchain.
///
/// Provides methods to resolve:
/// - Walrus Move package ID from the system object
/// - WAL coin type from the staking module
/// - System state (pricing, epoch, committee info)
/// - Staking state (committee members, shards)
///
/// Mirrors the TS SDK's `systemObject()`, `systemState()`,
/// `stakingState()`, `#walType()`, and `#getWalrusPackageId()`.
library;

import 'package:sui/sui.dart';

import '../constants/walrus_constants.dart';
import '../utils/encoding_utils.dart';

/// On-chain system object fields (id, version, package_id, new_package_id).
///
/// Corresponds to TS SDK's `System` BCS struct.
class WalrusSystemObject {
  /// The Sui object ID of the system object.
  final String id;

  /// Current system version — used as a dynamic field key.
  final int version;

  /// Resolved Walrus Move package ID (latest — for Move calls).
  final String packageId;

  /// Type-origin package ID extracted from the object's runtime type.
  ///
  /// In Sui, object types are stamped with the **original** package ID
  /// where the struct was first defined. This ID is needed for type-based
  /// filters (e.g., `StructType` in `getOwnedObjects`).
  ///
  /// Mirrors TS SDK's `#getPackageId()` which does
  /// `parseStructTag(system.type!).address`.
  final String typeOriginPackageId;

  /// Optional new package ID for pending upgrades.
  final String? newPackageId;

  const WalrusSystemObject({
    required this.id,
    required this.version,
    required this.packageId,
    required this.typeOriginPackageId,
    this.newPackageId,
  });

  @override
  String toString() =>
      'WalrusSystemObject(id: $id, version: $version, packageId: $packageId, '
      'typeOriginPackageId: $typeOriginPackageId)';
}

/// Pricing and committee metadata from the system state inner.
///
/// Corresponds to TS SDK's `SystemStateInnerV1`.
class WalrusSystemState {
  /// Number of shards in the current committee.
  final int nShards;

  /// Current Walrus epoch.
  final int epoch;

  /// Price per storage unit per epoch (in WAL).
  final BigInt storagePricePerUnitSize;

  /// Write price per storage unit (in WAL).
  final BigInt writePricePerUnitSize;

  /// Total capacity size.
  final BigInt totalCapacitySize;

  /// Used capacity size.
  final BigInt usedCapacitySize;

  const WalrusSystemState({
    required this.nShards,
    required this.epoch,
    required this.storagePricePerUnitSize,
    required this.writePricePerUnitSize,
    required this.totalCapacitySize,
    required this.usedCapacitySize,
  });

  @override
  String toString() =>
      'WalrusSystemState('
      'nShards: $nShards, epoch: $epoch, '
      'storagePricePerUnitSize: $storagePricePerUnitSize, '
      'writePricePerUnitSize: $writePricePerUnitSize)';
}

/// Storage cost breakdown for a blob.
///
/// Corresponds to TS SDK's `storageCost()` return value.
class StorageCostInfo {
  /// Cost in WAL for reserving storage space.
  final BigInt storageCost;

  /// Cost in WAL for writing the blob.
  final BigInt writeCost;

  /// Total cost (storageCost + writeCost).
  BigInt get totalCost => storageCost + writeCost;

  const StorageCostInfo({required this.storageCost, required this.writeCost});

  @override
  String toString() =>
      'StorageCostInfo(storageCost: $storageCost, writeCost: $writeCost, '
      'total: $totalCost)';
}

/// Staking object fields (id, version, package_id).
///
/// Corresponds to TS SDK's `Staking` BCS struct.
class WalrusStakingObject {
  final String id;
  final int version;
  final String packageId;
  final String? newPackageId;

  const WalrusStakingObject({
    required this.id,
    required this.version,
    required this.packageId,
    this.newPackageId,
  });
}

/// The epoch state of the Walrus staking system.
///
/// Corresponds to TS SDK's `EpochState` enum:
/// - `EpochChangeSync(u16)` — epoch transition in progress
/// - `EpochChangeDone(u64)` — epoch change completed
/// - `NextParamsSelected(u64)` — next params have been selected
enum EpochStateKind {
  /// Epoch transition is in progress. Reads should check whether to
  /// use the previous committee for blobs certified before this epoch.
  epochChangeSync,

  /// Epoch change has completed.
  epochChangeDone,

  /// Next epoch parameters have been selected.
  nextParamsSelected,
}

/// Parsed epoch state with its kind and optional associated value.
class EpochState {
  final EpochStateKind kind;

  /// For `EpochChangeSync`: the u16 sync value.
  /// For `EpochChangeDone` / `NextParamsSelected`: the u64 value.
  final int? value;

  const EpochState({required this.kind, this.value});

  /// Whether the system is currently transitioning between epochs.
  bool get isTransitioning => kind == EpochStateKind.epochChangeSync;

  @override
  String toString() => 'EpochState($kind, value: $value)';
}

/// Staking inner state with committee and shard information.
///
/// Corresponds to TS SDK's `StakingInnerV1`.
class WalrusStakingState {
  /// Total number of shards in the system.
  final int nShards;

  /// Current Walrus epoch.
  final int epoch;

  /// Committee VecMap: nodeId → list of shard indices.
  ///
  /// In the TS SDK, `Committee` = `VecMap<Address, vector<u16>>`.
  final Map<String, List<int>> committeeMembers;

  /// The current epoch state (transitioning, done, etc.).
  ///
  /// Used to determine whether reads should use the previous committee.
  final EpochState epochState;

  /// Previous committee VecMap (for reads during epoch transitions).
  ///
  /// During `EpochChangeSync`, blobs certified in a prior epoch should
  /// be read from the previous committee's nodes.
  final Map<String, List<int>>? previousCommittee;

  const WalrusStakingState({
    required this.nShards,
    required this.epoch,
    required this.committeeMembers,
    required this.epochState,
    this.previousCommittee,
  });

  @override
  String toString() =>
      'WalrusStakingState('
      'nShards: $nShards, epoch: $epoch, '
      'members: ${committeeMembers.length}, '
      'epochState: $epochState)';
}

/// Reads Walrus on-chain state from the Sui blockchain.
///
/// Caches resolved values for the lifetime of the reader instance.
/// Create a new instance to force re-reads (e.g., after epoch change).
class SystemStateReader {
  final SuiClient _suiClient;
  final WalrusPackageConfig _config;

  // Cached values.
  WalrusSystemObject? _systemObject;
  WalrusSystemState? _systemState;
  WalrusStakingObject? _stakingObject;
  WalrusStakingState? _stakingState;
  String? _walType;
  String? _walrusPackageId;

  SystemStateReader({
    required SuiClient suiClient,
    required WalrusPackageConfig config,
  }) : _suiClient = suiClient,
       _config = config;

  /// Clear all cached values. Call after epoch changes.
  void reset() {
    _systemObject = null;
    _systemState = null;
    _stakingObject = null;
    _stakingState = null;
    _walType = null;
    _walrusPackageId = null;
  }

  // -------------------------------------------------------------------------
  // System Object
  // -------------------------------------------------------------------------

  /// Read the Walrus system object from chain.
  ///
  /// Extracts: `id`, `version`, `package_id`, `new_package_id`, and
  /// the **type origin** package ID from the object's runtime type.
  /// Mirrors TS SDK's `systemObject()` + `#getPackageId()`.
  Future<WalrusSystemObject> systemObject() async {
    if (_systemObject != null) return _systemObject!;

    final resp = await _suiClient.getObject(
      _config.systemObjectId,
      options: SuiObjectDataOptions(showContent: true, showType: true),
    );

    final content = resp.data?.content;
    if (content == null) {
      throw StateError(
        'Failed to read system object ${_config.systemObjectId}',
      );
    }

    final fields = _extractFields(content);

    // Extract type-origin package ID from the object's runtime type.
    // The type looks like `<originalPkgId>::system::System`.
    // In Sui, object types always carry the **original** package ID
    // where the struct was first defined — this is the "type origin".
    final objectType = resp.data?.type;
    String typeOriginPkgId;
    if (objectType != null && objectType.contains('::')) {
      typeOriginPkgId = objectType.split('::').first;
    } else {
      // Fallback to package_id if type is somehow unavailable.
      typeOriginPkgId = _parseStringField(fields, 'package_id');
    }

    _systemObject = WalrusSystemObject(
      id: _config.systemObjectId,
      version: _parseIntField(fields, 'version'),
      packageId: _parseStringField(fields, 'package_id'),
      typeOriginPackageId: typeOriginPkgId,
      newPackageId: fields['new_package_id'] as String?,
    );

    return _systemObject!;
  }

  // -------------------------------------------------------------------------
  // Walrus Package ID
  // -------------------------------------------------------------------------

  /// Get the **type-origin** package ID.
  ///
  /// Extracted from the System object's runtime type tag. In Sui, object
  /// types are stamped with the original package ID where the struct was
  /// first defined. This is the ID to use for:
  /// - `StructType` filters in `getOwnedObjects`
  /// - Type-matching blob objects, storage resources, etc.
  ///
  /// Mirrors TS SDK's `#getPackageId()`.
  Future<String> getPackageId() async {
    final system = await systemObject();
    return system.typeOriginPackageId;
  }

  /// Resolve the Walrus Move package ID from the system object.
  ///
  /// The TS SDK has two package ID concepts:
  /// 1. `getPackageId()` — extracted from the system object's type tag address
  /// 2. `getWalrusPackageId()` — from `systemObject().package_id` field
  ///
  /// This method returns the `package_id` field, which is the one
  /// used for Move calls like `register_blob`, `certify_blob`, etc.
  Future<String> getWalrusPackageId() async {
    if (_walrusPackageId != null) return _walrusPackageId!;
    final system = await systemObject();
    _walrusPackageId = system.packageId;
    return _walrusPackageId!;
  }

  // -------------------------------------------------------------------------
  // WAL Token Type
  // -------------------------------------------------------------------------

  /// Discover the WAL coin type from the on-chain staking module.
  ///
  /// Reads `staking::stake_with_pool` function signature and extracts
  /// the type parameter from the second argument `Coin<WAL>`.
  ///
  /// Mirrors TS SDK's `#walType()`.
  Future<String> getWalType() async {
    if (_walType != null) return _walType!;

    final packageId = await getWalrusPackageId();

    // Read the Move function signature for staking::stake_with_pool
    final normalized = await _suiClient.getNormalizedMoveFunction(
      packageId,
      'staking',
      'stake_with_pool',
    );

    // The second parameter is `Coin<WAL>` — extract the WAL type.
    // Parameters: [self, coin: Coin<WAL>, ...]
    if (normalized.parameters.length < 2) {
      throw StateError(
        'staking::stake_with_pool has unexpected parameter count: '
        '${normalized.parameters.length}',
      );
    }

    final coinParam = normalized.parameters[1];
    _walType = _extractCoinTypeFromParam(coinParam, packageId);

    if (_walType == null) {
      throw StateError('Could not resolve WAL coin type from stake_with_pool');
    }

    return _walType!;
  }

  // -------------------------------------------------------------------------
  // System State (Pricing)
  // -------------------------------------------------------------------------

  /// Read the current system state containing pricing and committee info.
  ///
  /// The system state is stored as a dynamic field on the system object,
  /// keyed by `{type: u64, value: version}`.
  ///
  /// Mirrors TS SDK's `systemState()`.
  Future<WalrusSystemState> systemState() async {
    if (_systemState != null) return _systemState!;

    final system = await systemObject();

    // Read dynamic field with key {type: u64, value: version}
    final dynField = await _suiClient.getDynamicFieldObject(
      _config.systemObjectId,
      'u64',
      system.version.toString(),
    );

    final content = dynField.data?.content;
    if (content == null) {
      throw StateError(
        'Failed to read system state dynamic field for version '
        '${system.version}',
      );
    }

    final fields = _extractFields(content);
    // The dynamic field wraps the inner value in a 'value' field.
    // The value itself is a Move object {type, fields} that needs unwrapping.
    final valueRaw = fields['value'];
    final valueFields = valueRaw is Map<String, dynamic>
        ? _extractFields(valueRaw)
        : fields;

    // Extract committee info (BlsCommittee has n_shards and epoch).
    // The committee is also a Move object {type, fields} that needs unwrapping.
    final committeeRaw = valueFields['committee'];
    final committeeFields = committeeRaw is Map<String, dynamic>
        ? _extractFields(committeeRaw)
        : null;

    _systemState = WalrusSystemState(
      nShards: _parseIntField(committeeFields ?? valueFields, 'n_shards'),
      epoch: _parseIntField(committeeFields ?? valueFields, 'epoch'),
      storagePricePerUnitSize: _parseBigIntField(
        valueFields,
        'storage_price_per_unit_size',
      ),
      writePricePerUnitSize: _parseBigIntField(
        valueFields,
        'write_price_per_unit_size',
      ),
      totalCapacitySize: _parseBigIntField(valueFields, 'total_capacity_size'),
      usedCapacitySize: _parseBigIntField(valueFields, 'used_capacity_size'),
    );

    return _systemState!;
  }

  // -------------------------------------------------------------------------
  // Storage Cost
  // -------------------------------------------------------------------------

  /// Calculate the cost (in WAL) of storing a blob.
  ///
  /// Mirrors TS SDK's `storageCost(size, epochs)`.
  Future<StorageCostInfo> storageCost(int size, int epochs) async {
    final state = await systemState();
    final encodedSize = encodedBlobLength(size, state.nShards);
    return storageCostFromEncodedSize(encodedSize, epochs, state);
  }

  /// Calculate storage cost from already-encoded size.
  StorageCostInfo storageCostFromEncodedSize(
    int encodedSize,
    int epochs,
    WalrusSystemState state,
  ) {
    final units = BigInt.from(storageUnitsFromSize(encodedSize));
    final storageCost =
        units * state.storagePricePerUnitSize * BigInt.from(epochs);
    final writeCost = units * state.writePricePerUnitSize;
    return StorageCostInfo(storageCost: storageCost, writeCost: writeCost);
  }

  // -------------------------------------------------------------------------
  // Staking Object
  // -------------------------------------------------------------------------

  /// Read the Walrus staking object from chain.
  Future<WalrusStakingObject> stakingObject() async {
    if (_stakingObject != null) return _stakingObject!;

    final resp = await _suiClient.getObject(
      _config.stakingPoolId,
      options: SuiObjectDataOptions(showContent: true),
    );

    final content = resp.data?.content;
    if (content == null) {
      throw StateError(
        'Failed to read staking object ${_config.stakingPoolId}',
      );
    }

    final fields = _extractFields(content);

    _stakingObject = WalrusStakingObject(
      id: _config.stakingPoolId,
      version: _parseIntField(fields, 'version'),
      packageId: _parseStringField(fields, 'package_id'),
      newPackageId: fields['new_package_id'] as String?,
    );

    return _stakingObject!;
  }

  // -------------------------------------------------------------------------
  // Staking State (Committee)
  // -------------------------------------------------------------------------

  /// Read the staking inner state from chain.
  ///
  /// Contains the committee VecMap and shard count.
  /// Mirrors TS SDK's `stakingState()`.
  Future<WalrusStakingState> stakingState() async {
    if (_stakingState != null) return _stakingState!;

    final staking = await stakingObject();

    // Read dynamic field with key {type: u64, value: version}
    final dynField = await _suiClient.getDynamicFieldObject(
      _config.stakingPoolId,
      'u64',
      staking.version.toString(),
    );

    final content = dynField.data?.content;
    if (content == null) {
      throw StateError(
        'Failed to read staking state dynamic field for version '
        '${staking.version}',
      );
    }

    final fields = _extractFields(content);
    // The dynamic field wraps the inner value in a 'value' field.
    // The value itself is a Move object {type, fields} that needs unwrapping.
    final valueRaw = fields['value'];
    final valueFields = valueRaw is Map<String, dynamic>
        ? _extractFields(valueRaw)
        : fields;

    // Parse committee: VecMap<Address, vector<u16>>
    // In JSON-RPC, this comes as the 'committee' field which contains
    // a VecMap with 'contents' array of {key, value} pairs.
    // The committee is also a Move object {type, fields} that needs unwrapping.
    final committeeMembers = _parseCommittee(valueFields['committee']);

    // Parse epoch_state: enum { EpochChangeSync(u16), EpochChangeDone(u64),
    //                           NextParamsSelected(u64) }
    // JSON-RPC returns this as a nested Move object with a variant field.
    final epochState = _parseEpochState(valueFields['epoch_state']);

    // Parse previous_committee: same format as committee.
    Map<String, List<int>>? previousCommittee;
    if (valueFields['previous_committee'] != null) {
      try {
        previousCommittee = _parseCommittee(valueFields['previous_committee']);
      } catch (_) {
        // Previous committee may not always be parseable
        // (e.g., first epoch). Non-fatal.
      }
    }

    _stakingState = WalrusStakingState(
      nShards: _parseIntField(valueFields, 'n_shards'),
      epoch: _parseIntField(valueFields, 'epoch'),
      committeeMembers: committeeMembers,
      epochState: epochState,
      previousCommittee: previousCommittee,
    );

    return _stakingState!;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Extract the 'fields' map from a Move struct content.
  ///
  /// Handles both `SuiMoveObject` (typed class from the `sui` package)
  /// and raw `Map<String, dynamic>` (e.g. from dynamic field responses).
  Map<String, dynamic> _extractFields(dynamic content) {
    // SuiMoveObject from sui package — access .fields directly.
    if (content is SuiMoveObject) {
      final f = content.fields;
      if (f is Map<String, dynamic>) return f;
      // fields might be null or an unexpected type
      throw StateError(
        'SuiMoveObject.fields has unexpected type: ${f.runtimeType}',
      );
    }
    if (content is Map<String, dynamic>) {
      // SuiParsedData → MoveObject has 'fields'
      if (content.containsKey('fields')) {
        final fields = content['fields'];
        if (fields is Map<String, dynamic>) return fields;
      }
      return content;
    }
    throw StateError('Unexpected content format: ${content.runtimeType}');
  }

  int _parseIntField(Map<String, dynamic> fields, String key) {
    final value = fields[key];
    if (value is int) return value;
    if (value is String) return int.parse(value);
    throw StateError('Field $key has unexpected type: ${value.runtimeType}');
  }

  BigInt _parseBigIntField(Map<String, dynamic> fields, String key) {
    final value = fields[key];
    if (value is int) return BigInt.from(value);
    if (value is String) return BigInt.parse(value);
    throw StateError('Field $key has unexpected type: ${value.runtimeType}');
  }

  String _parseStringField(Map<String, dynamic> fields, String key) {
    final value = fields[key];
    if (value is String) return value;
    throw StateError('Field $key has unexpected type: ${value.runtimeType}');
  }

  /// Parse an EpochState enum from JSON-RPC format.
  ///
  /// The Move enum `EpochState` has three variants:
  /// - `EpochChangeSync(u16)`
  /// - `EpochChangeDone(u64)`
  /// - `NextParamsSelected(u64)`
  ///
  /// JSON-RPC returns this as a Move object `{type: "...::EpochState", fields: {...}}`
  /// where the variant is encoded in the type string or as a tagged field.
  EpochState _parseEpochState(dynamic epochState) {
    if (epochState == null) {
      // Default to NextParamsSelected if not present (normal operation).
      return const EpochState(kind: EpochStateKind.nextParamsSelected);
    }

    // Unwrap Move object wrapper if present.
    dynamic fields = epochState;
    String? typeStr;
    if (epochState is Map<String, dynamic>) {
      if (epochState.containsKey('type')) {
        typeStr = epochState['type'] as String?;
      }
      if (epochState.containsKey('fields') &&
          epochState['fields'] is Map<String, dynamic>) {
        fields = epochState['fields'] as Map<String, dynamic>;
      }
    }

    // Try to determine the variant from the 'type' string.
    if (typeStr != null) {
      if (typeStr.contains('EpochChangeSync')) {
        final value = _tryParseInt(fields);
        return EpochState(kind: EpochStateKind.epochChangeSync, value: value);
      } else if (typeStr.contains('EpochChangeDone')) {
        final value = _tryParseInt(fields);
        return EpochState(kind: EpochStateKind.epochChangeDone, value: value);
      } else if (typeStr.contains('NextParamsSelected')) {
        final value = _tryParseInt(fields);
        return EpochState(
          kind: EpochStateKind.nextParamsSelected,
          value: value,
        );
      }
    }

    // Fallback: try variant field names.
    if (fields is Map<String, dynamic>) {
      if (fields.containsKey('EpochChangeSync')) {
        return EpochState(
          kind: EpochStateKind.epochChangeSync,
          value: _tryParseInt(fields['EpochChangeSync']),
        );
      } else if (fields.containsKey('EpochChangeDone')) {
        return EpochState(
          kind: EpochStateKind.epochChangeDone,
          value: _tryParseInt(fields['EpochChangeDone']),
        );
      } else if (fields.containsKey('NextParamsSelected')) {
        return EpochState(
          kind: EpochStateKind.nextParamsSelected,
          value: _tryParseInt(fields['NextParamsSelected']),
        );
      }

      // JSON-RPC variant field: the variant name is the key mapped
      // to the inner value. Check for snake_case as well.
      if (fields.containsKey('epoch_change_sync')) {
        return EpochState(
          kind: EpochStateKind.epochChangeSync,
          value: _tryParseInt(fields['epoch_change_sync']),
        );
      } else if (fields.containsKey('epoch_change_done')) {
        return EpochState(
          kind: EpochStateKind.epochChangeDone,
          value: _tryParseInt(fields['epoch_change_done']),
        );
      } else if (fields.containsKey('next_params_selected')) {
        return EpochState(
          kind: EpochStateKind.nextParamsSelected,
          value: _tryParseInt(fields['next_params_selected']),
        );
      }

      // Variant field: `variant` key.
      final variant = fields['variant'];
      if (variant is String) {
        if (variant.contains('EpochChangeSync')) {
          return EpochState(
            kind: EpochStateKind.epochChangeSync,
            value: _tryParseInt(fields['value'] ?? fields['fields']),
          );
        } else if (variant.contains('EpochChangeDone')) {
          return EpochState(
            kind: EpochStateKind.epochChangeDone,
            value: _tryParseInt(fields['value'] ?? fields['fields']),
          );
        } else if (variant.contains('NextParamsSelected')) {
          return EpochState(
            kind: EpochStateKind.nextParamsSelected,
            value: _tryParseInt(fields['value'] ?? fields['fields']),
          );
        }
      }
    }

    // Default fallback: treat as NextParamsSelected (normal operation).
    return const EpochState(kind: EpochStateKind.nextParamsSelected);
  }

  /// Try to parse an int from various formats.
  int? _tryParseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is Map<String, dynamic>) {
      // Might be wrapped in Move fields.
      final inner = value['fields'] ?? value['value'];
      if (inner is int) return inner;
      if (inner is String) return int.tryParse(inner);
    }
    return null;
  }

  /// Parse a Committee VecMap from JSON-RPC format.
  ///
  /// The committee in the staking state is `VecMap<Address, vector<u16>>`.
  /// JSON-RPC returns this as:
  /// ```json
  /// { "contents": [ { "key": "0x...", "value": [0, 1, 2] }, ... ] }
  /// ```
  ///
  /// However, the `BlsCommittee` in the system state has a different format
  /// with `members` array. We handle both formats.
  Map<String, List<int>> _parseCommittee(dynamic committee) {
    if (committee == null) {
      throw StateError('Committee field is null');
    }

    final members = <String, List<int>>{};

    // Unwrap Move object wrapper {type, fields} if present.
    if (committee is Map<String, dynamic> &&
        committee.containsKey('type') &&
        committee.containsKey('fields') &&
        committee['fields'] is Map<String, dynamic>) {
      committee = committee['fields'] as Map<String, dynamic>;
    }

    // Handle Move positional struct fields (pos0, pos1, etc.).
    // On-chain, a Committee struct serializes as:
    //   { pos0: { type: "VecMap<...>", fields: { contents: [...] } } }
    // We unwrap pos0 and then its own {type, fields} wrapper.
    if (committee is Map<String, dynamic> && committee.containsKey('pos0')) {
      dynamic inner = committee['pos0'];
      // Unwrap the VecMap's own {type, fields} wrapper.
      if (inner is Map<String, dynamic> &&
          inner.containsKey('type') &&
          inner.containsKey('fields') &&
          inner['fields'] is Map<String, dynamic>) {
        inner = inner['fields'] as Map<String, dynamic>;
      }
      committee = inner;
    }

    if (committee is Map<String, dynamic>) {
      // Format 1: VecMap with 'contents' array
      final contents = committee['contents'];
      if (contents is List) {
        for (final entry in contents) {
          if (entry is Map<String, dynamic>) {
            // Unwrap Move object wrapper on each entry.
            final entryFields =
                entry.containsKey('fields') &&
                    entry['fields'] is Map<String, dynamic>
                ? entry['fields'] as Map<String, dynamic>
                : entry;
            final key = entryFields['key'] as String;
            final value = entryFields['value'];
            members[key] = _parseIntList(value);
          }
        }
        return members;
      }

      // Format 2: BlsCommittee with 'members' array
      final membersList = committee['members'];
      if (membersList is List) {
        for (final member in membersList) {
          if (member is Map<String, dynamic>) {
            // Unwrap Move object wrapper on each member.
            final memberFields =
                member.containsKey('fields') &&
                    member['fields'] is Map<String, dynamic>
                ? member['fields'] as Map<String, dynamic>
                : member;
            final nodeId = memberFields['node_id'] as String;
            // BlsCommittee members have weight and public_key but
            // shard indices come from the staking state committee.
            members[nodeId] = [];
          }
        }
        return members;
      }
    }

    // Format 3: Tuple format (as used by TS SDK's Committee type)
    if (committee is List && committee.isNotEmpty) {
      final vecMap = committee[0];
      if (vecMap is Map<String, dynamic> && vecMap.containsKey('contents')) {
        final contents = vecMap['contents'] as List;
        for (final entry in contents) {
          if (entry is Map<String, dynamic>) {
            // Unwrap Move object wrapper on each entry.
            final entryFields =
                entry.containsKey('fields') &&
                    entry['fields'] is Map<String, dynamic>
                ? entry['fields'] as Map<String, dynamic>
                : entry;
            final key = entryFields['key'] as String;
            final value = entryFields['value'];
            members[key] = _parseIntList(value);
          }
        }
        return members;
      }
    }

    throw StateError('Unexpected committee format: ${committee.runtimeType}');
  }

  List<int> _parseIntList(dynamic value) {
    if (value is List) {
      return value.map((e) {
        if (e is int) return e;
        if (e is String) return int.parse(e);
        return 0;
      }).toList();
    }
    return [];
  }

  /// Extract WAL coin type from a Move function parameter.
  ///
  /// The parameter is `Coin<WAL>`. We need to extract the WAL type
  /// from the Coin's type parameter.
  String? _extractCoinTypeFromParam(dynamic param, String packageId) {
    // The normalized Move parameter is a complex nested structure.
    // We look for Struct { address: "0x2", module: "coin", name: "Coin",
    //   typeArguments: [Struct { address: <pkg>, module: "wal", name: "WAL" }] }
    if (param is Map<String, dynamic>) {
      // Handle MutableReference / Reference wrappers
      final inner = param['MutableReference'] ?? param['Reference'] ?? param;

      if (inner is Map<String, dynamic>) {
        final struct = inner['Struct'];
        if (struct is Map<String, dynamic>) {
          final typeArgs = struct['typeArguments'] as List?;
          if (typeArgs != null &&
              typeArgs.isNotEmpty &&
              struct['module'] == 'coin' &&
              struct['name'] == 'Coin') {
            return _normalizeTypeTag(typeArgs[0]);
          }
        }
      }
    }
    return null;
  }

  /// Convert a normalized Move type to a type tag string.
  String? _normalizeTypeTag(dynamic type) {
    if (type is String) return type;
    if (type is Map<String, dynamic>) {
      final struct = type['Struct'] ?? type;
      if (struct is Map<String, dynamic> &&
          struct.containsKey('address') &&
          struct.containsKey('module') &&
          struct.containsKey('name')) {
        return '${struct['address']}::${struct['module']}::${struct['name']}';
      }
    }
    return null;
  }
}
