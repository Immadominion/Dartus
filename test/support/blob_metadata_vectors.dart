import 'dart:convert';
import 'dart:typed_data';

/// Blob metadata produced by Mysten's `@mysten/walrus-wasm` 0.3.1
/// (`BlobEncoder(1000).compute_metadata`), the encoder the TS SDK uses.
/// Every Dartus encoder must reproduce these exactly.
class BlobMetadataVector {
  const BlobMetadataVector(this.name, this.blobId, this.rootHashHex, this.data);

  final String name;
  final String blobId;
  final String rootHashHex;
  final Uint8List Function() data;
}

const blobMetadataShards = 1000;

final blobMetadataVectors = [
  BlobMetadataVector(
    'empty',
    '3GPQL3HZNnFhN_F7l5Aa-X1VOtAKwIsg9zuWk8R81v4',
    'e3fb10a9d88c9e7157c5e112dd6916e44011f5a9d6460bced51ebacf9308e1da',
    () => Uint8List(0),
  ),
  BlobMetadataVector(
    'short text',
    'kIrHJ_1VfYJD-OV0O1JicM2lB5swr83ZkfvTD7BWV0I',
    'e9f5feb3289dd18904088ddac61027178b139dc05cd7a185a8dbd51b3fa0380f',
    () => Uint8List.fromList(utf8.encode('hello walrus')),
  ),
  BlobMetadataVector(
    '64 KiB pattern',
    'w_DSRdoKtTB9xaAdsDKQ4TDDPrnwNuIYlyGzQDM0zS4',
    '1ecbeef59b148a4f095e92b581e272b978110037eec0181efd75835c88d415e6',
    () => Uint8List.fromList(
      List<int>.generate(65536, (i) => (i * 31 + 7) & 0xff),
    ),
  ),
];

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
