import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

void main() {
  bool noProxy(String spec, String url) =>
      ProxyBypassRules.parse(spec).matches(Uri.parse(url));
  bool wildcard(String spec, String url) => ProxyBypassRules.parse(
    spec,
    style: BypassStyle.wildcard,
  ).matches(Uri.parse(url));

  group('no_proxy style', () {
    test('domain matches itself and sub-domains, not look-alikes', () {
      expect(noProxy('example.com', 'https://example.com/'), isTrue);
      expect(noProxy('example.com', 'https://api.example.com/'), isTrue);
      expect(noProxy('example.com', 'https://badexample.com/'), isFalse);
      expect(noProxy('.example.com', 'https://example.com/'), isTrue);
      expect(noProxy('*.example.com', 'https://a.b.example.com/'), isTrue);
    });

    test('is case-insensitive and ignores trailing dots', () {
      expect(noProxy('Example.COM', 'https://API.example.com./'), isTrue);
    });

    test('"*" matches everything', () {
      expect(noProxy('*', 'http://anything.test/'), isTrue);
    });

    test('supports comma and space separated lists', () {
      const spec = 'localhost, .corp.test  10.0.0.0/8';
      expect(noProxy(spec, 'http://localhost:8080/'), isTrue);
      expect(noProxy(spec, 'http://git.corp.test/'), isTrue);
      expect(noProxy(spec, 'http://10.20.30.40/'), isTrue);
      expect(noProxy(spec, 'http://11.0.0.1/'), isFalse);
    });

    test('matches IP literals and CIDR blocks, IPv4 and IPv6', () {
      expect(noProxy('127.0.0.1', 'http://127.0.0.1:3000/'), isTrue);
      expect(noProxy('192.168.0.0/16', 'http://192.168.4.2/'), isTrue);
      expect(noProxy('192.168.0.0/16', 'http://192.169.0.1/'), isFalse);
      expect(noProxy('::1', 'http://[::1]:8080/'), isTrue);
      expect(noProxy('fd00::/8', 'http://[fd12:3456::1]/'), isTrue);
      expect(noProxy('fd00::/8', 'http://[fe80::1]/'), isFalse);
    });

    test('honours an explicit port', () {
      expect(noProxy('example.com:8443', 'https://example.com:8443/'), isTrue);
      expect(noProxy('example.com:8443', 'https://example.com/'), isFalse);
      expect(noProxy('example.com:443', 'https://example.com/'), isTrue);
    });

    test('empty specs match nothing', () {
      expect(ProxyBypassRules.parse('').isEmpty, isTrue);
      expect(ProxyBypassRules.parse(null).isEmpty, isTrue);
      expect(noProxy(' , ', 'http://a/'), isFalse);
    });
  });

  group('wildcard style', () {
    test('<local> matches dotless host names only', () {
      expect(wildcard('<local>', 'http://intranet/'), isTrue);
      expect(wildcard('<local>', 'http://intranet.corp/'), isFalse);
      expect(wildcard('<local>', 'http://10.0.0.1/'), isFalse);
    });

    test('glob patterns', () {
      const spec = '*.corp.example;10.*';
      expect(wildcard(spec, 'https://git.corp.example/'), isTrue);
      expect(wildcard(spec, 'https://corp.example/'), isFalse);
      expect(wildcard(spec, 'http://10.1.2.3/'), isTrue);
      expect(wildcard(spec, 'http://110.1.2.3/'), isFalse);
    });

    test('exact names do not match sub-domains', () {
      expect(wildcard('example.com', 'https://example.com/'), isTrue);
      expect(wildcard('example.com', 'https://www.example.com/'), isFalse);
    });

    test('leading dot means any sub-domain', () {
      expect(wildcard('.example.com', 'https://www.example.com/'), isTrue);
    });

    test('CIDR entries from GNOME ignore-hosts', () {
      final rules = ProxyBypassRules.fromList([
        'localhost',
        '127.0.0.0/8',
        '::1',
      ]);
      expect(rules.matches(Uri.parse('http://127.1.2.3/')), isTrue);
      expect(rules.matches(Uri.parse('http://[::1]/')), isTrue);
      expect(rules.matches(Uri.parse('http://localhost/')), isTrue);
      expect(rules.matches(Uri.parse('http://example.com/')), isFalse);
    });
  });
}
