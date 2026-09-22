import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/http.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

import 'fake_platform.dart';

/// A minimal forward HTTP proxy: answers every request itself and records the
/// absolute-form request target it received.
Future<(HttpServer, List<Uri>)> _startProxy() async {
  final seen = <Uri>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    seen.add(request.uri);
    request.response
      ..headers.contentType = ContentType.text
      ..write('via-proxy ${request.uri.host}')
      ..close();
  });
  return (server, seen);
}

Future<HttpServer> _startOrigin() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response
      ..write('direct')
      ..close();
  });
  return server;
}

void main() {
  late HttpServer proxy;
  late List<Uri> seen;
  late FakeProxyPlatform platform;
  late SystemProxyResolver resolver;

  setUp(() async {
    (proxy, seen) = await _startProxy();
    platform = FakeProxyPlatform(
      (uri) => uri.host == '127.0.0.1'
          ? const [ProxyEntry.direct]
          : [ProxyEntry.http('127.0.0.1', proxy.port), ProxyEntry.direct],
    );
    resolver = SystemProxyResolver(platform: platform);
  });

  tearDown(() async {
    await resolver.dispose();
    await proxy.close(force: true);
  });

  Future<String> read(HttpClientRequest request) async {
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  test(
    'ProxyAwareHttpClient pre-resolves and sends through the proxy',
    () async {
      final client = ProxyAwareHttpClient(resolver: resolver);
      // The host does not exist: only a proxy can answer.
      final body = await read(
        await client.getUrl(Uri.parse('http://corp-only.invalid/hello')),
      );
      expect(body, 'via-proxy corp-only.invalid');
      expect(seen.single.toString(), 'http://corp-only.invalid/hello');
      expect(platform.calls.single.host, 'corp-only.invalid');
      client.close(force: true);
    },
  );

  test('host/port/path variants are pre-resolved too', () async {
    final client = ProxyAwareHttpClient(resolver: resolver);
    final body = await read(await client.post('corp-only.invalid', 80, '/p'));
    expect(body, 'via-proxy corp-only.invalid');
    expect(platform.calls.single, Uri.parse('http://corp-only.invalid:80'));
    client.close(force: true);
  });

  test('DIRECT decisions connect straight to the origin', () async {
    final origin = await _startOrigin();
    final client = ProxyAwareHttpClient(resolver: resolver);
    final body = await read(
      await client.getUrl(Uri.parse('http://127.0.0.1:${origin.port}/')),
    );
    expect(body, 'direct');
    expect(seen, isEmpty);
    client.close(force: true);
    await origin.close(force: true);
  });

  test('an explicit findProxy disables system resolution', () async {
    final origin = await _startOrigin();
    final client = ProxyAwareHttpClient(resolver: resolver)
      ..findProxy = (_) => 'DIRECT';
    await read(
      await client.getUrl(Uri.parse('http://127.0.0.1:${origin.port}/')),
    );
    expect(platform.calls, isEmpty);
    client.close(force: true);
    await origin.close(force: true);
  });

  test('preResolve: false uses the warmed cache', () async {
    final uri = Uri.parse('http://corp-only.invalid/warm');
    await resolver.warmUp([uri]);
    final client = ProxyAwareHttpClient(resolver: resolver, preResolve: false);
    expect(await read(await client.getUrl(uri)), 'via-proxy corp-only.invalid');
    client.close(force: true);
  });

  test('forwards configuration to the inner client', () {
    final inner = HttpClient();
    final client = ProxyAwareHttpClient(inner: inner, resolver: resolver)
      ..userAgent = 'ua'
      ..connectionTimeout = const Duration(seconds: 3)
      ..idleTimeout = const Duration(seconds: 7)
      ..maxConnectionsPerHost = 4
      ..autoUncompress = false;
    expect(inner.userAgent, 'ua');
    expect(client.connectionTimeout, const Duration(seconds: 3));
    expect(inner.idleTimeout, const Duration(seconds: 7));
    expect(inner.maxConnectionsPerHost, 4);
    expect(inner.autoUncompress, isFalse);
    expect(client.inner, same(inner));
    client.close(force: true);
  });

  test('SystemProxyHttpOverrides makes HttpClient() proxy-aware', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      expect(client, isA<ProxyAwareHttpClient>());
      final body = await read(
        await client.getUrl(Uri.parse('http://corp-only.invalid/o')),
      );
      expect(body, 'via-proxy corp-only.invalid');
      client.close(force: true);
    }, SystemProxyHttpOverrides(resolver: resolver));
  });

  test('package:http client goes through the proxy', () async {
    final client = createSystemProxyHttpClient(resolver: resolver);
    final response = await client.get(Uri.parse('http://corp-only.invalid/h'));
    expect(response.statusCode, 200);
    expect(response.body, 'via-proxy corp-only.invalid');
    client.close();
  });
}
