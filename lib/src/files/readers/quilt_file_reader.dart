/// Reader for individual files within a quilt blob.
///
/// Mirrors the TS SDK's `files/readers/quilt-file.ts`.
///
/// A [QuiltFileReader] lazily reads a single patch (file) from a quilt
/// using its [QuiltReader]. It implements [WalrusFileReader] so quilt
/// files are interchangeable with any other file source.
library;

import 'dart:typed_data';

import '../file.dart';
import 'quilt_reader.dart';

/// Reads a single file from within a quilt blob.
///
/// Wraps a [QuiltReader] and a specific sliver index. Bytes are read
/// lazily on first access. Identifier and tags are cached once resolved.
///
/// Mirrors the TS SDK's `QuiltFileReader` from `files/readers/quilt-file.ts`.
class QuiltFileReader implements WalrusFileReader {
  final QuiltReader _quilt;
  final int _sliverIndex;
  String? _identifier;
  Map<String, String>? _tags;

  QuiltFileReader({
    required QuiltReader quilt,
    required int sliverIndex,
    String? identifier,
    Map<String, String>? tags,
  }) : _quilt = quilt,
       _sliverIndex = sliverIndex,
       _identifier = identifier,
       _tags = tags;

  @override
  Future<Uint8List> getBytes() async {
    final result = await _quilt.readBlob(_sliverIndex);
    _identifier = result.identifier;
    _tags = result.tags ?? {};
    return result.blobContents;
  }

  @override
  Future<String?> getIdentifier() async {
    if (_identifier != null) {
      return _identifier;
    }

    final header = await _quilt.getBlobHeader(_sliverIndex);
    _identifier = header.identifier;
    return _identifier;
  }

  @override
  Future<Map<String, String>> getTags() async {
    if (_tags != null) {
      return _tags!;
    }

    final header = await _quilt.getBlobHeader(_sliverIndex);
    _tags = header.tags ?? {};
    return _tags!;
  }
}
