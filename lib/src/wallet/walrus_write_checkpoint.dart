part of 'walrus_writer.dart';

/// A versioned snapshot of an upload. File bytes can be stored separately.
///
/// The snapshot contains relay authentication material and transaction intents;
/// keep it in the same private storage as the file being uploaded.
class WalrusWriteCheckpoint {
  WalrusWriteCheckpoint._(this._state, this.data, this.files);

  final Map<String, dynamic> _state;
  final Uint8List data;
  final List<QuiltBlob>? files;

  int get version => 1;
  String get kind => _state['kind'] as String;
  bool get isFiles => _state['kind'] == 'files';
  String get network => _state['network'] as String;
  String? get owner => _state['owner'] as String?;
  String? get registerDigest => _state['registerDigest'] as String?;
  String? get certifyDigest => _state['certifyDigest'] as String?;
  String? get blobObjectId => _state['blobObjectId'] as String?;
  String? get pendingRequestId => (_state['request'] as Map?)?['id'] as String?;

  /// Omit bytes when the caller has already stored them in a separate record.
  Map<String, dynamic> toJson({bool includeData = true}) {
    final json = _cloneMap(_state);
    json['checksum'] = _stateHash(json);
    if (includeData) {
      if (isFiles) {
        json['fileData'] = [
          for (final file in files!) base64Encode(file.contents),
        ];
      } else {
        json['data'] = base64Encode(data);
      }
    }
    return json;
  }

  /// [data] supplies a blob's bytes when omitted by [toJson]. For quilts,
  /// [files] supplies the original files, including their identifiers and tags.
  factory WalrusWriteCheckpoint.fromJson(
    Map<String, dynamic> json, {
    Uint8List? data,
    List<QuiltBlob>? files,
  }) {
    final state = _cloneMap({
      for (final entry in json.entries)
        if (!const {'checksum', 'data', 'fileData'}.contains(entry.key))
          entry.key: entry.value,
    });
    if (state['version'] != 1 ||
        !const {'blob', 'files'}.contains(state['kind']) ||
        json['checksum'] != _stateHash(state)) {
      throw const FormatException('Invalid or unsupported upload checkpoint');
    }
    if (state['kind'] == 'files') {
      final records = _list(state['files'], 'files');
      final embedded = json['fileData'];
      if (files == null) {
        final values = _list(embedded, 'fileData');
        if (values.length != records.length) {
          throw const FormatException('Checkpoint file count differs');
        }
        files = [
          for (var i = 0; i < records.length; i++)
            QuiltBlob(
              identifier: _string(
                _map(records[i], 'file')['identifier'],
                'identifier',
              ),
              tags: _tags(_map(records[i], 'file')['tags']),
              contents: _bytes(values[i], 'fileData'),
            ),
        ];
      }
      if (files.length != records.length || files.isEmpty) {
        throw const FormatException('Checkpoint file count differs');
      }
      final copied = <QuiltBlob>[];
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        final record = _map(records[i], 'file');
        if (file.identifier != record['identifier'] ||
            file.contents.length != record['size'] ||
            sha256.convert(file.contents).toString() != record['sha256'] ||
            _canonical(file.tags ?? const <String, String>{}) !=
                _canonical(_tags(record['tags']))) {
          throw const FormatException(
            'Checkpoint file content or metadata differs',
          );
        }
        copied.add(
          QuiltBlob(
            identifier: file.identifier,
            contents: Uint8List.fromList(file.contents).asUnmodifiableView(),
            tags: Map.unmodifiable(file.tags ?? const <String, String>{}),
          ),
        );
      }
      files = List.unmodifiable(copied);
      if (state['quiltShards'] == null) {
        if (state['index'] != null ||
            state['metadata'] != null ||
            state['request'] != null ||
            state['registerDigest'] != null) {
          throw const FormatException('Checkpoint has no quilt layout');
        }
        data = Uint8List(0).asUnmodifiableView();
      } else {
        final quilt = encodeQuilt(
          blobs: files,
          numShards: _integer(state['quiltShards'], 'quiltShards', minimum: 1),
        );
        if (_canonical(_indexJson(quilt.index)) != _canonical(state['index'])) {
          throw const FormatException('Checkpoint quilt layout differs');
        }
        data = quilt.quilt.asUnmodifiableView();
      }
    } else {
      data ??= _bytes(json['data'], 'data');
      data = Uint8List.fromList(data).asUnmodifiableView();
    }
    if (data.length != state['size'] ||
        sha256.convert(data).toString() != state['sha256']) {
      throw const FormatException('Checkpoint bytes do not match the upload');
    }
    return WalrusWriteCheckpoint._(state, data, files);
  }
}

