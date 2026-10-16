/// Reads the Walrus state that wallet writes need from Sui, over gRPC-web.
///
/// Works on the web and natively. Sui's public JSON-RPC has been shut down,
/// so this reader uses `SuiGrpcClient` from `package:sui`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sui/builder/coin_with_balance.dart';
import 'package:sui/grpc/proto/sui/rpc/v2/effects.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/object.pb.dart' as pb;
import 'package:sui/sui.dart';

import '../constants/walrus_constants.dart';
import '../errors/walrus_errors.dart';
import '../utils/blob_id_utils.dart';
import '../utils/encoding_utils.dart';

/// A snapshot of the Walrus system object and its current inner state.
@immutable
class WalrusSystemSnapshot {
  const WalrusSystemSnapshot({
    required this.epoch,
    required this.nShards,
    required this.committeeSize,
    required this.storagePricePerUnit,
    required this.writePricePerUnit,
    required this.packageId,
    required this.typeOriginPackageId,
    required this.maxEpochsAhead,
  });

  /// The current Walrus epoch.
  final int epoch;

  /// Number of shards; blob metadata and encoded sizes depend on it.
  final int nShards;

  /// Number of storage nodes in the committee (the certificate bitmap size).
  final int committeeSize;

  /// FROST per storage unit (1 MiB of encoded size) per epoch.
  final BigInt storagePricePerUnit;

  /// FROST per storage unit charged once when a blob is registered.
  final BigInt writePricePerUnit;

  /// The current Walrus package, used as the target of Move calls.
  final String packageId;

  /// The package that first defined the Walrus types (`Blob`, `System`).
  final String typeOriginPackageId;

  /// The most epochs storage can be bought for at once (53 on both
  /// public networks).
  final int maxEpochsAhead;

  /// The full Move type of a Walrus `Blob` object.
  String get blobType => '$typeOriginPackageId::blob::Blob';

  /// What storing [size] bytes for [epochs] epochs costs, in FROST of WAL.
  WalrusStorageCost storageCost(int size, int epochs) {
    final encodedSize = encodedBlobLength(size, nShards);
    final units = BigInt.from(storageUnitsFromSize(encodedSize));
    return WalrusStorageCost(
      encodedSize: encodedSize,
      storageCost: units * storagePricePerUnit * BigInt.from(epochs),
      writeCost: units * writePricePerUnit,
    );
  }
}

/// The WAL a blob costs, split the way the Move calls take it.
@immutable
class WalrusStorageCost {
  const WalrusStorageCost({
    required this.encodedSize,
    required this.storageCost,
    required this.writeCost,
  });

  /// The blob's size after erasure coding; prices and relay tips use it.
  final int encodedSize;

  /// FROST paid to `system::reserve_space`.
  final BigInt storageCost;

  /// FROST paid to `system::register_blob`.
  final BigInt writeCost;

  /// Total FROST of WAL (1 WAL = 10^9 FROST).
  BigInt get total => storageCost + writeCost;
}

/// A Walrus `Blob` object as stored on Sui.
@immutable
class WalrusBlobObject {
  const WalrusBlobObject({
    required this.objectId,
    required this.blobId,
    required this.size,
    required this.registeredEpoch,
    required this.certifiedEpoch,
    required this.startEpoch,
    required this.endEpoch,
    required this.deletable,
    required this.owner,
  });

  final String objectId;

  /// The blob ID in its URL-safe base64 form.
  final String blobId;

  /// Unencoded size in bytes.
  final int size;

  final int registeredEpoch;

  /// The epoch the blob was certified in; null until it is certified.
  final int? certifiedEpoch;

  /// First epoch of the storage period.
  final int startEpoch;

  /// The storage period ends at the start of this epoch.
  final int endEpoch;

  final bool deletable;

  /// The owning address, or null when the object is not address-owned
  /// (for example wrapped in another object).
  final String? owner;

  bool get isCertified => certifiedEpoch != null;
}

/// The SUI and WAL an address holds (coins plus address balance), in MIST
/// and FROST.
@immutable
class WalrusWalletBalances {
  const WalrusWalletBalances({required this.sui, required this.wal});

