import 'dart:convert';
import 'dart:typed_data';

import 'package:sui/sui.dart';

import '../crypto/bls_provider.dart';
import '../errors/walrus_errors.dart';
import '../models/protocol_types.dart';
import '../models/storage_node_types.dart';
import '../utils/encoding_utils.dart';

/// The exact Walrus StorageConfirmation BCS message, bound to its epoch,
/// blob and (for a deletable blob) the registered Sui object.
Uint8List storageConfirmationMessage({
  required String blobId,
  required int epoch,
  required bool deletable,
  required String blobObjectId,
}) {
  if (epoch < 0 || epoch > 0xffffffff) {
    throw ArgumentError.value(epoch, 'epoch', 'Must fit u32');
  }
  return (BytesBuilder(copy: false)
        ..add([1, 0, 3]) // BLOB_CERT_MSG, intent version 0, Walrus app ID.
        ..add(SuiBcs.U32.serialize(epoch).toBytes())
        ..add(blobIdFromUrlSafeBase64(blobId))
        ..addByte(deletable ? 1 : 0)
        ..add(
          deletable ? SuiBcs.Address.serialize(blobObjectId).toBytes() : [],
        ))
      .toBytes();
}

/// Aggregate one authenticated confirmation per committee node, in committee
/// order. A node owning several shards still occupies one signer bitmap bit.
ProtocolMessageCertificate buildStorageCertificate({
  required Map<int, StorageConfirmation?> confirmations,
  required CommitteeInfo committee,
  required BlsProvider provider,
  required String blobId,
  required String blobObjectId,
  required bool deletable,
}) {
  final nodes = committee.nodes;
  final message = storageConfirmationMessage(
    blobId: blobId,
    epoch: committee.epoch,
    deletable: deletable,
    blobObjectId: blobObjectId,
  );
  final signers = <int>[];
  final signatures = <Uint8List>[];
  final publicKeys = <Uint8List>[];
  var signedShards = 0;
  for (var i = 0; i < nodes.length; i++) {
    final confirmation = confirmations[i];
    final publicKey = nodes[i].publicKey;
    if (confirmation == null ||
        publicKey == null ||
        (publicKey.length != 48 && publicKey.length != 96) ||
        base64Encode(confirmation.serializedMessage) != base64Encode(message)) {
      continue;
    }
    try {
      final signature = base64Decode(confirmation.signature);
      if (signature.length != 96 ||
          !provider.verify(signature, publicKey, message)) {
        continue;
      }
      signedShards += nodes[i].shardIndices.length;
      signers.add(i);
      signatures.add(signature);
      publicKeys.add(publicKey);
    } on FormatException {
      continue;
    }
  }
  if (nodes.isEmpty || !isQuorum(signedShards, committee.numShards)) {
    throw NotEnoughBlobConfirmationsError(
      'Valid confirmations cover $signedShards/${committee.numShards} shards and do not form a quorum',
    );
  }
  final signature = signatures.length == 1
      ? signatures.single
      : provider.aggregate(signatures);
  if (signature.length != 96 ||
      !provider.verifyAggregate(publicKeys, message, signature)) {
    throw const NotEnoughBlobConfirmationsError(
      'Invalid aggregate storage certificate',
    );
  }
  return ProtocolMessageCertificate(
    signers: signers,
    serializedMessage: message,
    signature: signature,
  );
}
