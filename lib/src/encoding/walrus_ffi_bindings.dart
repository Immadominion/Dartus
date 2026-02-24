// ignore_for_file: avoid_positional_boolean_parameters
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Dart FFI bindings for the walrus_ffi native library.
///
/// Provides canonical Walrus RS2 blob encoding and metadata computation
/// that is bit-identical to walrus-core / walrus-wasm.
///
/// ## Library Discovery
///
/// The native library is searched in this order:
/// 1. Path set via [configure] (call before first use)
/// 2. `WALRUS_FFI_LIB` environment variable
/// 3. Relative to the `dartus` package source directory (auto-resolved)
/// 4. Relative to the current working directory
/// 5. System library paths (`/usr/local/lib/`)
///
/// For Flutter apps, call [configure] early (e.g. in `main()`) with the
/// correct path to `libwalrus_ffi.dylib`.
class WalrusFfiBindings {
  WalrusFfiBindings._();

  static WalrusFfiBindings? _instance;
  static String? _configuredPath;
  static String? _resolvedPath;
  late final DynamicLibrary _lib;

  // C function signatures
  late final int Function(
    int nShards,
    Pointer<Uint8> dataPtr,
    int dataLen,
    Pointer<Uint8> outBlobId,
    Pointer<Uint8> outRootHash,
    Pointer<Uint64> outUnencodedLength,
    Pointer<Uint8> outEncodingType,
  )
  _computeMetadata;

  late final int Function(
    int nShards,
    int blobLen,
    Pointer<Uint32> outPrimarySymbols,
    Pointer<Uint32> outSecondarySymbols,
    Pointer<Uint32> outSymbolSize,
    Pointer<Uint64> outPrimarySliverSize,
    Pointer<Uint64> outSecondarySliverSize,
  )
  _encodingParams;

  late final int Function(
    int nShards,
    Pointer<Uint8> dataPtr,
    int dataLen,
    Pointer<Uint8> outPrimarySlivers,
    Pointer<Uint8> outSecondarySlivers,
    Pointer<Uint8> outBlobId,
    Pointer<Uint8> outRootHash,
    Pointer<Uint64> outUnencodedLength,
    Pointer<Uint8> outEncodingType,
  )
  _encodeBlob;

  late final int Function(
    int nShards,
    int blobSize,
    Pointer<Uint8> sliverDataPtr,
    Pointer<Uint16> sliverIndicesPtr,
    int sliverCount,
    int sliverSize,
    Pointer<Uint8> outBlobPtr,
    Pointer<Uint64> outBlobLen,
  )
  _decodeBlob;

  /// Get or create the singleton instance.
  ///
  /// [libraryPath] overrides the default platform-specific library path.
  /// If not provided, searches for the library in standard locations.
  /// Prefer [configure] for setting the path before first use.
  static WalrusFfiBindings instance({String? libraryPath}) {
    if (_instance != null) return _instance!;
    final inst = WalrusFfiBindings._();
    try {
      inst._load(libraryPath ?? _configuredPath);
    } catch (e) {
      // Don't leave a half-initialized singleton — the next call to
      // instance() or isAvailable must retry, not return a broken object.
      _instance = null;
      rethrow;
    }
    _instance = inst;
    return _instance!;
  }

  /// Pre-configure the native library path before first use.
  ///
  /// Call this early (e.g. in `main()`) to ensure the native library
  /// is found. This is especially important for Flutter apps where the
  /// working directory may not be the package root.
  ///
  /// ```dart
  /// void main() {
  ///   WalrusFfiBindings.configure('/path/to/libwalrus_ffi.dylib');
  ///   runApp(MyApp());
  /// }
  /// ```
  static void configure(String path) {
    if (_instance != null) {
      throw StateError(
        'WalrusFfiBindings already initialized. '
        'Call configure() before any encoder usage.',
      );
    }
    _configuredPath = path;
  }

