/// Builds Sui Programmable Transaction Blocks for Walrus Move contracts.
///
/// Wraps the `sui` package's [Transaction] class to construct Move calls
/// for blob registration, certification, storage reservation, and
/// upload relay tipping.
///
/// Mirrors the TS SDK's transaction-building methods on `WalrusClient`:
/// `registerBlob`, `certifyBlob`, `createStorage`, `sendUploadRelayTip`.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sui/builder/transaction.dart';

import '../utils/encoding_utils.dart' show signersToBitmap;

import '../constants/walrus_constants.dart';
import '../models/protocol_types.dart';
import '../utils/blob_id_utils.dart';

/// Builds Walrus-specific Sui transactions.
///
/// Usage:
/// ```dart
/// final builder = WalrusTransactionBuilder(
///   packageConfig: testnetWalrusPackageConfig,
///   walrusPackageId: '<discovered-package-id>',
/// );
///
/// // With proper WAL payment:
/// final tx = builder.registerBlobWithWal(
///   RegisterBlobOptions(
///     size: data.length,
///     epochs: 3,
///     blobId: metadata.blobId,
///     rootHash: metadata.rootHash,
///     deletable: true,
///     owner: myAddress,
///   ),
///   walCoinObjectId: myWalCoinId,
///   walType: '0x...::wal::WAL',
///   storageCost: storageCostAmount,
///   writeCost: writeCostAmount,
///   encodedSize: computedEncodedSize,
/// );
/// ```
class WalrusTransactionBuilder {
  /// On-chain Walrus system config for the target network.
  final WalrusPackageConfig packageConfig;

  /// The resolved Walrus Move package ID on the target network.
  ///
  /// This may differ from [packageConfig.systemObjectId] — the system
  /// object can reveal the actual package address at runtime via
  /// `System.package_id`.
  final String walrusPackageId;

  WalrusTransactionBuilder({
    required this.packageConfig,
    required this.walrusPackageId,
  });

  // -------------------------------------------------------------------------
  // Register Blob (with proper WAL payment)
  // -------------------------------------------------------------------------

  /// Build a transaction that registers a new blob with proper WAL payment.
  ///
  /// This is the **production-correct** method that:
  /// 1. Splits [storageCost] from the WAL coin for `reserve_space`
  /// 2. Splits [writeCost] from the WAL coin for `register_blob`
  /// 3. Calls `coin::destroy_zero<WAL>` on the remaining coin
  /// 4. Transfers the Blob object to [options.owner]
  ///
  /// Mirrors the TS SDK's `registerBlob()` method which uses `#withWal()`
  /// for both storage and write payments.
  ///
  /// Parameters:
  /// - [walCoinObjectId]: Object ID of a WAL coin with sufficient balance.
  ///   If null, [walCoinInput] must be provided instead.
  /// - [walCoinInput]: Pre-resolved transaction input for the WAL coin.
  ///   Takes precedence over [walCoinObjectId].
  /// - [walType]: The full WAL coin type string (e.g., `0x...::wal::WAL`).
  /// - [storageCost]: WAL amount for `reserve_space`.
  /// - [writeCost]: WAL amount for `register_blob` write payment.
  /// - [encodedSize]: Pre-computed encoded blob size in bytes.
  Transaction registerBlobWithWal(
    RegisterBlobOptions options, {
    String? walCoinObjectId,
    Map<String, dynamic>? walCoinInput,
    required String walType,
    required BigInt storageCost,
    required BigInt writeCost,
    required int encodedSize,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    // Resolve the WAL coin input.
    final walCoin = walCoinInput ?? tx.object(walCoinObjectId!);

    // Step 1: Split storage cost from WAL coin.
    final storageSplit = tx.splitCoins(walCoin, [tx.pure.u64(storageCost)]);

    // Step 2: Reserve storage space.
    final storage = tx.moveCall(
      '$walrusPackageId::system::reserve_space',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        tx.pure.u64(BigInt.from(encodedSize)), // storageAmount
        tx.pure.u32(options.epochs), // epochsAhead
        storageSplit, // payment: Coin<WAL>
      ],
    );

    // Step 3: Destroy the zero-balance storage coin.
    // reserve_space takes &mut Coin<WAL> and deducts the cost, leaving 0.
    // Coin<WAL> lacks `drop`, so we must explicitly destroy it.
    tx.moveCall(
      '0x2::coin::destroy_zero',
      typeArguments: [walType],
      arguments: [storageSplit],
    );

    // Step 4: Split write cost from WAL coin.
    final writeSplit = tx.splitCoins(walCoin, [tx.pure.u64(writeCost)]);

    // Step 5: Register the blob.
    final blob = tx.moveCall(
      '$walrusPackageId::system::register_blob',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        storage, // storage: Storage
        tx.pure.u256(blobIdToInt(options.blobId)), // blobId
        tx.pure.u256(_rootHashToBigInt(options.rootHash)), // rootHash
        tx.pure.u64(BigInt.from(options.size)), // size
        tx.pure.u8(1), // encodingType (1 = RS2)
        tx.pure.boolean(options.deletable), // deletable
        writeSplit, // writePayment: Coin<WAL>
      ],
    );

