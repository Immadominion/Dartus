/// Types for direct storage-node interaction (Phase 3).
///
/// These types mirror the TypeScript SDK's `storage-node/types.ts`
/// and are used by [StorageNodeClient] for direct sliver read/write.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Sliver Types
// ---------------------------------------------------------------------------

/// Walrus sliver type — primary or secondary.
///
/// Each storage node is responsible for one primary and one secondary
/// sliver per blob.
///
/// Mirrors TS SDK `SliverType`.
enum SliverType {
  /// Primary sliver (column of the encoding matrix).
  primary('primary'),

  /// Secondary sliver (row of the encoding matrix).
  secondary('secondary');

  const SliverType(this.value);

  /// Wire value used in HTTP paths and BCS encoding.
  final String value;
}

/// A single encoded sliver for a specific pair index.
///
/// Corresponds to the TS SDK's `SliverData` BCS type:
/// `{ symbols: { data: bytes, symbol_size: u16 }, index: u16 }`
@immutable
class SliverData {
  /// The encoded symbol data bytes.
  final Uint8List data;

  /// Size of each individual symbol within [data].
  final int symbolSize;

  /// The sliver pair index (0-based).
  final int index;

  const SliverData({
    required this.data,
    required this.symbolSize,
    required this.index,
  });

  @override
  String toString() =>
      'SliverData('
      'index: $index, '
      'dataLen: ${data.length}, '
      'symbolSize: $symbolSize)';
}

/// A pair of primary + secondary slivers assigned to a specific node.
@immutable
class SliverPair {
  /// The primary sliver.
  final SliverData primary;

  /// The secondary sliver.
  final SliverData secondary;

  const SliverPair({required this.primary, required this.secondary});
}

// ---------------------------------------------------------------------------
// Storage Node
// ---------------------------------------------------------------------------

/// Information about a Walrus storage node.
///
/// Resolved from on-chain committee state.
@immutable
class StorageNodeInfo {
  /// Unique node identifier (Sui address or BLS public key).
  final String nodeId;

  /// HTTP endpoint URL for direct node API calls.
  final String endpointUrl;

  /// Shard indices assigned to this node.
  final List<int> shardIndices;

  /// BLS12-381 G1 public key (48 bytes compressed).
  ///
  /// Used for verifying storage confirmation signatures during
  /// certificate building. Populated from the on-chain staking
  /// pool's `node_info.public_key` field.
  ///
  /// Null when the public key is unavailable (e.g., relay mode
  /// or when the staking pool doesn't expose it).
  final Uint8List? publicKey;

  const StorageNodeInfo({
    required this.nodeId,
    required this.endpointUrl,
    required this.shardIndices,
    this.publicKey,
  });

  @override
  String toString() =>
      'StorageNodeInfo('
      'nodeId: ${nodeId.substring(0, 8)}..., '
      'shards: ${shardIndices.length})';
}

// ---------------------------------------------------------------------------
// Sliver Assignment
// ---------------------------------------------------------------------------

/// Slivers to be written to a specific storage node.
///
/// Mirrors the TS SDK's `SliversForNode` type.
@immutable
class SliversForNode {
  /// The target storage node.
  final StorageNodeInfo node;

  /// Shard index assigned to this node for this blob.
  final int shardIndex;

  /// Sliver pair index derived from shard index + blob ID rotation.
  final int sliverPairIndex;

  /// Primary sliver data for this node.
  final SliverData primary;

  /// Secondary sliver data for this node.
  final SliverData secondary;

  const SliversForNode({
    required this.node,
    required this.shardIndex,
    required this.sliverPairIndex,
    required this.primary,
    required this.secondary,
  });

  @override
  String toString() =>
      'SliversForNode('
      'nodeId: ${node.nodeId.substring(0, 8)}..., '
      'shard: $shardIndex, pairIdx: $sliverPairIndex)';
}

// ---------------------------------------------------------------------------
// Blob Status
// ---------------------------------------------------------------------------

