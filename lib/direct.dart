/// Native-only entry point for Dartus **direct mode**.
///
/// Re-exports everything in `package:dartus/dartus.dart` **plus** the
/// client-side encoding and direct storage-node surface that depends on the
/// Rust FFI native library (`dart:ffi`). Because `dart:ffi` is not available
/// on the web, import this entry point only from native targets
/// (mobile / desktop / CLI):
///
/// ```dart
/// import 'package:dartus/direct.dart';
///
/// final client = WalrusDirectClient.fromNetwork(
///   network: WalrusNetwork.testnet,
/// );
/// ```
///
/// Web and pure-HTTP apps should import `package:dartus/dartus.dart`, which
/// stays free of `dart:ffi`.
library;

export 'dartus.dart';

// Direct mode + Rust FFI (native-only — these pull in dart:ffi)
export 'src/client/walrus_direct_client.dart';
export 'src/client/write_blob_flow.dart';
export 'src/client/write_files_flow.dart';
export 'src/encoding/walrus_blob_encoder.dart';
export 'src/encoding/walrus_ffi_bindings.dart';