    // Step 6: Destroy the zero-balance write coin.
    tx.moveCall(
      '0x2::coin::destroy_zero',
      typeArguments: [walType],
      arguments: [writeSplit],
    );

    // Step 7: Transfer the Blob object to the owner.
    if (options.owner != null) {
      tx.transferObjects([blob], tx.pure.address(options.owner!));
    }

    return tx;
  }

  // -------------------------------------------------------------------------
  // Register Blob (legacy, for testing without WAL)
  // -------------------------------------------------------------------------

  /// Build a transaction that registers a blob using gas coin as payment.
  ///
  /// **Warning**: This uses `tx.gas` as write payment, which only works
  /// when the system accepts SUI for payment (not standard Walrus behavior).
  /// For production use, call [registerBlobWithWal] instead.
  ///
  /// Kept for backward compatibility and local testing.
  @Deprecated('Use registerBlobWithWal() for production WAL payment')
  Transaction registerBlobTransaction(
    RegisterBlobOptions options, {
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final registration = tx.moveCall(
      '$walrusPackageId::system::register_blob',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        tx.object(packageConfig.systemObjectId), // storage (placeholder)
        tx.pure.u256(blobIdToInt(options.blobId)), // blobId
        tx.pure.u256(_rootHashToBigInt(options.rootHash)), // rootHash
        tx.pure.u64(BigInt.from(options.size)), // size
        tx.pure.u8(1), // encodingType
        tx.pure.boolean(options.deletable), // deletable
        tx.gas, // writePayment (simplified — not valid for Walrus)
      ],
    );

    if (options.owner != null) {
      tx.transferObjects([registration], tx.pure.address(options.owner!));
    }

    return tx;
  }

  // -------------------------------------------------------------------------
  // Create Storage (standalone)
  // -------------------------------------------------------------------------

  /// Build a transaction that creates a storage reservation.
  ///
  /// Splits [storageCost] from the WAL coin and calls `reserve_space`.
  /// The resulting Storage object can be used with `register_blob`.
  ///
  /// Mirrors TS SDK's `createStorage()`.
  Transaction createStorageTransaction({
    required int encodedSize,
    required int epochs,
    required String walCoinObjectId,
    required BigInt storageCost,
    String? walType,
    String? owner,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final walCoin = tx.object(walCoinObjectId);
    final payment = tx.splitCoins(walCoin, [tx.pure.u64(storageCost)]);

    final storage = tx.moveCall(
      '$walrusPackageId::system::reserve_space',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        tx.pure.u64(BigInt.from(encodedSize)), // storageAmount
        tx.pure.u32(epochs), // epochsAhead
        payment, // payment: Coin<WAL>
      ],
    );

    // Destroy the zero-balance payment coin (Coin<WAL> lacks `drop`).
    // reserve_space takes &mut Coin<WAL>, deducting cost and leaving 0.
    // Matches TS SDK's #withWal → coin::destroy_zero pattern.
    if (walType != null) {
      tx.moveCall(
        '0x2::coin::destroy_zero',
        typeArguments: [walType],
        arguments: [payment],
      );
    }

    if (owner != null) {
      tx.transferObjects([storage], tx.pure.address(owner));
    }

    return tx;
  }

  // -------------------------------------------------------------------------
  // Certify Blob
  // -------------------------------------------------------------------------

  /// Build a transaction that certifies a blob using a certificate.
  ///
  /// The certificate is obtained either from the upload relay or by
  /// aggregating individual storage node confirmations (Phase 3).
  ///
  /// Corresponds to TS SDK's `certifyBlobTransaction()`.
  Transaction certifyBlobTransaction(
    CertifyBlobOptions options, {
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();
    final cert = options.certificate;

    if (cert == null) {
      throw ArgumentError(
        'A ProtocolMessageCertificate is required. '
        'Obtain one from the upload relay or aggregate storage node '
        'confirmations in direct mode.',
      );
    }

    // Convert signer indices → compact bitmap (matching TS SDK's
    // `signersToBitmap(signers, committeeSize)` call at certify time).
    final signersBitmap = signersToBitmap(cert.signers, options.committeeSize);

    tx.moveCall(
      '$walrusPackageId::system::certify_blob',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        tx.object(options.blobObjectId), // blob object
        tx.pure.vector('u8', cert.signature.toList()), // signature
        tx.pure.vector('u8', signersBitmap.toList()), // signersBitmap
        tx.pure.vector('u8', cert.serializedMessage.toList()), // message
      ],
    );

    return tx;
  }

  // -------------------------------------------------------------------------
  // Upload Relay Tip
  // -------------------------------------------------------------------------

  /// Add an upload relay tip payment + auth payload to [transaction].
  ///
  /// The auth payload proves to the relay that the tip was included in
  /// the same transaction as the blob registration.
  ///
  /// Auth payload structure (matches TS SDK `addAuthPayload`):
  /// `blobDigest + SHA256(nonce) + BCS(u64, size)`
  ///
  /// Corresponds to TS SDK's `sendUploadRelayTip()`.
  Transaction sendUploadRelayTip({
    required int size,
    required Uint8List blobDigest,
    required Uint8List nonce,
    required UploadRelayTipConfig tipConfig,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    // Calculate tip amount.
    final tipAmount = tipConfig.calculateTip(size);

    // Build auth payload: blobDigest + sha256(nonce) + bcs(u64(size))
    //
    // The relay reads this as a raw 72-byte pure input from the tx data.
    // Must use tx.pure(Uint8List) to pass raw bytes — NOT tx.pure.vector()
    // which wraps in a BCS vector encoding (ULEB128 length prefix).
    // Matches TS SDK: `transaction.pure(authPayload)`.
    final nonceHash = sha256.convert(nonce).bytes;
    final sizeBytes = _bcsU64(size);
    final authPayload = Uint8List.fromList([
      ...blobDigest,
      ...nonceHash,
      ...sizeBytes,
    ]);

    // Add auth payload as a raw pure argument (72 bytes, no vector wrapper).
    tx.pure(authPayload);

    // Split tip coin from gas and transfer to relay operator.
    final tipCoin = tx.splitCoins(tx.gas, [tx.pure.u64(tipAmount)]);
    tx.transferObjects([tipCoin], tx.pure.address(tipConfig.address));

    return tx;
  }

  // -------------------------------------------------------------------------
  // Delete Blob
  // -------------------------------------------------------------------------

  /// Build a transaction that deletes a deletable blob.
  ///
  /// Corresponds to TS SDK's `deleteBlobTransaction()`.
  Transaction deleteBlobTransaction({
    required String blobObjectId,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    tx.moveCall(
      '$walrusPackageId::system::delete_blob',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        tx.object(blobObjectId), // blob
      ],
    );

    return tx;
  }

  // -------------------------------------------------------------------------
  // Extend Blob
  // -------------------------------------------------------------------------

  /// Build a transaction that extends the validity period of a blob.
  ///
  /// Uses WAL coin for payment when [walCoinObjectId] is provided.
  /// Falls back to gas coin if not provided (not valid for production).
  ///
  /// Corresponds to TS SDK's `extendBlobTransaction()`.
  Transaction extendBlobTransaction({
    required String blobObjectId,
    required int epochs,
    String? walCoinObjectId,
    BigInt? extensionCost,
    String? walType,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final dynamic payment;
    if (walCoinObjectId != null && extensionCost != null) {
      final walCoin = tx.object(walCoinObjectId);
      payment = tx.splitCoins(walCoin, [tx.pure.u64(extensionCost)]);
    } else {
      payment = tx.gas; // Fallback — not valid for production Walrus
    }

    tx.moveCall(
      '$walrusPackageId::system::extend_blob',
      arguments: [
        tx.object(packageConfig.systemObjectId), // self
        tx.object(blobObjectId), // blob
        tx.pure.u32(epochs), // additional epochs
        payment, // payment
      ],
    );

    // Destroy zero-balance coin if using WAL payment.
    // extend_blob takes &mut Coin<WAL>, deducting cost and leaving 0.
    if (walCoinObjectId != null && extensionCost != null && walType != null) {
      tx.moveCall(
        '0x2::coin::destroy_zero',
        typeArguments: [walType],
        arguments: [payment],
      );
    }

    return tx;
  }

  // -------------------------------------------------------------------------
  // Blob Metadata (Attributes)
  // -------------------------------------------------------------------------

  /// Build a transaction that creates a new empty Metadata object.
  ///
  /// Corresponds to TS `metadata::_new()` Move call.
  dynamic createMetadata({required Transaction tx}) {
    return tx.moveCall('$walrusPackageId::metadata::new', arguments: []);
  }

  /// Build a transaction that adds metadata to a blob.
  ///
  /// Aborts on-chain if metadata is already present on the blob.
  /// Use [addOrReplaceMetadata] if you want to replace existing metadata.
  ///
  /// Corresponds to TS `blob::addMetadata()` Move call.
  void addMetadata({
    required Transaction tx,
    required dynamic blobObject,
    required dynamic metadata,
  }) {
    tx.moveCall(
      '$walrusPackageId::blob::add_metadata',
      arguments: [blobObject, metadata],
    );
  }

  /// Build a transaction that adds or replaces metadata on a blob.
  ///
  /// Returns the previously attached metadata if one existed.
  ///
  /// Corresponds to TS `blob::addOrReplaceMetadata()` Move call.
  dynamic addOrReplaceMetadata({
    required Transaction tx,
    required dynamic blobObject,
    required dynamic metadata,
  }) {
    return tx.moveCall(
      '$walrusPackageId::blob::add_or_replace_metadata',
      arguments: [blobObject, metadata],
    );
  }

  /// Build a transaction that inserts or updates a single key-value
  /// pair in the blob's metadata. Creates metadata if not present.
  ///
  /// Corresponds to TS `blob::insertOrUpdateMetadataPair()` Move call.
  void insertOrUpdateMetadataPair({
    required Transaction tx,
    required dynamic blobObject,
    required String key,
    required String value,
  }) {
    tx.moveCall(
      '$walrusPackageId::blob::insert_or_update_metadata_pair',
      arguments: [blobObject, tx.pure.string(key), tx.pure.string(value)],
    );
  }

  /// Build a transaction that removes a metadata key-value pair from
  /// the blob. Aborts if the key does not exist.
  ///
  /// Corresponds to TS `blob::removeMetadataPair()` Move call.
  void removeMetadataPair({
    required Transaction tx,
    required dynamic blobObject,
    required String key,
  }) {
    tx.moveCall(
      '$walrusPackageId::blob::remove_metadata_pair',
      arguments: [blobObject, tx.pure.string(key)],
    );
  }

  /// Build a transaction that removes a metadata key-value pair if it
  /// exists (does not abort if absent).
  ///
  /// Corresponds to TS `blob::removeMetadataPairIfExists()` Move call.
  void removeMetadataPairIfExists({
    required Transaction tx,
    required dynamic blobObject,
    required String key,
  }) {
    tx.moveCall(
      '$walrusPackageId::blob::remove_metadata_pair_if_exists',
      arguments: [blobObject, tx.pure.string(key)],
    );
  }

  /// Build a complete write-blob-attributes transaction.
  ///
  /// Reads existing attributes from the blob and applies the given
  /// [attributes] map. If a value is `null`, the key is removed.
  /// If non-null, the key is inserted or updated.
  ///
  /// If the blob has no metadata yet, creates a new empty metadata
  /// object and attaches it first.
  ///
  /// Mirrors the TS SDK's `#writeBlobAttributesForRef()`.
  Transaction writeBlobAttributesTransaction({
    required String blobObjectId,
    required Map<String, String?> attributes,
    Map<String, String>? existingAttributes,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();
    final blobObj = tx.object(blobObjectId);

    if (existingAttributes == null) {
      // No metadata exists yet — create and attach.
      final meta = createMetadata(tx: tx);
      addMetadata(tx: tx, blobObject: blobObj, metadata: meta);
    }

    for (final entry in attributes.entries) {
      if (entry.value == null) {
        // Remove this key (only if it existed).
        if (existingAttributes != null &&
            existingAttributes.containsKey(entry.key)) {
          removeMetadataPair(tx: tx, blobObject: blobObj, key: entry.key);
        }
      } else {
        insertOrUpdateMetadataPair(
          tx: tx,
          blobObject: blobObj,
          key: entry.key,
          value: entry.value!,
        );
      }
    }

    return tx;
  }

  // -------------------------------------------------------------------------
  // WAL Exchange Contracts
  // -------------------------------------------------------------------------

  /// Build a transaction that exchanges a specific amount of SUI for WAL.
  ///
  /// Calls `wal_exchange::wal_exchange::exchange_for_wal` on the exchange
  /// object. Splits [amountSui] from [suiCoinObjectId] and exchanges it.
  ///
  /// Returns the resulting WAL coin transaction result.
  ///
  /// Mirrors the TS SDK's WAL exchange contract `exchangeForWal`.
  dynamic exchangeForWalTransaction({
    required String exchangeObjectId,
    required String suiCoinObjectId,
    required BigInt amountSui,
    required String walExchangePackageId,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final suiCoin = tx.object(suiCoinObjectId);
    final result = tx.moveCall(
      '$walExchangePackageId::wal_exchange::exchange_for_wal',
      arguments: [
        tx.object(exchangeObjectId), // self: &mut Exchange
        suiCoin, // sui: &mut Coin<SUI>
        tx.pure.u64(amountSui), // amount_sui: u64
      ],
    );

    return result;
  }

  /// Build a transaction that exchanges a specific amount of WAL for SUI.
  ///
  /// Calls `wal_exchange::wal_exchange::exchange_for_sui` on the exchange
  /// object. Splits [amountWal] from [walCoinObjectId] and exchanges it.
  ///
  /// Returns the resulting SUI coin transaction result.
  ///
  /// Mirrors the TS SDK's WAL exchange contract `exchangeForSui`.
  dynamic exchangeForSuiTransaction({
    required String exchangeObjectId,
    required String walCoinObjectId,
    required BigInt amountWal,
    required String walExchangePackageId,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final walCoin = tx.object(walCoinObjectId);
    final result = tx.moveCall(
      '$walExchangePackageId::wal_exchange::exchange_for_sui',
      arguments: [
        tx.object(exchangeObjectId), // self: &mut Exchange
        walCoin, // wal: &mut Coin<WAL>
        tx.pure.u64(amountWal), // amount_wal: u64
      ],
    );

    return result;
  }

  /// Build a transaction that exchanges all SUI in a coin for WAL.
  ///
  /// Calls `wal_exchange::wal_exchange::exchange_all_for_wal` on the
  /// exchange object. The entire [suiCoinObjectId] balance is exchanged.
  ///
  /// Returns the resulting WAL coin transaction result.
  ///
  /// Mirrors the TS SDK's WAL exchange contract `exchangeAllForWal`.
  dynamic exchangeAllForWalTransaction({
    required String exchangeObjectId,
    required String suiCoinObjectId,
    required String walExchangePackageId,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final result = tx.moveCall(
      '$walExchangePackageId::wal_exchange::exchange_all_for_wal',
      arguments: [
        tx.object(exchangeObjectId), // self: &mut Exchange
        tx.object(suiCoinObjectId), // sui: Coin<SUI>
      ],
    );

    return result;
  }

  /// Build a transaction that exchanges all WAL in a coin for SUI.
  ///
  /// Calls `wal_exchange::wal_exchange::exchange_all_for_sui` on the
  /// exchange object. The entire [walCoinObjectId] balance is exchanged.
  ///
  /// Returns the resulting SUI coin transaction result.
  ///
  /// Mirrors the TS SDK's WAL exchange contract `exchangeAllForSui`.
  dynamic exchangeAllForSuiTransaction({
    required String exchangeObjectId,
    required String walCoinObjectId,
    required String walExchangePackageId,
    Transaction? transaction,
  }) {
    final tx = transaction ?? Transaction();

    final result = tx.moveCall(
      '$walExchangePackageId::wal_exchange::exchange_all_for_sui',
      arguments: [
        tx.object(exchangeObjectId), // self: &mut Exchange
        tx.object(walCoinObjectId), // wal: Coin<WAL>
      ],
    );

    return result;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Convert a 32-byte root hash to BigInt for u256 argument.
  ///
  /// Uses **little-endian** byte order, matching the TS SDK's
  /// `BigInt(bcs.u256().parse(rootHash))` which interprets the
  /// 32-byte array as a BCS u256 (little-endian).
  static BigInt _rootHashToBigInt(Uint8List rootHash) {
    if (rootHash.length != 32) {
      throw ArgumentError('rootHash must be 32 bytes, got ${rootHash.length}');
    }
    // Little-endian: byte[0] is the least significant.
    var result = BigInt.zero;
    for (var i = rootHash.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(rootHash[i]);
    }
    return result;
  }

  /// BCS-encode a u64 value as little-endian 8 bytes.
  static Uint8List _bcsU64(int value) {
    final bytes = Uint8List(8);
    var v = value;
    for (var i = 0; i < 8; i++) {
      bytes[i] = v & 0xFF;
      v >>= 8;
    }
    return bytes;
  }
}
