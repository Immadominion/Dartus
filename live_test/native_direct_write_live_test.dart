/// Opt-in TESTNET native RS2 → direct storage nodes → BLS certification.
/// No upload relay or publisher is used, including for the final byte read.
///
/// Required environment (keep the seed in the process environment):
/// DARTUS_LIVE_NETWORK=testnet
/// DARTUS_LIVE_ED25519_SEED=`<32-byte hex seed of funded testnet account>`
/// DARTUS_BLS_LIBRARY=`<absolute path to built bls_dart dynamic library>`
/// DARTUS_NATIVE_RECEIPT=`<persistent local JSON path outside the repository>`
/// WALRUS_FFI_LIB=`<optional explicit path to built walrus_ffi library>`
///
/// Preflight only (reads, encoding, transaction simulation; no signing):
/// DARTUS_NATIVE_DRY_RUN=true flutter test --no-pub
///   live_test/native_direct_write_live_test.dart --reporter expanded
///
/// Paid test (at most one registration and one certification):
/// DARTUS_RUN_LIVE_WRITES=true flutter test --no-pub
///   live_test/native_direct_write_live_test.dart --reporter expanded
///
/// Reuse the SAME receipt on every retry. Before submitting either transaction,
/// its locally computed digest is flushed to the receipt. A resumed test only
/// queries that digest; it never submits a second transaction for that phase.
/// An unresolved digest stops the test for manual inspection. Receipts contain
/// public transaction/blob IDs and test data, never seeds or signatures.
@TestOn('vm')
@Tags(['integration', 'live-write'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bls_dart/bls_dart.dart';
import 'package:dartus/direct.dart';
import 'package:dartus/src/chain/walrus_grpc_transaction.dart';
import 'package:dartus/src/chain/write_flow_verification.dart';
// RustLib.init exposes this bridge type in its public signature.
// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:sui/grpc/proto/sui/rpc/v2/effects.pb.dart' as pb;
import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/sui.dart';
import 'package:test/test.dart';

final _maxWal = BigInt.from(1000000); // 0.001 testnet WAL, storage + write.
final _maxGasPerTransaction = BigInt.from(50000000); // 0.05 testnet SUI.
const _epochs = 1;

void main() {
  test(
    'native testnet direct upload certifies and reads the exact bytes',
    () async {
      final env = Platform.environment;
      if (env['DARTUS_LIVE_NETWORK'] != 'testnet') {
        throw StateError('This harness requires DARTUS_LIVE_NETWORK=testnet');
      }
      final dryRun = env['DARTUS_NATIVE_DRY_RUN'] == 'true';
      if (!dryRun && env['DARTUS_RUN_LIVE_WRITES'] != 'true') {
        throw StateError(
          'Set DARTUS_NATIVE_DRY_RUN=true or DARTUS_RUN_LIVE_WRITES=true',
        );
      }
      final seed = env['DARTUS_LIVE_ED25519_SEED'];
      if (seed == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(seed)) {
        throw StateError(
          'DARTUS_LIVE_ED25519_SEED must contain a 32-byte hex seed',
        );
      }
      final library = env['DARTUS_BLS_LIBRARY'];
      if (library == null || !File(library).existsSync()) {
        throw StateError(
          'Set DARTUS_BLS_LIBRARY to an existing bls_dart library',
        );
      }
      final path = env['DARTUS_NATIVE_RECEIPT'];
      if (path == null || path.isEmpty) {
        throw StateError(
          'Set DARTUS_NATIVE_RECEIPT to a persistent local JSON path',
        );
      }
      final destination = File(path).absolute;
      await destination.parent.create(recursive: true);
      final directory = await destination.parent.resolveSymbolicLinks();
      final receiptFile = File(
        '$directory/${destination.uri.pathSegments.last}',
      );
      final repository =
          '${await Directory.current.resolveSymbolicLinks()}${Platform.pathSeparator}';
      if (receiptFile.path.startsWith(repository)) {
        throw StateError('Keep DARTUS_NATIVE_RECEIPT outside the repository');
      }
      final lock = await File(
        '${receiptFile.path}.lock',
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      addTearDown(() async {
        await lock.unlock();
        await lock.close();
      });

      final account = SuiAccount(
        Ed25519Keypair.fromSeed(
          Uint8List.fromList([
            for (var i = 0; i < seed.length; i += 2)
              int.parse(seed.substring(i, i + 2), radix: 16),
          ]),
        ),
      );
      final owner = account.getAddress();
      final receipt = receiptFile.existsSync()
          ? Map<String, dynamic>.from(
              jsonDecode(await receiptFile.readAsString()) as Map,
            )
          : <String, dynamic>{
              'version': 1,
              'network': 'testnet',
              'owner': owner,
              'createdAt': DateTime.now().toUtc().toIso8601String(),
              'epochs': _epochs,
            };
      if (receipt['version'] != 1 ||
          receipt['network'] != 'testnet' ||
          receipt['owner'] != owner ||
          receipt['epochs'] != _epochs) {
        throw StateError(
          'Receipt belongs to another account, network or test version',
        );
      }
      final data = Uint8List.fromList(
        utf8.encode(
          'Dartus native direct testnet smoke ${receipt['createdAt']}\n',
        ),
      );
      if (data.length > 128) {
        throw StateError('Smoke payload exceeded 128 bytes');
      }
      receipt['payloadBase64'] = base64Encode(data);
      Future<void> save() async {
        final temporary = File('${receiptFile.path}.tmp');
        await temporary.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
          flush: true,
        );
        await temporary.rename(receiptFile.path);
      }

      await save();

      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final grpc = SuiGrpcClient(network: SuiNetwork.testnet);
      final encoder = WalrusBlobEncoder();
      // Use the constructor: fromNetwork intentionally chooses a default relay.
      final client = WalrusDirectClient(
        network: WalrusNetwork.testnet,
        grpcClient: grpc,
        encoder: encoder,
        blsProvider: const BlsDartProvider(),
        logLevel: WalrusLogLevel.debug,
      );
      addTearDown(client.close);
      expect(client.uploadRelayConfig, isNull);
      final committee = await client.getCommittee();
      client.validateDirectWriteReadiness(committee: committee);
      final encoded = encoder.encodeBlob(data, committee.numShards);
      if (receipt['blobId'] != null && receipt['blobId'] != encoded.blobId) {
        throw StateError(
          'Receipt encoding differs; do not register another blob',
        );
      }
      receipt['blobId'] = encoded.blobId;
      receipt['numShards'] = committee.numShards;
      final blobType = await client.getBlobType();
      final costs = await client.storageCost(data.length, _epochs);
      if (costs.totalCost > _maxWal) {
        throw StateError(
          'Storage quote ${costs.totalCost} exceeds $_maxWal FROST cap',
        );
      }
      receipt['quotedWalFrost'] = costs.totalCost.toString();
      await save();
      print(
        'Native preflight: ${data.length} bytes, $_epochs epoch, '
        '${committee.numShards} shards/${committee.nodes.length} members, '
        '${costs.totalCost} FROST WAL; gas cap $_maxGasPerTransaction MIST per phase; '
        'receipt=${receiptFile.path}',
      );

      Future<Uint8List> prepare(Transaction transaction) async {
        final bytes = await prepareWalrusTransaction(
          grpc,
          transaction,
          sender: owner,
          gasBudget: _maxGasPerTransaction,
        );
        final budget = Transaction.fromBytes(bytes).getData().gasData.budget;
        if (budget == null ||
            budget <= BigInt.zero ||
            budget > _maxGasPerTransaction) {
          throw StateError(
            'Prepared gas budget exceeds the per-transaction cap',
          );
        }
        return bytes;
      }

      Future<pb.ExecutedTransaction> executeOnce(
        String phase,
        Uint8List? bytes,
      ) async {
        final previous = receipt[phase];
        late final String digest;
        late pb.ExecutedTransaction executed;
        if (previous != null) {
          digest = (previous as Map)['digest'] as String;
          print(
            'Resuming $phase by querying saved digest $digest; no new submission',
          );
          executed = await grpc.waitForTransaction(
            digest,
            timeout: const Duration(seconds: 60),
            readMask: const ['digest', 'effects'],
          );
        } else {
          if (dryRun) throw StateError('Dry run cannot submit transactions');
          if (bytes == null) {
            throw StateError('Missing prepared $phase transaction');
          }
          digest = TransactionBlockDataBuilder.getDigestFromBytes(bytes);
          final gasBudget = Transaction.fromBytes(
            bytes,
          ).getData().gasData.budget!;
          receipt[phase] = <String, dynamic>{
            'digest': digest,
            'status': 'submission_pending',
            'gasBudgetMist': gasBudget.toString(),
            'checkpointedAt': DateTime.now().toUtc().toIso8601String(),
          };
          // Flush before signing/submission. An ambiguous result cannot trigger
          // a fresh payment on a later run.
          await save();
          print(
            'Submitting $phase digest $digest with gas budget $gasBudget MIST',
          );
          final signed = account.keyPair.signTransactionBlock(bytes);
          executed = await grpc.executeTransaction(
            bytes,
            [Uint8List.fromList(base64Decode(signed.signature))],
            readMask: const ['digest', 'effects'],
          );
        }
        if (executed.digest != digest ||
            !executed.hasEffects() ||
            !executed.effects.hasStatus() ||
            !executed.effects.status.hasSuccess()) {
          throw StateError(
            '$phase outcome is unconfirmed. Inspect saved digest $digest; do not replace the receipt',
          );
        }
        final record = receipt[phase] as Map<String, dynamic>;
        record['status'] = executed.effects.status.success
            ? 'success'
            : 'failed';
        final gas = executed.effects.gasUsed;
        record['gasUsed'] = {
          'computationCost': gas.computationCost.toString(),
          'storageCost': gas.storageCost.toString(),
          'storageRebate': gas.storageRebate.toString(),
        };
        await save();
        if (!executed.effects.status.success) {
          throw StateError(
            '$phase failed on chain ($digest): ${executed.effects.status.error.description}',
          );
        }
        return executed;
      }

      Uint8List? registerBytes;
      if (receipt['register'] == null) {
        final walCoin = await client.findWalCoin(owner, costs.totalCost);
        if (walCoin == null) {
          throw StateError('No testnet WAL coin covers the storage quote');
        }
        final transaction = await client.registerBlobTransaction(
          RegisterBlobOptions(
            size: data.length,
            epochs: _epochs,
            blobId: encoded.blobId,
            rootHash: encoded.rootHash,
            deletable: true,
            owner: owner,
          ),
          walCoinObjectId: walCoin,
          storageCost: costs.storageCost,
          writeCost: costs.writeCost,
        );
        registerBytes = await prepare(transaction);
        print(
          'Registration prepared without signing; gas budget '
          '${Transaction.fromBytes(registerBytes).getData().gasData.budget} MIST',
        );
      }
      if (dryRun) {
        print(
          'Preflight complete. No transaction signed/submitted and no node upload performed.',
        );
        return;
      }

      final registered = await executeOnce('register', registerBytes);
      final created = registered.effects.changedObjects
          .where(
            (change) =>
                change.idOperation == pb.ChangedObject_IdOperation.CREATED &&
                change.objectType == blobType,
          )
          .toList();
      if (created.length != 1) {
        throw StateError(
          'Expected exactly one created Walrus Blob in registration effects',
        );
      }
      final objectId = created.single.objectId;
      if (receipt['blobObjectId'] != null &&
          receipt['blobObjectId'] != objectId) {
        throw StateError('Registration receipt and object ID disagree');
      }
      receipt['blobObjectId'] = objectId;
      await save();
      await verifyFlowBlob(
        client: client.suiClient,
        objectId: objectId,
        blobId: encoded.blobId,
        blobType: blobType,
        size: data.length,
        deletable: true,
        owner: owner,
        certified: false,
        digest: (receipt['register'] as Map)['digest'] as String,
      );

      Uint8List? certifyBytes;
      if (receipt['certify'] == null) {
        print('Uploading encoded metadata/slivers directly to storage nodes');
        final confirmations = await client.writeEncodedBlobToNodes(
          encodedBlob: encoded,
          committee: committee,
          deletable: true,
          blobObjectId: objectId,
          maxConcurrency: 20,
        );
        final certificate = client.buildCertificateFromConfirmations(
          confirmations: confirmations,
          committee: committee,
          blobId: encoded.blobId,
          blobObjectId: objectId,
          deletable: true,
        );
        receipt['confirmedMembers'] = certificate.signers.length;
        receipt['confirmedShards'] = certificate.signers.fold<int>(
          0,
          (sum, index) => sum + committee.nodes[index].shardIndices.length,
        );
        receipt['certificateEpoch'] = committee.epoch;
        await save();
        final transaction = await client.certifyBlobTransaction(
          CertifyBlobOptions(
            blobId: encoded.blobId,
            blobObjectId: objectId,
            deletable: true,
            certificate: certificate,
            committeeSize: committee.nodes.length,
          ),
        );
        certifyBytes = await prepare(transaction);
      }
      await executeOnce('certify', certifyBytes);
      await verifyFlowBlob(
        client: client.suiClient,
        objectId: objectId,
        blobId: encoded.blobId,
        blobType: blobType,
        size: data.length,
        deletable: true,
        owner: owner,
        certified: true,
        digest: (receipt['certify'] as Map)['digest'] as String,
      );
      print(
        'Certified on chain; reading and decoding primary slivers directly',
      );
      final bytes = await client.readBlob(blobId: encoded.blobId);
      expect(bytes, orderedEquals(data));
      receipt['exactReadVerified'] = true;
      receipt['completedAt'] = DateTime.now().toUtc().toIso8601String();
      await save();
      print(
        'Native direct round trip verified: blob=${encoded.blobId}, '
        'object=$objectId, register=${(receipt['register'] as Map)['digest']}, '
        'certify=${(receipt['certify'] as Map)['digest']}, bytes=${bytes.length}',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
