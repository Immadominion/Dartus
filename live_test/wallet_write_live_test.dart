/// Explicit opt-in only: spends real WAL and SUI from the key you provide.
///
/// ```sh
/// DARTUS_RUN_LIVE_WRITES=true \
/// DARTUS_LIVE_NETWORK=testnet \
/// DARTUS_LIVE_ED25519_SEED=<32-byte hex seed of a funded throwaway key> \
/// flutter test live_test/wallet_write_live_test.dart
/// ```
@TestOn('vm')
@Tags(['integration', 'live-write'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;
import 'package:sui/sui.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a keypair pays for, registers, uploads and certifies a blob it owns',
    () async {
      final env = Platform.environment;
      expect(
        env['DARTUS_RUN_LIVE_WRITES'],
        'true',
        reason: 'Set DARTUS_RUN_LIVE_WRITES=true to authorize a paid write',
      );
      final seed = env['DARTUS_LIVE_ED25519_SEED'];
      expect(seed, isNotNull, reason: 'Set DARTUS_LIVE_ED25519_SEED');
      final network = WalrusNetwork.values.byName(
        env['DARTUS_LIVE_NETWORK'] ?? 'testnet',
      );

      final writer = WalrusWriter(network: network);
      addTearDown(writer.close);
      final account = SuiAccount(
        Ed25519Keypair.fromSeed(Uint8List.fromList(_hex(seed!))),
      );
      final signer = KeypairTransactionSigner(account, writer.chain.sui);

      final bytes = Uint8List.fromList(
        utf8.encode('Dartus wallet write ${DateTime.now().toIso8601String()}'),
      );
      final estimate = await writer.estimate(size: bytes.length, epochs: 1);
      final before = await writer.balances(signer.address);
      final stages = <WalrusWriteStage>[];

      final result = await writer.write(
        bytes,
        signer: signer,
        epochs: 1,
        onStage: stages.add,
      );

      expect(stages, WalrusWriteStage.values);
      expect(result.blob.owner, signer.address);
      expect(result.blob.isCertified, isTrue);
      expect(result.blob.deletable, isTrue);
      expect(result.blob.size, bytes.length);
      expect(result.endEpoch, estimate.endEpoch);

      final after = await writer.balances(signer.address);
      expect(before.wal - after.wal, estimate.cost.total);

      // Any aggregator serves the bytes back.
      final aggregator = switch (network) {
        WalrusNetwork.testnet =>
          'https://aggregator.walrus-testnet.walrus.space',
        WalrusNetwork.mainnet =>
          'https://aggregator.walrus-mainnet.walrus.space',
      };
      final read = await http.get(
        Uri.parse('$aggregator/v1/blobs/${result.blobId}'),
      );
      expect(read.statusCode, 200);
      expect(read.bodyBytes, bytes);

      print(
        'Stored ${result.blobId} as ${result.blobObjectId} '
        '(register ${result.registerDigest}, certify ${result.certifyDigest}); '
        'paid ${estimate.cost.total} FROST + ${result.relayTip} MIST tip',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

List<int> _hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];
