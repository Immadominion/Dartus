@TestOn('vm')
@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/direct.dart';
import 'package:dartus/src/chain/storage_certificate.dart';
import 'package:test/test.dart';

class _Bls implements BlsProvider {
  final verifiedKeys = <int>[];
  int aggregated = 0;
  bool aggregateValid = true;
  @override
  bool verify(Uint8List signature, Uint8List publicKey, Uint8List message) {
    verifiedKeys.add(publicKey.length);
    return signature.first == publicKey.first;
  }

  @override
  Uint8List aggregate(List<Uint8List> signatures) {
    aggregated = signatures.length;
    return Uint8List(96);
  }

  @override
  bool verifyAggregate(
    List<Uint8List> publicKeys,
    Uint8List message,
    Uint8List aggregateSignature,
  ) => aggregateValid;
}

void main() {
  final blobId = base64UrlEncode(Uint8List(32)).replaceAll('=', '');
  final nodes = List.generate(
    4,
    (i) => StorageNodeInfo(
      nodeId: 'node000$i',
      endpointUrl: 'http://127.0.0.1:1',
      shardIndices: i == 0 ? [0, 1, 2, 3, 4, 5, 6] : [i + 6],
      publicKey: Uint8List(96)..[0] = i + 1,
    ),
  );
  final committee = CommitteeInfo(
    numShards: 10,
    epoch: 258,
    members: nodes,
    nodeByShardIndex: {
      for (final n in nodes)
        for (final shard in n.shardIndices) shard: n,
    },
  );
  final message = storageConfirmationMessage(
    blobId: blobId,
    epoch: 258,
    deletable: true,
    blobObjectId: '0x1',
  );
  Map<int, StorageConfirmation?> confirmations(
    List<int> signers, {
    Uint8List? msg,
  }) => {
    for (final i in signers)
      i: StorageConfirmation(
        serializedMessage: msg ?? message,
        signature: base64Encode(Uint8List(96)..[0] = i + 1),
      ),
  };
  ProtocolMessageCertificate build(
    Map<int, StorageConfirmation?> input,
    _Bls bls,
  ) => buildStorageCertificate(
    confirmations: input,
    committee: committee,
    provider: bls,
    blobId: blobId,
    blobObjectId: '0x1',
    deletable: true,
  );

  test(
    'confirmation intent, epoch, persistence and object are canonical BCS',
    () {
      expect(message, [
        1,
        0,
        3,
        2,
        1,
        0,
        0,
        ...List.filled(32, 0),
        1,
        ...List.filled(31, 0),
        1,
      ]);
    },
  );
  test('one heavy member reaches shard quorum and keeps member index', () {
    final bls = _Bls();
    final cert = build(confirmations([0]), bls);
    expect(cert.signers, [0]);
    expect(bls.verifiedKeys, [96]);
  });
  test('three light members fail despite node-count majority', () {
    expect(
      () => build(confirmations([1, 2, 3]), _Bls()),
      throwsA(isA<NotEnoughBlobConfirmationsError>()),
    );
  });
  test('multi-shard member contributes one signature to aggregation', () {
    final bls = _Bls();
    final cert = build(confirmations([0, 1, 2]), bls);
    expect(cert.signers, [0, 1, 2]);
    expect(bls.aggregated, 3);
  });
  test(
    'wrong epoch, blob, object and malformed signatures are not counted',
    () {
      for (final index in [3, 7, 71]) {
        final bad = Uint8List.fromList(message)..[index] ^= 1;
        expect(
          () => build(confirmations([0], msg: bad), _Bls()),
          throwsA(isA<NotEnoughBlobConfirmationsError>()),
        );
      }
      final bad = {
        0: StorageConfirmation(
          serializedMessage: message,
          signature: 'not-base64',
        ),
      };
      expect(
        () => build(bad, _Bls()),
        throwsA(isA<NotEnoughBlobConfirmationsError>()),
      );
    },
  );
  test('invalid aggregate cannot become a certificate', () {
    expect(
      () => build(confirmations([0, 1]), _Bls()..aggregateValid = false),
      throwsA(isA<NotEnoughBlobConfirmationsError>()),
    );
  });
  test(
    'direct writer sends metadata and confirmation once per node, all assigned slivers first',
    () async {
      final servers = <HttpServer>[];
      final paths = <List<String>>[];
      final loopbackNodes = <StorageNodeInfo>[];
      final blob = WalrusBlobEncoder().encodeBlob(
        Uint8List.fromList([1, 2, 3, 4, 5]),
        4,
      );
      for (var i = 0; i < 2; i++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        final requests = <String>[];
        paths.add(requests);
        server.listen((request) async {
          final bytes = await request.fold<List<int>>([], (all, chunk) {
            all.addAll(chunk);
            return all;
          });
          requests.add(request.uri.path);
          if (request.uri.path.contains('/slivers/')) {
            final segments = request.uri.pathSegments;
            final pairIndex = int.parse(segments[4]);
            final index = bytes[bytes.length - 2] | (bytes.last << 8);
            final expectedPair = segments.last == 'primary' ? index : 3 - index;
            // Mirror the storage node's axis-specific pair/index validation.
            if (pairIndex != expectedPair) {
              request.response.statusCode = HttpStatus.badRequest;
              request.response.write('SLIVER_INDEX_MISMATCH');
            }
          }
          if (request.uri.path.contains('/confirmation/')) {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'success': {
                  'data': {
                    'signed': {
                      'serialized_message': base64Encode(message),
                      'signature': base64Encode(Uint8List(96)),
                    },
                  },
                },
              }),
            );
          }
          await request.response.close();
        });
        loopbackNodes.add(
          StorageNodeInfo(
            nodeId: 'loopback$i',
            endpointUrl: 'http://127.0.0.1:${server.port}',
            shardIndices: [i * 2, i * 2 + 1],
            publicKey: Uint8List(96),
          ),
        );
      }
      addTearDown(() async {
        for (final server in servers) {
          await server.close(force: true);
        }
      });
      final localCommittee = CommitteeInfo(
        numShards: 4,
        epoch: 258,
        members: loopbackNodes,
        nodeByShardIndex: {
          for (final node in loopbackNodes)
            for (final shard in node.shardIndices) shard: node,
        },
      );
      final client = WalrusDirectClient(
        network: WalrusNetwork.testnet,
        blsProvider: _Bls(),
      );
      addTearDown(client.close);
      final result = await client.writeEncodedBlobToNodes(
        encodedBlob: blob,
        committee: localCommittee,
        deletable: true,
        blobObjectId: '0x1',
        maxConcurrency: 1,
      );
      expect(result.keys, [0, 1]);
      expect(result.values, everyElement(isNotNull));
      for (final requests in paths) {
        expect(requests, hasLength(6));
        expect(requests.first, endsWith('/metadata'));
        expect(
          requests.where((path) => path.contains('/slivers/')),
          hasLength(4),
        );
        expect(requests.last, endsWith('/confirmation/deletable/0x1'));
      }
    },
  );
}
