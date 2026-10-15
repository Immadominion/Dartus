@TestOn('vm')
@Tags(['unit'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('default test runner blocks external HTTP connections', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await expectLater(
      client.getUrl(Uri.parse('https://external.invalid/should-not-connect')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('External network disabled in test/'),
        ),
      ),
    );
  });
}
