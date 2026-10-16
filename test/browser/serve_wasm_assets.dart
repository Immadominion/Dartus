// Hybrid VM helper for the browser tests: serves assets/walrus_wasm/ on a
// loopback port with CORS, and sends the base URL back to the browser.
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final root = Directory('assets/walrus_wasm').absolute;
  server.listen((request) async {
    final response = request.response
      ..headers.set('Access-Control-Allow-Origin', '*');
    final segments = request.uri.pathSegments;
    final name = segments.length == 1 ? segments.single : '';
    final file = File('${root.path}/$name');
    if (name.isEmpty || !await file.exists()) {
      response.statusCode = HttpStatus.notFound;
    } else {
      response.headers.contentType = name.endsWith('.wasm')
          ? ContentType('application', 'wasm')
          : ContentType('text', 'javascript', charset: 'utf-8');
      await response.addStream(file.openRead());
    }
    await response.close();
  });
  channel.sink.add('http://127.0.0.1:${server.port}/');
  await channel.stream.drain<void>();
  await server.close(force: true);
}
