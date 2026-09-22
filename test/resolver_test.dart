import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

import 'fake_platform.dart';

void main() {
  late FakeProxyPlatform platform;
  late DateTime now;
  late SystemProxyResolver resolver;

  setUp(() {
    platform = FakeProxyPlatform((_) => const [ProxyEntry.http('p', 8080)]);
    now = DateTime(2026, 1, 1);
    resolver = SystemProxyResolver(
      platform: platform,
      cacheTtl: const Duration(minutes: 5),
      errorTtl: const Duration(seconds: 30),
      maxCacheEntries: 3,
      clock: () => now,
    );
  });

  tearDown(() => resolver.dispose());

  test('caches per origin until the TTL expires', () async {
    await resolver.resolve(Uri.parse('https://a.test/one'));
    await resolver.resolve(Uri.parse('https://A.test/two?x=1'));
    expect(platform.calls, hasLength(1));

    now = now.add(const Duration(minutes: 4, seconds: 59));
    await resolver.resolve(Uri.parse('https://a.test/'));
    expect(platform.calls, hasLength(1));

    now = now.add(const Duration(seconds: 1));
    await resolver.resolve(Uri.parse('https://a.test/'));
    expect(platform.calls, hasLength(2));
  });

  test('different scheme or port is a different origin', () async {
    await resolver.resolve(Uri.parse('https://a.test/'));
    await resolver.resolve(Uri.parse('http://a.test/'));
    await resolver.resolve(Uri.parse('https://a.test:8443/'));
    expect(platform.calls, hasLength(3));
  });

  test('ws/wss are resolved as http/https', () async {
    await resolver.resolve(Uri.parse('wss://a.test/socket'));
    expect(platform.calls.single.scheme, 'https');
    expect(platform.calls.single.port, 443);
    await resolver.resolve(Uri.parse('https://a.test/'));
    expect(platform.calls, hasLength(1));
  });

  test('forceRefresh bypasses the cache', () async {
    await resolver.resolve(Uri.parse('https://a.test/'));
    await resolver.resolve(Uri.parse('https://a.test/'), forceRefresh: true);
    expect(platform.calls, hasLength(2));
  });

  test('errors are cached for errorTtl only', () async {
    platform.error = 'PAC download failed';
    final first = await resolver.resolveDetailed(Uri.parse('https://a.test/'));
    expect(first.isSuccess, isFalse);
    now = now.add(const Duration(seconds: 29));
    await resolver.resolve(Uri.parse('https://a.test/'));
    expect(platform.calls, hasLength(1));
    now = now.add(const Duration(seconds: 1));
    await resolver.resolve(Uri.parse('https://a.test/'));
    expect(platform.calls, hasLength(2));
  });

  test('concurrent lookups for one origin share a native call', () async {
    platform.gate = Completer<void>();
    final futures = [
      resolver.resolve(Uri.parse('https://a.test/1')),
      resolver.resolve(Uri.parse('https://a.test/2')),
      resolver.resolve(Uri.parse('https://a.test/3')),
    ];
    platform.gate!.complete();
    final results = await Future.wait(futures);
    expect(platform.calls, hasLength(1));
    expect(
      results.every((r) => r.single == const ProxyEntry.http('p', 8080)),
      isTrue,
    );
  });

  test('evicts the least recently used origin', () async {
    for (final host in ['a', 'b', 'c']) {
      await resolver.resolve(Uri.parse('https://$host.test/'));
    }
    // Touch "a" so "b" becomes the oldest.
    await resolver.resolve(Uri.parse('https://a.test/'));
    await resolver.resolve(Uri.parse('https://d.test/'));
    expect(resolver.cacheSize, 3);
    expect(resolver.cached(Uri.parse('https://b.test/')), isNull);
    expect(resolver.cached(Uri.parse('https://a.test/')), isNotNull);
  });

  test('change events clear the cache', () async {
    await resolver.resolve(Uri.parse('https://a.test/'));
    expect(resolver.cacheSize, 1);
    platform.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(resolver.cacheSize, 0);
  });

  test('a change during resolution is not cached', () async {
    // Subscribe first so the change event reaches the resolver.
    await resolver.resolve(Uri.parse('https://warm.test/'));
    platform.gate = Completer<void>();
    final pending = resolver.resolve(Uri.parse('https://a.test/'));
    await Future<void>.delayed(Duration.zero);
    platform.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    platform.gate!.complete();
    await pending;
    expect(resolver.cached(Uri.parse('https://a.test/')), isNull);
  });

  group('findProxy (synchronous)', () {
    test('miss returns the fallback and warms the cache', () async {
      final uri = Uri.parse('https://a.test/');
      expect(resolver.findProxy(uri), 'DIRECT');
      expect(resolver.findProxy(uri, fallback: 'PROXY f:1'), 'PROXY f:1');
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls, hasLength(1));
      expect(resolver.findProxy(uri), 'PROXY p:8080');
    });

    test('resolveOnMiss: false does not start a lookup', () async {
      resolver.findProxy(Uri.parse('https://a.test/'), resolveOnMiss: false);
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls, isEmpty);
    });

    test('stale entries are still used while refreshing', () async {
      final uri = Uri.parse('https://a.test/');
      await resolver.resolve(uri);
      now = now.add(const Duration(hours: 1));
      platform.answer = (_) => const [ProxyEntry.direct];
      expect(resolver.findProxy(uri), 'PROXY p:8080');
      await Future<void>.delayed(Duration.zero);
      expect(resolver.findProxy(uri), 'DIRECT');
    });

    test('findProxyCallback plugs into HttpClient.findProxy', () async {
      await resolver.warmUp([Uri.parse('http://b.test/')]);
      final callback = resolver.findProxyCallback();
      expect(callback(Uri.parse('http://b.test/x')), 'PROXY p:8080');
    });
  });

  test('platform exceptions become DIRECT with an error', () async {
    final throwing = SystemProxyResolver(platform: _ThrowingPlatform());
    final r = await throwing.resolveDetailed(Uri.parse('https://a.test/'));
    expect(r.entries, const [ProxyEntry.direct]);
    expect(r.error, contains('boom'));
    await throwing.dispose();
  });

  test('rejects URIs without a host and use after dispose', () async {
    expect(() => resolver.resolve(Uri.parse('/relative')), throwsArgumentError);
    await resolver.dispose();
    expect(
      () => resolver.resolve(Uri.parse('https://a.test/')),
      throwsStateError,
    );
    expect(resolver.findProxy(Uri.parse('https://a.test/')), 'DIRECT');
  });

  test('SystemProxy facade delegates to the shared resolver', () async {
    final shared = SystemProxyResolver(platform: platform, clock: () => now);
    SystemProxy.resolver = shared;
    expect(await SystemProxy.resolve(Uri.parse('https://z.test/')), const [
      ProxyEntry.http('p', 8080),
    ]);
    expect(SystemProxy.findProxy(Uri.parse('https://z.test/')), 'PROXY p:8080');
    SystemProxy.clearCache();
    expect(shared.cacheSize, 0);
    expect(SystemProxy.supportsChangeEvents, isTrue);
  });
}

class _ThrowingPlatform extends FakeProxyPlatform {
  _ThrowingPlatform() : super((_) => const []);

  @override
  Future<ProxyResolution> resolve(Uri uri, {required Duration timeout}) =>
      Future.error(StateError('boom').toString());
}
