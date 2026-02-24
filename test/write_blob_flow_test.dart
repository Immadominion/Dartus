/// Tests for WriteBlobFlow blob object ID extraction logic.
///
/// NOTE: WriteBlobFlow itself imports `package:sui` which depends on
/// Flutter (`dart:ui`), so it cannot be loaded in plain `dart test`.
/// These tests verify the blob object ID extraction patterns
/// independently of the flow class.
library;

import 'package:test/test.dart';

void main() {
  group('Blob object ID extraction from transaction result', () {
    /// Mirrors the extraction logic in WriteBlobFlow._extractBlobObjectIdFromResult
    String? extractBlobObjectId(Map<String, dynamic> txResult) {
      // Try objectChanges first.
      final objectChanges = txResult['objectChanges'];
      if (objectChanges is List) {
        for (final change in objectChanges) {
          if (change is Map &&
              change['type'] == 'created' &&
              change['objectType'] != null &&
              change['objectType'].toString().contains('::blob::Blob')) {
            return change['objectId'] as String?;
          }
        }
      }

      // Fallback: effects.created
      final effects = txResult['effects'];
      if (effects is Map) {
        final created = effects['created'];
        if (created is List && created.isNotEmpty) {
          final first = created.first;
          if (first is Map) {
            return (first['reference']?['objectId'] ?? first['objectId'])
                ?.toString();
          }
        }
      }

      return null;
    }

    test('extracts from objectChanges with ::blob::Blob type', () {
      final result = extractBlobObjectId({
        'objectChanges': [
          {
            'type': 'mutated',
            'objectType': '0x2::coin::Coin<0x2::sui::SUI>',
            'objectId': '0xnotthis',
          },
          {
            'type': 'created',
            'objectType': '0xpkg::blob::Blob',
            'objectId': '0xthisone',
          },
        ],
      });
      expect(result, '0xthisone');
    });

    test('ignores mutated Blob objects (only finds created)', () {
      final result = extractBlobObjectId({
        'objectChanges': [
          {
            'type': 'mutated',
            'objectType': '0xpkg::blob::Blob',
            'objectId': '0xmutated',
          },
        ],
      });
      expect(result, isNull);
    });

    test('falls back to effects.created', () {
      final result = extractBlobObjectId({
        'effects': {
          'created': [
            {
              'reference': {'objectId': '0xfromEffects'},
            },
          ],
        },
      });
      expect(result, '0xfromEffects');
    });

    test('effects.created without reference uses objectId directly', () {
      final result = extractBlobObjectId({
        'effects': {
          'created': [
            {'objectId': '0xdirect'},
          ],
        },
      });
      expect(result, '0xdirect');
    });

    test('returns null when no blob found', () {
      final result = extractBlobObjectId({
        'objectChanges': [
          {
            'type': 'created',
            'objectType': '0x2::coin::Coin',
            'objectId': '0xnotblob',
          },
        ],
      });
      expect(result, isNull);
    });

    test('returns null for empty result', () {
      final result = extractBlobObjectId({});
      expect(result, isNull);
    });
  });
}