WalrusWriteCheckpoint _blobCheckpoint(WalrusWriteFlow flow) {
  final metadata = flow._metadata;
  final cost = flow._cost;
  final transaction = flow._pendingTransaction;
  return WalrusWriteCheckpoint._(
    {
      'version': 1,
      'kind': 'blob',
      'network': flow._writer.network.name,
      'relay': flow._writer.relay.host,
      'epochs': flow.epochs,
      'deletable': flow.deletable,
      'recipient': flow.recipient,
      'size': flow.data.length,
      'sha256': flow._dataHash,
      'owner': flow._owner,
      'metadata': metadata == null
          ? null
          : {
              'blobId': metadata.blobId,
              'rootHash': base64Encode(metadata.rootHash),
              'size': metadata.unencodedLength,
              'encodingType': metadata.encodingType,
              'nonce': base64Encode(metadata.nonce),
              'blobDigest': base64Encode(metadata.blobDigest),
              'shards': flow._metadataShards,
            },
      'cost': cost == null
          ? null
          : {
              'encodedSize': cost.encodedSize,
              'storageCost': cost.storageCost.toString(),
              'writeCost': cost.writeCost.toString(),
            },
      'tip': flow._tip.toString(),
      'tipped': flow._tipped,
      'certificate': flow._certificate?.toJson(),
      'registerDigest': flow.registerDigest,
      'blobObjectId': flow.blobObjectId,
      'certifyDigest': flow.certifyDigest,
      'request': transaction == null
          ? null
          : {
              'id': flow._pendingRequestId,
              'registration': flow._unknownIsRegistration,
              'transaction': {
                'json': transaction.json,
                'sender': transaction.sender,
                'chain': transaction.chain,
                'description': transaction.description,
              },
            },
    },
    flow.data,
    null,
  );
}

WalrusWriteCheckpoint _filesCheckpoint(
  WalrusWriteFilesFlow flow,
  WalrusWriteCheckpoint blob,
) => WalrusWriteCheckpoint._(
  {
    ...blob._state,
    'kind': 'files',
    'quiltShards': flow._shards,
    'index': flow._index == null ? null : _indexJson(flow._index!),
    'files': flow._fileRecords ??= [
      for (final file in flow.files)
        {
          'identifier': file.identifier,
          'tags': file.tags ?? const <String, String>{},
          'size': file.contents.length,
          'sha256': sha256.convert(file.contents).toString(),
        },
    ],
  },
  blob.data,
  flow.files,
);