/// Status of a blob on a specific storage node.
///
/// Mirrors TS SDK `BlobStatus`.
sealed class BlobStatus {
  const BlobStatus();

  /// The status type string (matches TS SDK `BlobStatus.type`).
  String get type;

  /// Serialize to a JSON-compatible map (used for aggregation keys).
  Map<String, dynamic> toJson();
}

/// Blob does not exist on this node.
class BlobStatusNonexistent extends BlobStatus {
  const BlobStatusNonexistent();

  @override
  String get type => 'nonexistent';

  @override
  Map<String, dynamic> toJson() => {'type': type};

  @override
  String toString() => 'BlobStatus.nonexistent';
}

/// Blob exists and metadata is invalid.
class BlobStatusInvalid extends BlobStatus {
  /// Event info for the invalid status.
  final Map<String, dynamic>? event;

  const BlobStatusInvalid({this.event});

  @override
  String get type => 'invalid';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    if (event != null) 'event': event,
  };

  @override
  String toString() => 'BlobStatus.invalid';
}

/// Deletable counts sub-structure.
class DeletableCounts {
  final int countDeletableTotal;
  final int countDeletableCertified;

  const DeletableCounts({
    required this.countDeletableTotal,
    required this.countDeletableCertified,
  });

  factory DeletableCounts.fromJson(Map<String, dynamic> json) =>
      DeletableCounts(
        countDeletableTotal: json['count_deletable_total'] as int? ?? 0,
        countDeletableCertified: json['count_deletable_certified'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'count_deletable_total': countDeletableTotal,
    'count_deletable_certified': countDeletableCertified,
  };
}

/// Status event sub-structure.
class StatusEvent {
  final String eventSeq;
  final String txDigest;

  const StatusEvent({required this.eventSeq, required this.txDigest});

  factory StatusEvent.fromJson(Map<String, dynamic> json) => StatusEvent(
    eventSeq: json['eventSeq'] as String? ?? '',
    txDigest: json['txDigest'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'eventSeq': eventSeq, 'txDigest': txDigest};
}

/// Blob is permanently stored.
class BlobStatusPermanent extends BlobStatus {
  /// End epoch for permanent storage.
  final int endEpoch;

  /// Whether the blob is certified.
  final bool isCertified;

  /// Initial certification epoch (if available).
  final int? initialCertifiedEpoch;

  /// Deletable counts.
  final DeletableCounts? deletableCounts;

  /// Status event info.
  final StatusEvent? statusEvent;

  const BlobStatusPermanent({
    required this.endEpoch,
    this.isCertified = false,
    this.initialCertifiedEpoch,
    this.deletableCounts,
    this.statusEvent,
  });

  @override
  String get type => 'permanent';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'endEpoch': endEpoch,
    'isCertified': isCertified,
    if (initialCertifiedEpoch != null)
      'initialCertifiedEpoch': initialCertifiedEpoch,
    if (deletableCounts != null) 'deletableCounts': deletableCounts!.toJson(),
    if (statusEvent != null) 'statusEvent': statusEvent!.toJson(),
  };

  @override
  String toString() => 'BlobStatus.permanent(endEpoch: $endEpoch)';
}

/// Blob is stored but deletable.
class BlobStatusDeletable extends BlobStatus {
  /// Initial certification epoch (if available).
  final int? initialCertifiedEpoch;

  /// Deletable counts.
  final DeletableCounts? deletableCounts;

  const BlobStatusDeletable({this.initialCertifiedEpoch, this.deletableCounts});

  @override
  String get type => 'deletable';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    if (initialCertifiedEpoch != null)
      'initialCertifiedEpoch': initialCertifiedEpoch,
    if (deletableCounts != null) 'deletableCounts': deletableCounts!.toJson(),
  };

  @override
  String toString() =>
      'BlobStatus.deletable('
      'initialCertifiedEpoch: $initialCertifiedEpoch)';
}

// ---------------------------------------------------------------------------
// Storage Confirmation
// ---------------------------------------------------------------------------

