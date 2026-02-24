/// Network-specific configuration constants for the Walrus protocol.
///
/// Mirrors the TypeScript SDK's `constants.ts` with `WalrusPackageConfig`.
/// These object IDs reference on-chain Walrus system objects on Sui.
library;

import 'package:meta/meta.dart';

/// Configuration for a Walrus deployment on a specific Sui network.
///
/// Contains the on-chain object IDs needed to interact with Walrus
/// Move contracts (blob registration, certification, storage).
@immutable
class WalrusPackageConfig {
  /// The system object ID of the Walrus package.
  ///
  /// Used to read system state (committee info, epoch, pricing)
  /// and as the first argument to `system::register_blob` / `system::certify_blob`.
  final String systemObjectId;

  /// The staking pool ID of the Walrus package.
  ///
  /// Used to read staking state (number of shards, committee members).
  final String stakingPoolId;

  /// Optional exchange object IDs for WAL token exchange.
  ///
  /// Used to swap SUI for WAL tokens via on-chain exchange contracts.
  final List<String>? exchangeIds;

  const WalrusPackageConfig({
    required this.systemObjectId,
    required this.stakingPoolId,
    this.exchangeIds,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WalrusPackageConfig &&
          runtimeType == other.runtimeType &&
          systemObjectId == other.systemObjectId &&
          stakingPoolId == other.stakingPoolId;

  @override
  int get hashCode => Object.hash(systemObjectId, stakingPoolId);

  @override
  String toString() =>
      'WalrusPackageConfig('
      'systemObjectId: $systemObjectId, '
      'stakingPoolId: $stakingPoolId)';
}

/// Testnet Walrus package configuration.
///
/// Matches the TypeScript SDK's `TESTNET_WALRUS_PACKAGE_CONFIG`.
const testnetWalrusPackageConfig = WalrusPackageConfig(
  systemObjectId:
      '0x6c2547cbbc38025cf3adac45f63cb0a8d12ecf777cdc75a4971612bf97fdf6af',
  stakingPoolId:
      '0xbe46180321c30aab2f8b3501e24048377287fa708018a5b7c2792b35fe339ee3',
  exchangeIds: [
    '0xf4d164ea2def5fe07dc573992a029e010dba09b1a8dcbc44c5c2e79567f39073',
    '0x19825121c52080bb1073662231cfea5c0e4d905fd13e95f21e9a018f2ef41862',
    '0x83b454e524c71f30803f4d6c302a86fb6a39e96cdfb873c2d1e93bc1c26a3bc5',
    '0x8d63209cf8589ce7aef8f262437163c67577ed09f3e636a9d8e0813843fb8bf1',
  ],
);

/// Mainnet Walrus package configuration.
///
/// Matches the TypeScript SDK's `MAINNET_WALRUS_PACKAGE_CONFIG`.
const mainnetWalrusPackageConfig = WalrusPackageConfig(
  systemObjectId:
      '0x2134d52768ea07e8c43570ef975eb3e4c27a39fa6396bef985b5abc58d03ddd2',
  stakingPoolId:
      '0x10b9d30c28448939ce6c4d6c6e0ffce4a7f8a4ada8248bdad09ef8b70e4a3904',
);

/// Known Walrus network identifiers.
enum WalrusNetwork {
  /// Sui testnet deployment.
  testnet,

  /// Sui mainnet deployment.
  mainnet,
}

/// Extension to resolve [WalrusNetwork] to its [WalrusPackageConfig].
extension WalrusNetworkConfig on WalrusNetwork {
  /// Returns the [WalrusPackageConfig] for this network.
  WalrusPackageConfig get packageConfig {
    switch (this) {
      case WalrusNetwork.testnet:
        return testnetWalrusPackageConfig;
      case WalrusNetwork.mainnet:
        return mainnetWalrusPackageConfig;
    }
  }

  /// Default Sui RPC URL for this network.
  String get defaultRpcUrl {
    switch (this) {
      case WalrusNetwork.testnet:
        return 'https://fullnode.testnet.sui.io:443';
      case WalrusNetwork.mainnet:
        return 'https://fullnode.mainnet.sui.io:443';
    }
  }

  /// Default Upload Relay URL for this network (if available).
  String? get defaultUploadRelayUrl {
    switch (this) {
      case WalrusNetwork.testnet:
        return 'https://upload-relay.testnet.walrus.space';
      case WalrusNetwork.mainnet:
        // Mainnet relay URL TBD
        return null;
    }
  }
}

/// Lifecycle rank for blob statuses, used by [getVerifiedBlobStatus]
/// to pick the "highest" status when multiple storage nodes disagree.
///
/// Higher rank = more authoritative status.
///
/// Matches the TypeScript SDK's `statusLifecycleRank`.
const Map<String, int> statusLifecycleRank = {
  'nonexistent': 0,
  'deletable': 1,
  'permanent': 2,
  'invalid': 3,
};
