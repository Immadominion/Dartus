import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uint8List sha256Digest(String input) {
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return Uint8List.fromList(digest.bytes);
}

String sha256Hex(String input) => sha256Digest(
  input,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