/// A storage confirmation from a single node.
///
/// After successfully writing metadata + slivers, the node returns
/// a signed confirmation that can be aggregated into a certificate.
///
/// Mirrors TS SDK `StorageConfirmation`.
@immutable
class StorageConfirmation {
  /// BCS-serialized confirmation message.
  final Uint8List serializedMessage;

  /// BLS signature over [serializedMessage].
  final String signature;

  const StorageConfirmation({
    required this.serializedMessage,
    required this.signature,
  });

  factory StorageConfirmation.fromJson(Map<String, dynamic> json) {
    return StorageConfirmation(
      serializedMessage: _decodeBase64Field(
        json['serializedMessage'] ?? json['serialized_message'],
      ),
      signature: json['signature'] as String,
    );
  }

  /// Decode a field that is base64-encoded (as returned by storage nodes).
  static Uint8List _decodeBase64Field(dynamic value) {
    if (value is List) {
      return Uint8List.fromList(value.cast<int>());
    }
    if (value is String) {
      // Base64 encoded — decode properly.
      return base64Decode(value);
    }
    throw ArgumentError('Unexpected field format: ${value.runtimeType}');
  }

  @override
  String toString() =>
      'StorageConfirmation('
      'messageLen: ${serializedMessage.length})';
}

// ---------------------------------------------------------------------------
// Encoded Blob
// ---------------------------------------------------------------------------

/// Result of encoding a blob for direct-mode distribution.
///
/// Contains the blob ID, metadata, and all slivers mapped to their
/// responsible storage nodes.
@immutable
class EncodedBlob {
  /// The computed Walrus blob ID (32 bytes, URL-safe base64 encoded).
  final String blobId;

  /// Raw blob ID bytes (32 bytes).
  final Uint8List blobIdBytes;

  /// BCS-serializable metadata for on-chain registration.
  final Uint8List metadataBytes;

  /// Merkle root hash of encoded slivers.
  final Uint8List rootHash;

  /// Original unencoded blob size.
  final int unencodedLength;

  /// Primary slivers indexed by sliver pair index.
  final List<SliverData> primarySlivers;

  /// Secondary slivers indexed by sliver pair index.
  final List<SliverData> secondarySlivers;

  const EncodedBlob({
    required this.blobId,
    required this.blobIdBytes,
    required this.metadataBytes,
    required this.rootHash,
    required this.unencodedLength,
    required this.primarySlivers,
    required this.secondarySlivers,
  });

  @override
  String toString() =>
      'EncodedBlob('
      'blobId: $blobId, '
      'unencodedLength: $unencodedLength, '
      'primarySlivers: ${primarySlivers.length}, '
      'secondarySlivers: ${secondarySlivers.length})';
}

// ---------------------------------------------------------------------------
// Committee Info
// ---------------------------------------------------------------------------

/// Summary of the current Walrus storage committee.
///
/// Resolved from on-chain system state.
@immutable
class CommitteeInfo {
  /// Total number of shards in the committee.
  final int numShards;

  /// Current Walrus epoch.
  final int epoch;

  /// Map from shard index to the node responsible for it.
  final Map<int, StorageNodeInfo> nodeByShardIndex;

  const CommitteeInfo({
    required this.numShards,
    required this.epoch,
    required this.nodeByShardIndex,
  });

  /// Returns the list of unique storage nodes in this committee.
  ///
  /// Derived from [nodeByShardIndex] by deduplicating on [StorageNodeInfo.nodeId].
  List<StorageNodeInfo> get nodes {
    final seen = <String>{};
    final result = <StorageNodeInfo>[];
    for (final node in nodeByShardIndex.values) {
      if (seen.add(node.nodeId)) {
        result.add(node);
      }
    }
    return result;
  }

  /// Get the storage node responsible for a given shard index.
  StorageNodeInfo? getNodeForShard(int shardIndex) =>
      nodeByShardIndex[shardIndex];

  @override
  String toString() =>
      'CommitteeInfo('
      'numShards: $numShards, '
      'epoch: $epoch, '
      'nodes: ${nodeByShardIndex.length})';
}
