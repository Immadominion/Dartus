/// Tests for storage node types: [StorageConfirmation], [SliverData],
/// [BlobStatus], etc.
///
/// Verifies JSON parsing, base64 decoding, and type constructors
/// match the wire format returned by Walrus storage nodes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartus/src/models/storage_node_types.dart';
import 'package:test/test.dart';

void main() {
  group('SliverType', () {
    test('has correct wire values', () {
      expect(SliverType.primary.value, 'primary');
      expect(SliverType.secondary.value, 'secondary');
    });
  });

  group('SliverData', () {
    test('constructs with correct properties', () {
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final sliver = SliverData(data: data, symbolSize: 2, index: 5);
      expect(sliver.data, equals(data));
      expect(sliver.symbolSize, 2);
      expect(sliver.index, 5);
    });

    test('toString includes relevant info', () {
      final sliver = SliverData(data: Uint8List(100), symbolSize: 8, index: 3);
      final str = sliver.toString();
      expect(str, contains('index: 3'));
      expect(str, contains('dataLen: 100'));
      expect(str, contains('symbolSize: 8'));
    });
  });

  group('StorageConfirmation', () {
    test('fromJson decodes base64 serializedMessage', () {
      // Create a known binary payload.
      final msgBytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final msgBase64 = base64Encode(msgBytes);

      final json = {
        'serializedMessage': msgBase64,
        'signature': 'someSigBase64==',
      };

      final conf = StorageConfirmation.fromJson(json);
      expect(conf.serializedMessage, equals(msgBytes));
      expect(conf.signature, 'someSigBase64==');
    });

    test('fromJson handles snake_case field name fallback', () {
      final msgBytes = Uint8List.fromList([1, 2, 3]);
      final json = {
        'serialized_message': base64Encode(msgBytes),
        'signature': 'sig',
      };

      final conf = StorageConfirmation.fromJson(json);
      expect(conf.serializedMessage, equals(msgBytes));
    });

    test('fromJson handles List<int> serializedMessage', () {
      final json = {
        'serializedMessage': [10, 20, 30, 40],
        'signature': 'sig',
      };

      final conf = StorageConfirmation.fromJson(json);
      expect(
        conf.serializedMessage,
        equals(Uint8List.fromList([10, 20, 30, 40])),
      );
    });

    test('fromJson throws on invalid field type', () {
      final json = {'serializedMessage': 42, 'signature': 'sig'};

      expect(
        () => StorageConfirmation.fromJson(json),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('BlobStatus types', () {
    test('BlobStatusNonexistent is const', () {
      const status = BlobStatusNonexistent();
      expect(status, isA<BlobStatus>());
    });

    test('BlobStatusPermanent carries endEpoch', () {
      const status = BlobStatusPermanent(endEpoch: 42);
      expect(status.endEpoch, 42);
    });

    test('BlobStatusDeletable carries initialCertifiedEpoch', () {
      const status = BlobStatusDeletable(initialCertifiedEpoch: 100);
      expect(status.initialCertifiedEpoch, 100);
    });

    test('BlobStatusInvalid is const', () {
      const status = BlobStatusInvalid();
      expect(status, isA<BlobStatus>());
    });
  });

  group('StorageNodeInfo', () {
    test('constructs with required fields', () {
      final node = StorageNodeInfo(
        nodeId: 'node-1',
        endpointUrl: 'https://node-1.walrus.space',
        shardIndices: [0, 1, 2],
      );
      expect(node.nodeId, 'node-1');
      expect(node.endpointUrl, 'https://node-1.walrus.space');
      expect(node.shardIndices, [0, 1, 2]);
    });
  });

  group('CommitteeInfo', () {
    test('nodeByShardIndex maps shards to nodes', () {
      final node0 = StorageNodeInfo(
        nodeId: 'a',
        endpointUrl: 'https://a.example.com',
        shardIndices: [0, 1],
      );
      final node1 = StorageNodeInfo(
        nodeId: 'b',
        endpointUrl: 'https://b.example.com',
        shardIndices: [2, 3],
      );

      final committee = CommitteeInfo(
        epoch: 1,
        numShards: 4,
        nodeByShardIndex: {0: node0, 1: node0, 2: node1, 3: node1},
      );

      expect(committee.nodeByShardIndex.length, 4);
      expect(committee.nodeByShardIndex[0]!.nodeId, 'a');
      expect(committee.nodeByShardIndex[2]!.nodeId, 'b');
      expect(committee.getNodeForShard(3)!.nodeId, 'b');
      expect(committee.getNodeForShard(99), isNull);
    });
  });

  group('EncodedBlob', () {
    test('holds encoding artifacts', () {
      final encoded = EncodedBlob(
        blobId: 'test-blob-id',
        blobIdBytes: Uint8List(32),
        metadataBytes: Uint8List(128),
        primarySlivers: [],
        secondarySlivers: [],
        rootHash: Uint8List(32),
        unencodedLength: 1024,
      );
      expect(encoded.blobId, 'test-blob-id');
      expect(encoded.unencodedLength, 1024);
      expect(encoded.primarySlivers, isEmpty);
    });
  });
}
