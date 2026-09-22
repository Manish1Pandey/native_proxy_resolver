import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

void main() {
  group('ProxyEntry.toFindProxyString', () {
    test('formats PROXY host:port and DIRECT in order', () {
      expect(
        ProxyEntry.toFindProxyString(const [
          ProxyEntry.http('proxy.corp', 8080),
          ProxyEntry.http('backup.corp', 3128),
          ProxyEntry.direct,
        ]),
        'PROXY proxy.corp:8080; PROXY backup.corp:3128; DIRECT',
      );
    });

    test('a single DIRECT entry is "DIRECT"', () {
      expect(ProxyEntry.toFindProxyString(const [ProxyEntry.direct]), 'DIRECT');
    });

    test('brackets IPv6 hosts', () {
      expect(
        const ProxyEntry.http('2001:db8::1', 8080).toFindProxyDirective(),
        'PROXY [2001:db8::1]:8080',
      );
    });

    test('skips SOCKS and HTTPS proxies that dart:io cannot use', () {
      expect(
        ProxyEntry.toFindProxyString(const [
          ProxyEntry(type: ProxyType.socks5, host: 's', port: 1080),
          ProxyEntry(type: ProxyType.https, host: 't', port: 443),
          ProxyEntry.http('p', 80),
        ]),
        'PROXY p:80',
      );
    });

    test('uses the fallback when nothing usable remains', () {
      const socksOnly = [
        ProxyEntry(type: ProxyType.socks, host: 's', port: 1080),
      ];
      expect(ProxyEntry.toFindProxyString(socksOnly), 'DIRECT');
      expect(
        ProxyEntry.toFindProxyString(socksOnly, fallback: 'PROXY x:1'),
        'PROXY x:1',
      );
      expect(ProxyEntry.toFindProxyString(const []), 'DIRECT');
    });

    test('removes duplicate directives', () {
      expect(
        ProxyEntry.toFindProxyString(const [
          ProxyEntry.direct,
          ProxyEntry.direct,
        ]),
        'DIRECT',
      );
    });

    test('embeds credentials only when both parts are safe', () {
      expect(
        const ProxyEntry.http(
          'p',
          8080,
          username: 'bob',
          password: 's3cr:et',
        ).toFindProxyDirective(),
        'PROXY bob:s3cr:et@p:8080',
      );
      expect(
        const ProxyEntry.http(
          'p',
          8080,
          username: 'bob',
          password: 'a;b',
        ).toFindProxyDirective(),
        'PROXY p:8080',
      );
      expect(
        const ProxyEntry.http(
          'p',
          8080,
          username: 'bob',
        ).toFindProxyDirective(),
        'PROXY p:8080',
      );
      expect(
        const ProxyEntry.http(
          'p',
          8080,
          username: 'bob',
          password: 'pw',
        ).toFindProxyDirective(includeCredentials: false),
        'PROXY p:8080',
      );
    });
  });

  group('ProxyEntry maps', () {
    test('round-trips through toMap / fromMap', () {
      const entry = ProxyEntry(
        type: ProxyType.socks5,
        host: 'socks.corp',
        port: 1080,
        username: 'u',
      );
      expect(ProxyEntry.fromMap(entry.toMap()), entry);
      expect(ProxyEntry.fromMap(const {'type': 'direct'}), ProxyEntry.direct);
    });

    test('strips IPv6 brackets from native hosts', () {
      expect(
        ProxyEntry.fromMap(const {'type': 'http', 'host': '[::1]', 'port': 8}),
        const ProxyEntry.http('::1', 8),
      );
    });

    test('rejects malformed maps', () {
      expect(
        () => ProxyEntry.fromMap(const {'type': 'gopher'}),
        throwsFormatException,
      );
      expect(
        () => ProxyEntry.fromMap(const {'type': 'http', 'host': 'p'}),
        throwsFormatException,
      );
      expect(
        () => ProxyEntry.fromMap(const {'type': 'http', 'host': '', 'port': 1}),
        throwsFormatException,
      );
    });

    test('toString uses PAC keywords', () {
      expect(const ProxyEntry.http('p', 1).toString(), 'PROXY p:1');
      expect(
        const ProxyEntry(type: ProxyType.socks4, host: 's', port: 2).toString(),
        'SOCKS4 s:2',
      );
      expect(ProxyEntry.direct.toString(), 'DIRECT');
    });
  });

  test('ProxyResolution never has an empty entry list', () {
    final resolution = ProxyResolution(
      uri: Uri.parse('https://a'),
      entries: const [],
      source: ProxySource.none,
      resolvedAt: DateTime(2026),
    );
    expect(resolution.entries, [ProxyEntry.direct]);
    expect(resolution.isSuccess, isTrue);
    expect(resolution.toFindProxyString(), 'DIRECT');
  });

  test('ProxySource.fromName maps unknown names to unknown', () {
    expect(ProxySource.fromName('pac'), ProxySource.pac);
    expect(ProxySource.fromName('bogus'), ProxySource.unknown);
    expect(ProxySource.fromName(null), ProxySource.unknown);
  });
}
