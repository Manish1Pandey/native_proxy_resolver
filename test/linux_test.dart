import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

const _manual = '''
org.gnome.system.proxy autoconfig-url ''
org.gnome.system.proxy ignore-hosts ['localhost', '127.0.0.0/8', '::1', '*.corp.test']
org.gnome.system.proxy mode 'manual'
org.gnome.system.proxy use-same-proxy false
org.gnome.system.proxy.http authentication-password 'pw'
org.gnome.system.proxy.http authentication-user 'bob'
org.gnome.system.proxy.http enabled false
org.gnome.system.proxy.http host 'http.proxy'
org.gnome.system.proxy.http port 3128
org.gnome.system.proxy.http use-authentication true
org.gnome.system.proxy.https host 'https.proxy'
org.gnome.system.proxy.https port 3129
org.gnome.system.proxy.socks host 'socks.proxy'
org.gnome.system.proxy.socks port 1080
''';

NativeProxyResolverLinux _linux({
  Map<String, String> env = const {},
  String? gsettings,
  int exitCode = 0,
  List<List<String>>? log,
}) => NativeProxyResolverLinux(
  environment: env,
  runProcess: (exe, args) async {
    log?.add([exe, ...args]);
    if (gsettings == null) throw const ProcessException('gsettings', []);
    return ProcessResult(1, exitCode, gsettings, '');
  },
);

Future<ProxyResolution> _resolve(NativeProxyResolverLinux linux, String url) =>
    linux.resolve(Uri.parse(url), timeout: const Duration(seconds: 1));

void main() {
  test('environment variables win over GNOME settings', () async {
    final log = <List<String>>[];
    final linux = _linux(
      env: const {'https_proxy': 'http://env:8080', 'no_proxy': '.internal'},
      gsettings: _manual,
      log: log,
    );
    final r = await _resolve(linux, 'https://example.com/');
    expect(r.entries, const [ProxyEntry.http('env', 8080)]);
    expect(r.source, ProxySource.environment);
    expect((await _resolve(linux, 'https://a.internal/')).entries, const [
      ProxyEntry.direct,
    ]);
    expect(log, isEmpty);
  });

  test('GNOME manual mode picks the proxy by scheme', () async {
    final linux = _linux(gsettings: _manual);
    expect((await _resolve(linux, 'http://example.com/')).entries, const [
      ProxyEntry.http('http.proxy', 3128, username: 'bob', password: 'pw'),
    ]);
    final https = await _resolve(linux, 'https://example.com/');
    expect(https.entries, const [ProxyEntry.http('https.proxy', 3129)]);
    expect(https.source, ProxySource.manual);
  });

  test('GNOME ignore-hosts bypasses the proxy', () async {
    final linux = _linux(gsettings: _manual);
    for (final url in [
      'http://localhost:8080/',
      'http://127.0.0.5/',
      'http://[::1]/',
      'https://git.corp.test/',
    ]) {
      expect((await _resolve(linux, url)).entries, const [
        ProxyEntry.direct,
      ], reason: url);
    }
  });

  test('GNOME socks proxy is used when the scheme has no proxy', () async {
    final linux = _linux(
      gsettings: _manual
          .replaceAll("host 'https.proxy'", "host ''")
          .replaceAll('https port 3129', 'https port 0'),
    );
    expect((await _resolve(linux, 'https://example.com/')).entries, const [
      ProxyEntry(type: ProxyType.socks, host: 'socks.proxy', port: 1080),
    ]);
  });

  test('GNOME auto mode is reported honestly', () async {
    final linux = _linux(
      gsettings:
          "org.gnome.system.proxy mode 'auto'\n"
          "org.gnome.system.proxy autoconfig-url 'http://wpad/wpad.dat'\n",
    );
    final r = await _resolve(linux, 'https://example.com/');
    expect(r.entries, const [ProxyEntry.direct]);
    expect(r.source, ProxySource.pac);
    expect(r.pacUrl, Uri.parse('http://wpad/wpad.dat'));
    expect(r.error, contains('not evaluated'));

    final wpad = _linux(gsettings: "org.gnome.system.proxy mode 'auto'\n");
    final w = await _resolve(wpad, 'https://example.com/');
    expect(w.source, ProxySource.autoDetect);
    expect(w.error, isNotNull);
  });

  test(
    'mode none, missing gsettings or a failing gsettings is DIRECT',
    () async {
      for (final linux in [
        _linux(gsettings: "org.gnome.system.proxy mode 'none'\n"),
        _linux(),
        _linux(gsettings: '', exitCode: 1),
      ]) {
        final r = await _resolve(linux, 'https://example.com/');
        expect(r.entries, const [ProxyEntry.direct]);
        expect(r.source, ProxySource.none);
        expect(r.error, isNull);
      }
      final missing = _linux();
      await _resolve(missing, 'https://example.com/');
      expect(missing.supportsChangeEvents, isFalse);
    },
  );

  test('gsettings output is read once per snapshot TTL', () async {
    final log = <List<String>>[];
    final linux = _linux(gsettings: _manual, log: log);
    await _resolve(linux, 'https://a/');
    await _resolve(linux, 'https://b/');
    expect(log, [
      ['gsettings', 'list-recursively', 'org.gnome.system.proxy'],
    ]);
  });

  test('GVariant parsing', () {
    expect(NativeProxyResolverLinux.parseGVariantString("'it\\'s'"), "it's");
    expect(NativeProxyResolverLinux.parseGVariantString('3128'), isNull);
    expect(NativeProxyResolverLinux.parseGVariantStringList('@as []'), isEmpty);
    expect(NativeProxyResolverLinux.parseGVariantStringList("['a', \"b\"]"), [
      'a',
      'b',
    ]);
  });

  test('gsettings monitor output emits change events', () async {
    final started = <String>[];
    final stdouts = <StreamController<List<int>>>[];
    final linux = NativeProxyResolverLinux(
      environment: const {},
      runProcess: (_, _) async => ProcessResult(1, 0, _manual, ''),
      startProcess: (exe, args) async {
        started.add(args.last);
        final out = StreamController<List<int>>();
        stdouts.add(out);
        return _FakeProcess(out.stream);
      },
    );
    final events = <void>[];
    final sub = linux.onChange.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(started, [
      'org.gnome.system.proxy',
      'org.gnome.system.proxy.http',
      'org.gnome.system.proxy.https',
      'org.gnome.system.proxy.socks',
    ]);
    stdouts[1].add(utf8.encode("host: 'new.proxy'\n"));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    await sub.cancel();
    for (final s in stdouts) {
      await s.close();
    }
  });
}

class _FakeProcess implements Process {
  _FakeProcess(this.stdout);

  @override
  final Stream<List<int>> stdout;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  int get pid => 1;

  @override
  IOSink get stdin => throw UnsupportedError('stdin');
}