  final BigInt sui;
  final BigInt wal;
}

/// Reads Walrus objects and state from Sui.
class WalrusChainReader {
  WalrusChainReader({
    required this.sui,
    required this.packageConfig,
    required this.walCoinType,
    this.cacheFor = const Duration(minutes: 1),
  });

  /// A reader for one of the public networks.
  factory WalrusChainReader.forNetwork(
    WalrusNetwork network, {
    SuiGrpcClient? sui,
  }) => WalrusChainReader(
    sui: sui ?? SuiGrpcClient(network: _suiNetwork(network)),
    packageConfig: network.packageConfig,
    walCoinType: network.walCoinType,
  );

  final SuiGrpcClient sui;
  final WalrusPackageConfig packageConfig;

  /// The WAL coin type storage is paid in.
  final String walCoinType;

  /// How long a system snapshot is reused. Prices and the committee change
  /// at most once per epoch, but a stale shard count would give a wrong
  /// blob ID, so the cache is short.
  final Duration cacheFor;

  Future<WalrusSystemSnapshot>? _snapshot;
  DateTime _snapshotAt = DateTime.fromMillisecondsSinceEpoch(0);

  static SuiNetwork _suiNetwork(WalrusNetwork network) => switch (network) {
    WalrusNetwork.testnet => SuiNetwork.testnet,
    WalrusNetwork.mainnet => SuiNetwork.mainnet,
  };

  /// Forget the cached system snapshot.
  void reset() => _snapshot = null;

  /// The current system snapshot, cached for [cacheFor].
  Future<WalrusSystemSnapshot> system() {
    final now = DateTime.now();
    if (_snapshot == null || now.difference(_snapshotAt) > cacheFor) {
      _snapshotAt = now;
      _snapshot = _readSystem().catchError((Object error) {
        _snapshot = null;
        throw error;
      });
    }
    return _snapshot!;
  }

  Future<WalrusSystemSnapshot> _readSystem() async {
    final system = await sui.getObject(
      packageConfig.systemObjectId,
      readMask: const ['object_type', 'json'],
    );
    final fields = _map(system.json.toProto3Json(), 'system object');
    final version = _int(fields['version'], 'system version');

    // The inner state is a dynamic field keyed by the version, a BCS u64
    // (little-endian). Written byte by byte: ByteData.setUint64 does not
    // exist when Flutter compiles to JavaScript.
    final key = Uint8List(8);
    for (var i = 0, v = version; i < 8; i++, v >>= 8) {
      key[i] = v & 0xff;
    }
    final inner = await sui.getDynamicFieldObject(
      packageConfig.systemObjectId,
      'u64',
      key,
      readMask: const ['json'],
    );
    final field = _map(inner.json.toProto3Json(), 'system state field');
    final state = _map(field['value'], 'system state');
    final committee = _map(state['committee'], 'committee');

    return WalrusSystemSnapshot(
      epoch: _int(committee['epoch'], 'epoch'),
      nShards: _int(committee['n_shards'], 'n_shards'),
      committeeSize:
          (committee['members'] as List?)?.length ??
          (throw StateError('Walrus committee has no members list')),
      storagePricePerUnit: _bigInt(
        state['storage_price_per_unit_size'],
        'storage price',
      ),
      writePricePerUnit: _bigInt(
        state['write_price_per_unit_size'],
        'write price',
      ),
      packageId: _string(fields['package_id'], 'package_id'),
      typeOriginPackageId: system.objectType.split('::').first,
      maxEpochsAhead: _int(
        _map(state['future_accounting'], 'future accounting')['length'],
        'future accounting length',
      ),
    );
  }

