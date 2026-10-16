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
    if (segments.length == 2 && segments.first == 'silent') {
      // A script that loads but never reports ready.
      response.headers
        ..contentType = ContentType('text', 'javascript', charset: 'utf-8')
        ..set('Access-Control-Allow-Origin', '*');
      response.write('// does nothing');
      await response.close();
      return;
    }
    if (segments.isNotEmpty && segments.first == 'spa') {
      // A single-page-app server answering every unknown path with its page.
      response.headers.contentType = ContentType.html;
      response.write('<!doctype html><title>App</title>');
      await response.close();
      return;
    }
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
