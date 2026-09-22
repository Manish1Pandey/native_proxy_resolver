import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

void main() {
  group('parsePacResult', () {
    test('parses every PAC directive', () {
      expect(
        ProxyListParser.parsePacResult(
          'PROXY a:8080; HTTPS b:443; SOCKS c:1080; SOCKS4 d:1081; '
          'SOCKS5 e:1082; HTTP f:81; DIRECT',
        ),
        const [
          ProxyEntry.http('a', 8080),
          ProxyEntry(type: ProxyType.https, host: 'b', port: 443),
          ProxyEntry(type: ProxyType.socks, host: 'c', port: 1080),
          ProxyEntry(type: ProxyType.socks4, host: 'd', port: 1081),
          ProxyEntry(type: ProxyType.socks5, host: 'e', port: 1082),
          ProxyEntry.http('f', 81),
          ProxyEntry.direct,
        ],
      );
    });

    test('is case-insensitive, tolerant of spacing, skips junk', () {
      expect(
        ProxyListParser.parsePacResult(
          ' proxy  a:1 ;; bogus x:1; PROXY; direct',
        ),
        const [ProxyEntry.http('a', 1), ProxyEntry.direct],
      );
    });

    test('defaults the port', () {
      expect(ProxyListParser.parsePacResult('PROXY a'), const [
        ProxyEntry.http('a', 80),
      ]);
    });
  });

  group('parseServerList (Windows syntax)', () {
    final http = Uri.parse('http://example.com/');
    final https = Uri.parse('https://example.com/');

    test('an unprefixed list applies to every scheme', () {
      expect(ProxyListParser.parseServerList('proxy:8080', https), const [
        ProxyEntry.http('proxy', 8080),
      ]);
      expect(
        ProxyListParser.parseServerList('p1:8080;p2:3128 p3', http),
        const [
          ProxyEntry.http('p1', 8080),
          ProxyEntry.http('p2', 3128),
          ProxyEntry.http('p3', 80),
        ],
      );
    });

    test('scheme=host entries are selected by target scheme', () {
      const spec = 'http=h:80;https=s:443;ftp=f:21;socks=k:1080';
      expect(ProxyListParser.parseServerList(spec, http), const [
        ProxyEntry.http('h', 80),
      ]);
      expect(ProxyListParser.parseServerList(spec, https), const [
        ProxyEntry.http('s', 443),
      ]);
      expect(
        ProxyListParser.parseServerList(spec, Uri.parse('wss://x/')),
        const [ProxyEntry.http('s', 443)],
      );
    });

    test('falls back to socks= when the scheme has no entry', () {
      expect(
        ProxyListParser.parseServerList('http=h:80;socks=k:1080', https),
        const [ProxyEntry(type: ProxyType.socks, host: 'k', port: 1080)],
      );
    });

    test('explicit proxy scheme prefixes and DIRECT', () {
      expect(
        ProxyListParser.parseServerList(
          'socks5://s:1080;https://t:8443;DIRECT',
          http,
        ),
        const [
          ProxyEntry(type: ProxyType.socks5, host: 's', port: 1080),
          ProxyEntry(type: ProxyType.https, host: 't', port: 8443),
          ProxyEntry.direct,
        ],
      );
    });

    test('IPv6 proxies', () {
      expect(ProxyListParser.parseServerList('[fd00::1]:3128', http), const [
        ProxyEntry.http('fd00::1', 3128),
      ]);
    });
  });

  group('parseProxyUrl', () {
    test('parses credentials, scheme, path and defaults', () {
      expect(
        ProxyListParser.parseProxyUrl('http://us%40r:p%3Ass@proxy:3128/'),
        const ProxyEntry.http(
          'proxy',
          3128,
          username: 'us@r',
          password: 'p:ss',
        ),
      );
      expect(
        ProxyListParser.parseProxyUrl('socks5h://s'),
        const ProxyEntry(type: ProxyType.socks5, host: 's', port: 1080),
      );
      expect(
        ProxyListParser.parseProxyUrl('proxy.corp:8080'),
        const ProxyEntry.http('proxy.corp', 8080),
      );
    });

    test('rejects unusable values', () {
      expect(ProxyListParser.parseProxyUrl(''), isNull);
      expect(ProxyListParser.parseProxyUrl('ftp://x:21'), isNull);
      expect(ProxyListParser.parseProxyUrl('proxy:notaport'), isNull);
      expect(ProxyListParser.parseProxyUrl('proxy:70000'), isNull);
    });
  });
}