  /// Read a Walrus `Blob` object. Throws [WalrusClientError] if the object
  /// is not a Walrus blob on this network.
  Future<WalrusBlobObject> blobObject(String objectId) async {
    final snapshot = await system();
    final pb.Object object = await sui.getObject(
      objectId,
      readMask: const ['object_id', 'object_type', 'owner', 'json'],
    );
    if (object.objectType != snapshot.blobType) {
      throw WalrusClientError(
        'Object $objectId is a ${object.objectType}, not a Walrus blob',
      );
    }
    final json = _map(object.json.toProto3Json(), 'blob object');
    final storage = _map(json['storage'], 'blob storage');
    final owner = object.owner.address;
    return WalrusBlobObject(
      objectId: objectId,
      blobId: blobIdFromInt(_bigInt(json['blob_id'], 'blob_id')),
      size: _int(json['size'], 'size'),
      registeredEpoch: _int(json['registered_epoch'], 'registered_epoch'),
      certifiedEpoch: json['certified_epoch'] == null
          ? null
          : _int(json['certified_epoch'], 'certified_epoch'),
      startEpoch: _int(storage['start_epoch'], 'start_epoch'),
      endEpoch: _int(storage['end_epoch'], 'end_epoch'),
      deletable: json['deletable'] == true,
      owner: owner.isEmpty ? null : owner,
    );
  }

  /// Wait until transaction [digest] is visible and check that it succeeded.
  ///
  /// Wallets return as soon as a transaction executes; a full node may take
  /// a moment longer to serve it, and the upload relay checks it too.
  Future<void> waitForSuccess(
    String digest, {
    Duration timeout = const Duration(seconds: 60),
  }) => _effects(digest, timeout);

  /// Wait for transaction [digest], check that it succeeded, and return the
  /// IDs of the objects of [type] it created.
  Future<List<String>> createdObjects(
    String digest, {
    required String type,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final effects = await _effects(digest, timeout);
    return [
      for (final change in effects.changedObjects)
        if (change.idOperation == pb.ChangedObject_IdOperation.CREATED &&
            change.objectType == type)
          change.objectId,
    ];
  }

  Future<pb.TransactionEffects> _effects(
    String digest,
    Duration timeout,
  ) async {
    final transaction = await sui.waitForTransaction(
      digest,
      timeout: timeout,
      readMask: const ['digest', 'effects'],
    );
    final effects = transaction.effects;
    if (!effects.status.success) {
      final reason = effects.status.error.description;
      throw WalrusClientError(
        'Transaction $digest failed${reason.isEmpty ? '' : ': $reason'}',
      );
    }
    return effects;
  }

  /// Serialize [tx] for a wallet, with [sender] set and its WAL and SUI
  /// payments (`CoinWithBalance` intents) resolved against [sender]'s coins
  /// and address balance, the way `@mysten/sui`'s dApp Kit does before it
  /// calls `sui:signAndExecuteTransaction`. The wallet adds gas.
  Future<String> serializeForWallet(Transaction tx, String sender) async {
    tx.setSender(sender);
    final data = TransactionBlockDataBuilder.restore(
      jsonDecode(tx.toJson()) as Map<String, dynamic>,
    );
    await resolveCoinBalanceIntents(
      data,
      GrpcBuilderAdapter(sui.core as GrpcCoreClient),
    );
    return jsonEncode(data.snapshot());
  }

  /// The SUI and WAL [owner] holds.
  Future<WalrusWalletBalances> balances(String owner) async {
    final balances = await Future.wait([
      sui.balanceOf(owner),
      sui.balanceOf(owner, coinType: walCoinType),
    ]);
    return WalrusWalletBalances(
      sui: balances[0].totalBalance,
      wal: balances[1].totalBalance,
    );
  }

  // --- JSON helpers. Protobuf Struct JSON carries numbers as doubles and
  // u64/u256 values as decimal strings.

  static Map<String, dynamic> _map(Object? value, String what) =>
      value is Map<String, dynamic>
      ? value
      : throw StateError('Unexpected $what: $value');

  static int _int(Object? value, String what) => switch (value) {
    final num n => n.toInt(),
    final String s => int.parse(s),
    _ => throw StateError('Unexpected $what: $value'),
  };

  static BigInt _bigInt(Object? value, String what) => switch (value) {
    final String s => BigInt.parse(s),
    final num n => BigInt.from(n),
    _ => throw StateError('Unexpected $what: $value'),
  };

  static String _string(Object? value, String what) =>
      value is String ? value : throw StateError('Unexpected $what: $value');
}
