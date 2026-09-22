// Runs against the real native resolver of the device / desktop.
//
//   flutter test integration_test -d macos
//
// Pass --dart-define=EXPECT_DIRECT=true on a machine without any proxy to
// also assert that the OS answers DIRECT.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_proxy_resolver/http.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

const _expectDirect = bool.fromEnvironment('EXPECT_DIRECT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native resolver answers for http and https URLs', (_) async {
    final resolver = SystemProxyResolver();
    for (final url in ['https://example.com/', 'http://example.com/']) {
      final resolution = await resolver.resolveDetailed(Uri.parse(url));
      // ignore: avoid_print
      print('native_proxy_resolver: $resolution');
      expect(resolution.entries, isNotEmpty);
      expect(resolution.error, isNull);
      expect(resolution.source, isNot(ProxySource.unknown));
      if (_expectDirect) {
        expect(resolution.entries, [ProxyEntry.direct]);
        expect(resolution.toFindProxyString(), 'DIRECT');
        expect(resolution.source, ProxySource.none);
      }
    }
    // Second lookup is cached.
    expect(resolver.cached(Uri.parse('https://example.com/other')), isNotNull);
    await resolver.dispose();
  });

  testWidgets('ProxyAwareHttpClient and package:http fetch through the OS '
      'route', (_) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..write('ok')
        ..close();
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}/');
    final resolver = SystemProxyResolver();

    final client = ProxyAwareHttpClient(resolver: resolver);
    final response = await (await client.getUrl(url)).close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    client.close();

    final httpClient = createSystemProxyHttpClient(resolver: resolver);
    expect((await httpClient.get(url)).body, 'ok');
    httpClient.close();

    await resolver.dispose();
    await server.close(force: true);
  });
}
