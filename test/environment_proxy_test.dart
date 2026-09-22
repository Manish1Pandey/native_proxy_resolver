import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

void main() {
  List<ProxyEntry>? route(Map<String, String> env, String url) =>
      EnvironmentProxyConfig.fromEnvironment(env).entriesFor(Uri.parse(url));

  test('picks http_proxy / https_proxy by scheme', () {
    const env = {'http_proxy': 'http://h:3128', 'https_proxy': 'http://s:3129'};
    expect(route(env, 'http://a.test/'), const [ProxyEntry.http('h', 3128)]);
    expect(route(env, 'https://a.test/'), const [ProxyEntry.http('s', 3129)]);
    expect(route(env, 'ws://a.test/'), const [ProxyEntry.http('h', 3128)]);
  });

  test('all_proxy is the fallback; unmatched schemes give null', () {
    expect(route(const {'ALL_PROXY': 'socks5://k:1080'}, 'https://a/'), const [
      ProxyEntry(type: ProxyType.socks5, host: 'k', port: 1080),
    ]);
    expect(route(const {'http_proxy': 'h:1'}, 'https://a/'), isNull);
    expect(EnvironmentProxyConfig.fromEnvironment(const {}).hasProxy, isFalse);
  });

  test('upper-case HTTP_PROXY is ignored (httpoxy), others accepted', () {
    expect(route(const {'HTTP_PROXY': 'h:1'}, 'http://a/'), isNull);
    expect(route(const {'HTTPS_PROXY': 's:2'}, 'https://a/'), const [
      ProxyEntry.http('s', 2),
    ]);
  });

  test('lower case wins over upper case', () {
    expect(
      route(const {
        'https_proxy': 'lower:1',
        'HTTPS_PROXY': 'upper:2',
      }, 'https://a/'),
      const [ProxyEntry.http('lower', 1)],
    );
  });

  test('no_proxy / NO_PROXY yield DIRECT', () {
    const env = {
      'https_proxy': 's:1',
      'NO_PROXY': 'localhost,.internal.test,10.0.0.0/8',
    };
    expect(route(env, 'https://svc.internal.test/'), const [ProxyEntry.direct]);
    expect(route(env, 'https://10.1.1.1/'), const [ProxyEntry.direct]);
    expect(route(env, 'https://public.test/'), const [ProxyEntry.http('s', 1)]);
  });
}