  /// Whether the native library has been loaded successfully.
  static bool get isAvailable {
    try {
      instance();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The file path of the loaded native library, or `null` if not loaded.
  ///
  /// Useful for propagating the library path to spawned isolates where
  /// static configuration is not inherited.
  static String? get resolvedPath => _resolvedPath;

  /// Reset the singleton — useful for testing with different library paths.
  static void reset() {
    _instance = null;
    _configuredPath = null;
    _resolvedPath = null;
  }

  void _load(String? libraryPath) {
    final path = libraryPath ?? _defaultLibraryPath();
    _lib = DynamicLibrary.open(path);
    _resolvedPath = path;

    _computeMetadata = _lib
        .lookup<
          NativeFunction<
            Int32 Function(
              Uint16,
              Pointer<Uint8>,
              IntPtr,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint64>,
              Pointer<Uint8>,
            )
          >
        >('walrus_compute_metadata')
        .asFunction();

    _encodingParams = _lib
        .lookup<
          NativeFunction<
            Int32 Function(
              Uint16,
              Uint64,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Uint64>,
              Pointer<Uint64>,
            )
          >
        >('walrus_encoding_params')
        .asFunction();

    _encodeBlob = _lib
        .lookup<
          NativeFunction<
            Int32 Function(
              Uint16,
              Pointer<Uint8>,
              IntPtr,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint64>,
              Pointer<Uint8>,
            )
          >
        >('walrus_encode_blob')
        .asFunction();

    _decodeBlob = _lib
        .lookup<
          NativeFunction<
            Int32 Function(
              Uint16,
              Uint64,
              Pointer<Uint8>,
              Pointer<Uint16>,
              Uint32,
              Uint64,
              Pointer<Uint8>,
              Pointer<Uint64>,
            )
          >
        >('walrus_decode_blob')
        .asFunction();
  }

  static String _defaultLibraryPath() {
    // Search order: env var → app bundle → package-relative → CWD-relative → system paths
    final envPath = Platform.environment['WALRUS_FFI_LIB'];
    if (envPath != null && File(envPath).existsSync()) return envPath;

    final libName = _platformLibName();
    final candidates = <String>[];

    // 0. macOS / iOS app bundle — essential for sandboxed Flutter apps.
    //    The executable lives at App.app/Contents/MacOS/App; dylibs go in
    //    App.app/Contents/Frameworks/.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final execDir = File(Platform.resolvedExecutable).parent.path;
        // Contents/MacOS → Contents/Frameworks
        final frameworksDir = '${Directory(execDir).parent.path}/Frameworks';
        candidates.add('$frameworksDir/$libName');
        // Also check directly next to the executable
        candidates.add('$execDir/$libName');
      } catch (_) {}
    }

    // 1. Resolve relative to the dartus package source directory.
    //    This works when dartus is a path dependency (typical for mono-repo).
    final packageRoot = _resolvePackageRoot();
    if (packageRoot != null) {
      candidates.add('$packageRoot/native/walrus_ffi/target/release/$libName');
      candidates.add('$packageRoot/native/walrus_ffi/target/debug/$libName');
    }

    // 2. Relative to CWD (works for `cd Dartus && dart test`)
    candidates.addAll([
      'native/walrus_ffi/target/release/$libName',
      'native/walrus_ffi/target/debug/$libName',
    ]);

    // 3. Relative to parent (works for sibling-directory layouts)
    candidates.addAll([
      '../Dartus/native/walrus_ffi/target/release/$libName',
      '../native/walrus_ffi/target/release/$libName',
    ]);

    // 4. Absolute from CWD
    final cwd = Directory.current.path;
    candidates.add('$cwd/native/walrus_ffi/target/release/$libName');

    // 5. System paths
    candidates.addAll(['/usr/local/lib/$libName', '/usr/lib/$libName']);

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }

    // Fall back — DynamicLibrary.open will search system paths
    return libName;
  }

  /// Resolve the dartus package root directory from the package config.
  ///
  /// Uses `Isolate.resolvePackageUri` synchronously by pre-resolving,
  /// or falls back to heuristic path detection.
  static String? _resolvePackageRoot() {
    try {
      // Heuristic: walk up from CWD looking for the dartus pubspec
      var dir = Directory.current;
      for (var i = 0; i < 6; i++) {
        final pubspec = File('${dir.path}/pubspec.yaml');
        if (pubspec.existsSync()) {
          final content = pubspec.readAsStringSync();
          if (content.contains('name: dartus')) {
            return dir.path;
          }
        }
        // Check if dartus is a subdirectory
        final dartusDir = Directory('${dir.path}/Dartus');
        if (dartusDir.existsSync()) {
          final dartusPubspec = File('${dartusDir.path}/pubspec.yaml');
          if (dartusPubspec.existsSync()) {
            return dartusDir.path;
          }
        }
        dir = dir.parent;
      }

      // Also check .dart_tool/package_config.json for path-dependency resolution
      final packageConfigCandidates = [
        '${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/../.dart_tool/package_config.json',
      ];
      for (final configPath in packageConfigCandidates) {
        final configFile = File(configPath);
        if (!configFile.existsSync()) continue;
        final content = configFile.readAsStringSync();
        // Look for dartus package entry with a file:// rootUri
        final dartusMatch = RegExp(
          r'"name"\s*:\s*"dartus"[^}]*"rootUri"\s*:\s*"([^"]+)"',
        ).firstMatch(content);
        if (dartusMatch != null) {
          var rootUri = dartusMatch.group(1)!;
          // rootUri is relative to .dart_tool/ directory
          if (!rootUri.startsWith('/') && !rootUri.startsWith('file:')) {
            final configDir = File(configPath).parent.path;
            rootUri = '$configDir/$rootUri';
          } else if (rootUri.startsWith('file://')) {
            rootUri = Uri.parse(rootUri).toFilePath();
          }
          final resolved = Directory(rootUri);
          if (resolved.existsSync()) {
            return resolved.resolveSymbolicLinksSync();
          }
        }
      }
    } catch (_) {
      // Ignore — we'll fall through to other search paths
    }
    return null;
  }

  static String _platformLibName() {
    if (Platform.isMacOS) return 'libwalrus_ffi.dylib';
    if (Platform.isLinux) return 'libwalrus_ffi.so';
    if (Platform.isWindows) return 'walrus_ffi.dll';
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Compute blob metadata (blob ID, root hash) without returning slivers.
  ///
  /// Used for the upload-relay path where the relay handles actual encoding.
  /// Returns a [WalrusBlobMetadata] with all fields needed for on-chain
  /// registration.
  WalrusBlobMetadata computeMetadata(int nShards, Uint8List data) {
    final dataPtr = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    final outBlobId = calloc<Uint8>(32);
    final outRootHash = calloc<Uint8>(32);
    final outUnencodedLength = calloc<Uint64>(1);
    final outEncodingType = calloc<Uint8>(1);

    try {
      if (data.isNotEmpty) {
        dataPtr.asTypedList(data.length).setAll(0, data);
      }

      final ret = _computeMetadata(
        nShards,
        data.isEmpty ? nullptr : dataPtr,
        data.length,
        outBlobId,
        outRootHash,
        outUnencodedLength,
        outEncodingType,
      );

      if (ret != 0) {
        throw WalrusFfiException(
          'walrus_compute_metadata failed with code $ret',
        );
      }

      return WalrusBlobMetadata(
        blobId: Uint8List.fromList(outBlobId.asTypedList(32)),
        rootHash: Uint8List.fromList(outRootHash.asTypedList(32)),
        unencodedLength: outUnencodedLength.value,
        encodingType: outEncodingType.value,
      );
    } finally {
      calloc.free(dataPtr);
      calloc.free(outBlobId);
      calloc.free(outRootHash);
      calloc.free(outUnencodedLength);
      calloc.free(outEncodingType);
    }
  }

  /// Get encoding parameters for a given shard count and blob size.
  WalrusEncodingParams encodingParams(int nShards, int blobLen) {
    final outP = calloc<Uint32>(1);
    final outS = calloc<Uint32>(1);
    final outSS = calloc<Uint32>(1);
    final outPriSize = calloc<Uint64>(1);
    final outSecSize = calloc<Uint64>(1);

    try {
      final ret = _encodingParams(
        nShards,
        blobLen,
        outP,
        outS,
        outSS,
        outPriSize,
        outSecSize,
      );

      if (ret != 0) {
        throw WalrusFfiException(
          'walrus_encoding_params failed with code $ret',
        );
      }

      return WalrusEncodingParams(
        primarySymbols: outP.value,
        secondarySymbols: outS.value,
        symbolSize: outSS.value,
        primarySliverSize: outPriSize.value,
        secondarySliverSize: outSecSize.value,
      );
    } finally {
      calloc.free(outP);
      calloc.free(outS);
      calloc.free(outSS);
      calloc.free(outPriSize);
      calloc.free(outSecSize);
    }
  }

  /// Full encode: compute metadata AND all primary + secondary slivers.
  ///
  /// Used for direct-mode blob storage where slivers must be distributed
  /// to storage nodes by the client.
  ///
  /// Returns a [WalrusFfiEncodedBlob] containing metadata and all slivers.
  WalrusFfiEncodedBlob encodeBlob(int nShards, Uint8List data) {
    // First get encoding params to know buffer sizes.
    final params = encodingParams(nShards, data.length);
    final priSliverSize = params.primarySliverSize;
    final secSliverSize = params.secondarySliverSize;
    final totalPriBytes = nShards * priSliverSize;
    final totalSecBytes = nShards * secSliverSize;

    // Allocate input + output buffers.
    final dataPtr = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    final outPriSlivers = calloc<Uint8>(totalPriBytes == 0 ? 1 : totalPriBytes);
    final outSecSlivers = calloc<Uint8>(totalSecBytes == 0 ? 1 : totalSecBytes);
    final outBlobId = calloc<Uint8>(32);
    final outRootHash = calloc<Uint8>(32);
    final outUnencodedLength = calloc<Uint64>(1);
    final outEncodingType = calloc<Uint8>(1);

    try {
      if (data.isNotEmpty) {
        dataPtr.asTypedList(data.length).setAll(0, data);
      }

      final ret = _encodeBlob(
        nShards,
        data.isEmpty ? nullptr : dataPtr,
        data.length,
        outPriSlivers,
        outSecSlivers,
        outBlobId,
        outRootHash,
        outUnencodedLength,
        outEncodingType,
      );

      if (ret != 0) {
        throw WalrusFfiException('walrus_encode_blob failed with code $ret');
      }

      // Extract primary slivers.
      final primarySlivers = <Uint8List>[];
      for (var i = 0; i < nShards; i++) {
        final offset = i * priSliverSize;
        primarySlivers.add(
          Uint8List.fromList(
            outPriSlivers
                .asTypedList(totalPriBytes)
                .sublist(offset, offset + priSliverSize),
          ),
        );
      }

      // Extract secondary slivers.
      final secondarySlivers = <Uint8List>[];
      for (var i = 0; i < nShards; i++) {
        final offset = i * secSliverSize;
        secondarySlivers.add(
          Uint8List.fromList(
            outSecSlivers
                .asTypedList(totalSecBytes)
                .sublist(offset, offset + secSliverSize),
          ),
        );
      }

      return WalrusFfiEncodedBlob(
        metadata: WalrusBlobMetadata(
          blobId: Uint8List.fromList(outBlobId.asTypedList(32)),
          rootHash: Uint8List.fromList(outRootHash.asTypedList(32)),
          unencodedLength: outUnencodedLength.value,
          encodingType: outEncodingType.value,
        ),
        primarySlivers: primarySlivers,
        secondarySlivers: secondarySlivers,
        symbolSize: params.symbolSize,
      );
    } finally {
      calloc.free(dataPtr);
      calloc.free(outPriSlivers);
      calloc.free(outSecSlivers);
      calloc.free(outBlobId);
      calloc.free(outRootHash);
      calloc.free(outUnencodedLength);
      calloc.free(outEncodingType);
    }
  }

  /// Decode (reconstruct) a blob from primary slivers via Rust FFI.
  ///
  /// Uses `walrus-core`'s RS2 decoder — the same decoder used by the
  /// Walrus network for canonical reconstruction. This is dramatically
  /// faster than any pure-Dart erasure coding implementation.
  ///
  /// [nShards]: number of shards in the committee.
  /// [blobSize]: the original unencoded blob length in bytes.
  /// [slivers]: list of `(index, data)` pairs — the shard index and raw
  ///   primary sliver bytes for each available sliver. Minimum required
  ///   is `primarySymbols` (from [encodingParams]).
  ///
  /// Returns the reconstructed original blob data.
  Uint8List decodeBlob({
    required int nShards,
    required int blobSize,
    required List<({int index, Uint8List data})> slivers,
  }) {
    if (slivers.isEmpty) {
      throw WalrusFfiException('decodeBlob: no slivers provided');
    }

    final sliverSize = slivers.first.data.length;
    final sliverCount = slivers.length;

    // Allocate flat buffers for all sliver data + indices.
    final totalSliverBytes = sliverCount * sliverSize;
    final sliverDataPtr = calloc<Uint8>(
      totalSliverBytes == 0 ? 1 : totalSliverBytes,
    );
    final sliverIndicesPtr = calloc<Uint16>(sliverCount);
    final outBlobPtr = calloc<Uint8>(blobSize == 0 ? 1 : blobSize);
    final outBlobLen = calloc<Uint64>(1);

    try {
      // Copy sliver data into the flat buffer.
      final flatView = sliverDataPtr.asTypedList(totalSliverBytes);
      final indicesView = sliverIndicesPtr.asTypedList(sliverCount);
      for (var i = 0; i < sliverCount; i++) {
        flatView.setRange(
          i * sliverSize,
          (i + 1) * sliverSize,
          slivers[i].data,
        );
        indicesView[i] = slivers[i].index;
      }

      final ret = _decodeBlob(
        nShards,
        blobSize,
        sliverDataPtr,
        sliverIndicesPtr,
        sliverCount,
        sliverSize,
        outBlobPtr,
        outBlobLen,
      );

      if (ret != 0) {
        throw WalrusFfiException(
          'walrus_decode_blob failed with code $ret '
          '(slivers=$sliverCount, sliverSize=$sliverSize, blobSize=$blobSize)',
        );
      }

      final decodedLen = outBlobLen.value;
      return Uint8List.fromList(outBlobPtr.asTypedList(decodedLen));
    } finally {
      calloc.free(sliverDataPtr);
      calloc.free(sliverIndicesPtr);
      calloc.free(outBlobPtr);
      calloc.free(outBlobLen);
    }
  }
}