Future<WalrusWriteFlow> _restoreBlobFlow(
  WalrusWriter writer,
  WalrusWriteCheckpoint checkpoint,
  Future<void> Function(WalrusWriteCheckpoint)? onCheckpoint, {
  bool allowFiles = false,
}) async {
  final state = checkpoint._state;
  if ((checkpoint.isFiles && !allowFiles) ||
      state['network'] != writer.network.name ||
      state['relay'] != writer.relay.host) {
    throw const FormatException('Checkpoint kind, network or relay differs');
  }
  final flow = writer.writeFlow(
    checkpoint.data,
    epochs: _integer(state['epochs'], 'epochs', minimum: 1),
    deletable: _boolean(state['deletable'], 'deletable'),
    recipient: state['recipient'] == null
        ? null
        : _string(state['recipient'], 'recipient'),
    onCheckpoint: onCheckpoint,
  );
  flow._owner = state['owner'] == null
      ? null
      : _walletAddress(_string(state['owner'], 'owner'), 'owner');
  final storedMetadata = state['metadata'];
  if (storedMetadata != null) {
    final m = _map(storedMetadata, 'metadata');
    final shards = _integer(m['shards'], 'shards', minimum: 1);
    final metadata = BlobMetadata(
      blobId: _string(m['blobId'], 'blobId'),
      rootHash: _bytes(m['rootHash'], 'rootHash', length: 32),
      unencodedLength: _integer(m['size'], 'metadata.size'),
      encodingType: _integer(m['encodingType'], 'encodingType', minimum: 1),
      nonce: _bytes(m['nonce'], 'nonce', length: 32),
      blobDigest: _bytes(m['blobDigest'], 'blobDigest', length: 32),
    );
    final computed = await writer.encoder.computeMetadata(flow.data, shards);
    if (metadata.unencodedLength != flow.data.length ||
        metadata.blobId != computed.blobId ||
        metadata.encodingType != computed.encodingType ||
        !_equalBytes(metadata.rootHash, computed.rootHash) ||
        !_equalBytes(metadata.blobDigest, computed.blobDigest) ||
        !_equalBytes(metadata.blobDigest, sha256.convert(flow.data).bytes)) {
      throw const FormatException(
        'Checkpoint encoding does not match the file',
      );
    }
    // The newly computed nonce is unrelated to the paid relay tip.
    flow._metadata = metadata;
    flow._metadataShards = shards;
  }
  final c = state['cost'];
  if (c != null) {
    final cost = _map(c, 'cost');
    flow._cost = WalrusStorageCost(
      encodedSize: _integer(cost['encodedSize'], 'encodedSize', minimum: 1),
      storageCost: _amount(cost['storageCost'], 'storageCost'),
      writeCost: _amount(cost['writeCost'], 'writeCost'),
    );
  }
  flow._tip = _amount(state['tip'], 'tip');
  flow._tipped = _boolean(state['tipped'], 'tipped');
  if (writer.maxRelayTip != null && flow._tip > writer.maxRelayTip!) {
    throw const FormatException('Saved relay tip exceeds the current budget');
  }
  flow._registerDigest = _optionalString(
    state['registerDigest'],
    'registerDigest',
  );
  flow._certifyDigest = _optionalString(
    state['certifyDigest'],
    'certifyDigest',
  );
  flow._blobObjectId = state['blobObjectId'] == null
      ? null
      : _walletAddress(
          _string(state['blobObjectId'], 'blobObjectId'),
          'blobObjectId',
        );
  final cert = state['certificate'];
  if (cert != null) {
    final value = _map(cert, 'certificate');
    final signers = _list(
      value['signers'],
      'signers',
    ).map((i) => _integer(i, 'signer')).toList();
    if (signers.isEmpty || signers.toSet().length != signers.length) {
      throw const FormatException('Invalid certificate signers');
    }
    flow._certificate = ProtocolMessageCertificate(
      signers: List.unmodifiable(signers),
      serializedMessage: _byteList(
        value['serialized_message'],
        'serialized_message',
      ),
      signature: _byteList(value['signature'], 'signature', length: 96),
    );
  }
  if ((flow.registerDigest != null || state['request'] != null) &&
      (flow._metadata == null || flow._owner == null || flow._cost == null)) {
    throw const FormatException('Paid upload is missing registration metadata');
  }
  if ((flow.blobObjectId != null && flow.registerDigest == null) ||
      (flow._certificate != null && flow.blobObjectId == null) ||
      (flow.certifyDigest != null && flow._certificate == null)) {
    throw const FormatException('Checkpoint upload stages are inconsistent');
  }
  final request = state['request'];
  if (request != null) {
    final saved = _map(request, 'request');
    final tx = _map(saved['transaction'], 'transaction');
    final transaction = WalletTransaction(
      json: _string(tx['json'], 'transaction.json'),
      sender: _walletAddress(
        _string(tx['sender'], 'transaction.sender'),
        'transaction.sender',
      ),
      chain: _string(tx['chain'], 'transaction.chain'),
      description: _string(tx['description'], 'transaction.description'),
    );
    flow._unknownIsRegistration = _boolean(
      saved['registration'],
      'registration',
    );
    if (transaction.sender != flow._owner ||
        transaction.chain != writer.network.suiChain ||
        (flow._unknownIsRegistration
            ? flow.registerDigest != null
            : flow._certificate == null || flow.certifyDigest != null)) {
      throw const FormatException(
        'Checkpoint wallet request does not match its upload',
      );
    }
    final transactionData = Transaction.from(transaction.json).getData();
    if (_walletAddress(transactionData.sender ?? '', 'transaction sender') !=
        flow._owner) {
      throw const FormatException('Checkpoint transaction sender differs');
    }
    flow._pendingTransaction = transaction;
    flow._pendingRequestId = _string(saved['id'], 'request.id');
    flow._unknownOutcome = WalrusTransactionOutcomeUnknown(
      transaction,
      StateError('Restored pending wallet request'),
    );
  }
  if (flow.registerDigest != null) {
    final snapshot = await writer.chain.system();
    final List<String> created;
    try {
      created = await writer.chain.createdObjects(
        flow.registerDigest!,
        type: snapshot.blobType,
      );
    } on WalrusTransactionExecutionFailed {
      if (flow.blobObjectId != null) {
        throw const FormatException('A failed registration cannot own a blob');
      }
      flow._registerDigest = null;
      flow._clearPending();
      return flow;
    }
    if (created.length != 1 ||
        (flow.blobObjectId != null && created.single != flow.blobObjectId)) {
      throw const FormatException(
        'Registration receipt does not match the checkpoint',
      );
    }
    if (flow.certifyDigest != null) {
      try {
        await writer.chain.waitForSuccess(flow.certifyDigest!);
      } on WalrusTransactionExecutionFailed {
        flow._certifyDigest = null;
        flow._clearPending();
      }
    }
    final blob = await writer.chain.blobObject(created.single);
    var expectedOwner = flow.certifyDigest == null
        ? flow._owner!
        : flow.recipient ?? flow._owner!;
    if (flow._pendingTransaction != null &&
        !flow._unknownIsRegistration &&
        flow.recipient != null &&
        blob.owner == flow.recipient) {
      // An interrupted certification may already have transferred the blob.
      expectedOwner = flow.recipient!;
    }
    flow._validateBlob(
      blob,
      expectedOwner: expectedOwner,
      objectId: created.single,
    );
    if (flow.certifyDigest == null && blob.endEpoch <= snapshot.epoch) {
      throw const WalrusClientError(
        'The registered upload storage has expired',
      );
    }
    flow._blobObjectId = created.single;
    if (flow.certifyDigest != null) {
      if (!blob.isCertified) {
        throw const FormatException('Saved certification is not confirmed');
      }
      flow._result = WalrusWriteResult(
        blob: blob,
        registerDigest: flow.registerDigest!,
        certifyDigest: flow.certifyDigest!,
        cost: flow._cost,
        relayTip: flow._tip,
      );
    }
  }
  return flow;
}

