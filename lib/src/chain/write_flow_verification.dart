import 'package:sui/sui.dart';

import '../errors/walrus_errors.dart';
import '../utils/blob_id_utils.dart';

/// Parse the current gRPC scalar/null or legacy Move `Option<u32>` JSON.
int? certifiedEpochFromJson(Object? value) {
  if (value == null) return null;
  if (value is int && value >= 0) return value;
  if (value is String) return int.tryParse(value);
  if (value is Map) {
    final fields = value['fields'] ?? value;
    if (fields is Map && fields['vec'] is List) {
      final values = fields['vec'] as List;
      if (values.isEmpty) return null;
      if (values.length == 1) return certifiedEpochFromJson(values.single);
    }
  }
  throw const FormatException('Invalid certified_epoch option');
}

/// Confirm an externally signed flow against chain state instead of treating
/// construction of an unsigned certify transaction as successful execution.
Future<void> verifyFlowBlob({
  required SuiClient client,
  required String objectId,
  required String blobId,
  required String blobType,
  required int size,
  required bool deletable,
  required String owner,
  required bool certified,
  String? digest,
}) async {
  if (digest != null) {
    final transaction = await client.waitForTransaction(
      digest,
      options: SuiTransactionBlockResponseOptions(showEffects: true),
    );
    if ((transaction.effects != null &&
            transaction.effects!.status.status !=
                ExecutionStatusType.success) ||
        (transaction.effects == null &&
            transaction.confirmedLocalExecution != true) ||
        (transaction.errors?.isNotEmpty ?? false)) {
      throw WalrusClientError('Transaction $digest did not succeed');
    }
  }
  final response = await client.getObject(
    objectId,
    options: SuiObjectDataOptions(
      showContent: true,
      showType: true,
      showOwner: true,
    ),
  );
  final data = response.data;
  final fields = data?.content?.fields;
  if (data?.type != blobType || fields is! Map) {
    throw WalrusClientError(
      'Object $objectId is not the expected Walrus Blob type',
    );
  }
  final parsedId = BigInt.tryParse(fields['blob_id'].toString());
  if (parsedId == null ||
      blobIdFromInt(parsedId) != blobId ||
      BigInt.tryParse(fields['size'].toString()) != BigInt.from(size) ||
      fields['deletable'] != deletable) {
    throw WalrusClientError(
      'Registered object $objectId does not match the requested blob',
    );
  }
  final address = data!.owner?.addressOwner;
  if (address is! String ||
      SuiBcs.Address.serialize(address).toHex() !=
          SuiBcs.Address.serialize(owner).toHex()) {
    throw WalrusClientError(
      'Blob $objectId is not owned by the registering wallet',
    );
  }
  if (certified && certifiedEpochFromJson(fields['certified_epoch']) == null) {
    throw WalrusClientError('Blob $objectId has not been certified on chain');
  }
}
