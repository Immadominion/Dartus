/// File abstraction for Walrus blobs, mirroring the TS SDK's `files/file.ts`.
///
/// [WalrusFile] wraps a [FileReader] that provides access to the file's
/// contents, identifier, and tags. This enables uniform handling of
/// both local blobs and quilt-derived file slices.
///
/// Example:
/// ```dart
/// final file = WalrusFile.from(
///   contents: utf8.encode('Hello, Walrus!'),
///   identifier: 'hello.txt',
///   tags: {'type': 'text'},
/// );
///
/// final bytes = await file.bytes();
/// final text = await file.text();
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

/// Interface for reading file data from various sources.
///
/// Mirrors the TS SDK's `FileReader` interface from `files/file.ts`.
/// Implementers provide access to file contents, identifier, and tags.
abstract class WalrusFileReader {
  /// Returns the file's identifier (e.g. filename), or `null` if unknown.
  Future<String?> getIdentifier();

  /// Returns the file's tags (key-value metadata), or empty map.
  Future<Map<String, String>> getTags();

  /// Returns the raw bytes of the file.
  Future<Uint8List> getBytes();
}

/// A local file reader backed by in-memory data.
///
/// Mirrors the TS SDK's `readers/local.ts`.
class LocalFileReader implements WalrusFileReader {
  final Uint8List _contents;
  final String _identifier;
  final Map<String, String> _tags;

  LocalFileReader({
    required Uint8List contents,
    required String identifier,
    Map<String, String>? tags,
  }) : _contents = contents,
       _identifier = identifier,
       _tags = tags ?? const {};

  @override
  Future<String?> getIdentifier() async => _identifier;

  @override
  Future<Map<String, String>> getTags() async => Map.unmodifiable(_tags);

  @override
  Future<Uint8List> getBytes() async => _contents;
}

/// Walrus file abstraction.
///
/// Mirrors the TS SDK's `WalrusFile` class from `files/file.ts`.
/// Wraps a [WalrusFileReader] to provide uniform access to file
/// contents regardless of the underlying data source.
class WalrusFile {
  final WalrusFileReader _reader;

  /// Create a [WalrusFile] from in-memory data.
  ///
  /// Convenience factory mirroring `WalrusFile.from()` in the TS SDK.
  factory WalrusFile.from({
    required Uint8List contents,
    required String identifier,
    Map<String, String>? tags,
  }) {
    return WalrusFile(
      reader: LocalFileReader(
        contents: contents,
        identifier: identifier,
        tags: tags,
      ),
    );
  }

  /// Create a [WalrusFile] from a custom reader.
  WalrusFile({required WalrusFileReader reader}) : _reader = reader;

  /// Returns the file's identifier (e.g. filename), or `null`.
  Future<String?> getIdentifier() => _reader.getIdentifier();

  /// Returns the file's tags.
  Future<Map<String, String>> getTags() => _reader.getTags();

  /// Returns the raw bytes of the file.
  Future<Uint8List> bytes() => _reader.getBytes();

  /// Returns the file contents decoded as UTF-8 text.
  Future<String> text() async {
    final data = await bytes();
    return utf8.decode(data);
  }

  /// Returns the file contents parsed as JSON.
  Future<dynamic> json() async {
    return jsonDecode(await text());
  }
}