// ---------------------------------------------------------------------------
// Result Types
// ---------------------------------------------------------------------------

/// Metadata returned by [WalrusFfiBindings.computeMetadata].
class WalrusBlobMetadata {
  WalrusBlobMetadata({
    required this.blobId,
    required this.rootHash,
    required this.unencodedLength,
    required this.encodingType,
  });

  /// 32-byte blob ID (Blake2b-256).
  final Uint8List blobId;

  /// 32-byte Merkle root hash.
  final Uint8List rootHash;

  /// Original unencoded blob size in bytes.
  final int unencodedLength;

  /// Encoding type (1 = RS2).
  final int encodingType;
}

/// Full encoding result from [WalrusFfiBindings.encodeBlob].
class WalrusFfiEncodedBlob {
  WalrusFfiEncodedBlob({
    required this.metadata,
    required this.primarySlivers,
    required this.secondarySlivers,
    required this.symbolSize,
  });

  /// Blob metadata (blob ID, root hash, etc.).
  final WalrusBlobMetadata metadata;

  /// Primary slivers, one per shard (indexed 0..nShards-1).
  final List<Uint8List> primarySlivers;

  /// Secondary slivers, one per shard (indexed 0..nShards-1).
  final List<Uint8List> secondarySlivers;

  /// Symbol size in bytes.
  final int symbolSize;
}

/// Encoding parameters returned by [WalrusFfiBindings.encodingParams].
class WalrusEncodingParams {
  WalrusEncodingParams({
    required this.primarySymbols,
    required this.secondarySymbols,
    required this.symbolSize,
    required this.primarySliverSize,
    required this.secondarySliverSize,
  });

  final int primarySymbols;
  final int secondarySymbols;
  final int symbolSize;
  final int primarySliverSize;
  final int secondarySliverSize;
}

/// Exception thrown when a walrus_ffi function call fails.
class WalrusFfiException implements Exception {
  WalrusFfiException(this.message);
  final String message;

  @override
  String toString() => 'WalrusFfiException: $message';
}