Future<WalrusWriteFilesFlow> _restoreFilesFlow(
  WalrusWriter writer,
  WalrusWriteCheckpoint checkpoint,
  Future<void> Function(WalrusWriteCheckpoint)? onCheckpoint,
) async {
  if (!checkpoint.isFiles || checkpoint.files == null) {
    throw const FormatException('A quilt checkpoint is required');
  }
  final state = checkpoint._state;
  final filesFlow = writer.writeFilesFlow(
    checkpoint.files!,
    epochs: _integer(state['epochs'], 'epochs', minimum: 1),
    deletable: _boolean(state['deletable'], 'deletable'),
    recipient: _optionalString(state['recipient'], 'recipient'),
    onCheckpoint: onCheckpoint,
  );
  if (state['network'] != writer.network.name ||
      state['relay'] != writer.relay.host) {
    throw const FormatException('Checkpoint network or relay differs');
  }
  if (state['quiltShards'] == null) return filesFlow;
  filesFlow._shards = _integer(state['quiltShards'], 'quiltShards', minimum: 1);
  filesFlow._index = encodeQuilt(
    blobs: filesFlow.files,
    numShards: filesFlow._shards!,
  ).index;
  filesFlow._flow = await _restoreBlobFlow(
    writer,
    checkpoint,
    filesFlow._saveBlobCheckpoint,
    allowFiles: true,
  );
  return filesFlow;
}

List<Map<String, dynamic>> _indexJson(QuiltIndex index) => [
  for (final patch in index.patches)
    {
      'identifier': patch.identifier,
      'tags': patch.tags,
      'startIndex': patch.startIndex,
      'endIndex': patch.endIndex,
    },
];

String _newRequestId() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Map<String, dynamic> _cloneMap(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
String _stateHash(Map<String, dynamic> value) =>
    sha256.convert(utf8.encode(_canonical(value))).toString();
String _canonical(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map<String, dynamic>) throw FormatException('Invalid $name');
  return value;
}

List<dynamic> _list(Object? value, String name) {
  if (value is! List) throw FormatException('Invalid $name');
  return value;
}

String _string(Object? value, String name) {
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid $name');
  }
  return value;
}

String? _optionalString(Object? value, String name) =>
    value == null ? null : _string(value, name);
int _integer(Object? value, String name, {int minimum = 0}) {
  if (value is! int || value < minimum) throw FormatException('Invalid $name');
  return value;
}

bool _boolean(Object? value, String name) {
  if (value is! bool) throw FormatException('Invalid $name');
  return value;
}

BigInt _amount(Object? value, String name) {
  final amount = BigInt.tryParse(_string(value, name));
  if (amount == null || amount.isNegative) {
    throw FormatException('Invalid $name');
  }
  return amount;
}

Uint8List _bytes(Object? value, String name, {int? length}) {
  if (value is! String) throw FormatException('Invalid $name');
  final bytes = base64Decode(value);
  if (length != null && bytes.length != length) {
    throw FormatException('Invalid $name length');
  }
  return bytes.asUnmodifiableView();
}

Uint8List _byteList(Object? value, String name, {int? length}) {
  final values = _list(value, name);
  if (values.any((b) => b is! int || b < 0 || b > 255) ||
      (length != null && values.length != length)) {
    throw FormatException('Invalid $name bytes');
  }
  return Uint8List.fromList(values.cast<int>()).asUnmodifiableView();
}

Map<String, String> _tags(Object? value) =>
    _map(value, 'tags').map((key, value) => MapEntry(key, value as String));
bool _equalBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
