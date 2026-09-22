import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannelNativeProxyResolver.methodChannel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final platform = MethodChannelNativeProxyResolver();
  final uri = Uri.parse('https://example.com/path');
  final calls = <MethodCall>[];

  void reply(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('sends the url and timeout to the native side', () async {
    reply(
      (_) => {
        'entries': [
          {'type': 'direct'},
        ],
        'source': 'none',
      },
    );
    await platform.resolve(uri, timeout: const Duration(seconds: 3));
    expect(calls.single.method, 'resolve');
    expect(calls.single.arguments, {
      'url': 'https://example.com/path',
      'timeoutMs': 3000,
    });
  });

  test('decodes Apple / Android style entry lists', () async {
    reply(
      (_) => {
        'entries': [
          {'type': 'http', 'host': 'proxy.corp', 'port': 8080},
          {'type': 'socks', 'host': 'socks.corp', 'port': 1080},
          {'type': 'direct'},
        ],
        'source': 'pac',
        'pacUrl': 'http://wpad.corp/wpad.dat',
      },
    );
    final r = await platform.resolve(uri, timeout: const Duration(seconds: 1));
    expect(r.entries, const [
      ProxyEntry.http('proxy.corp', 8080),
      ProxyEntry(type: ProxyType.socks, host: 'socks.corp', port: 1080),
      ProxyEntry.direct,
    ]);
    expect(r.source, ProxySource.pac);
    expect(r.pacUrl, Uri.parse('http://wpad.corp/wpad.dat'));
    expect(r.error, isNull);
    expect(r.toFindProxyString(), 'PROXY proxy.corp:8080; DIRECT');
  });

  test('parses Windows proxy lists and applies the bypass list', () async {
    reply(
      (_) => {
        'proxyList': 'http=h:80;https=s:8443',
        'proxyBypass': '<local>;*.corp.test',
        'source': 'manual',
      },
    );
    final r = await platform.resolve(uri, timeout: const Duration(seconds: 1));
    expect(r.entries, const [ProxyEntry.http('s', 8443)]);
    expect(r.source, ProxySource.manual);

    final bypassed = await platform.resolve(
      Uri.parse('https://git.corp.test/'),
      timeout: const Duration(seconds: 1),
    );
    expect(bypassed.entries, const [ProxyEntry.direct]);

    final local = await platform.resolve(
      Uri.parse('http://intranet/'),
      timeout: const Duration(seconds: 1),
    );
    expect(local.entries, const [ProxyEntry.direct]);
  });

  test('keeps native errors and skips malformed entries', () async {
    reply(
      (_) => {
        'entries': [
          {'type': 'http', 'host': 'p'},
          {'type': 'direct'},
        ],
        'source': 'pac',
        'error': 'PAC evaluation timed out after 1.0 s',
      },
    );
    final r = await platform.resolve(uri, timeout: const Duration(seconds: 1));
    expect(r.entries, const [ProxyEntry.direct]);
    expect(r.error, contains('timed out'));
    expect(r.error, contains('malformed'));
    expect(r.isSuccess, isFalse);
  });

  test('PlatformException becomes DIRECT with an error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'bad_args', message: 'nope');
    });
    final r = await platform.resolve(uri, timeout: const Duration(seconds: 1));
    expect(r.entries, const [ProxyEntry.direct]);
    expect(r.source, ProxySource.unknown);
    expect(r.error, contains('bad_args'));
  });

  test('a missing plugin becomes DIRECT with an error', () async {
    final r = await platform.resolve(uri, timeout: const Duration(seconds: 1));
    expect(r.entries, const [ProxyEntry.direct]);
    expect(r.error, contains('not registered'));
  });

  test('change events are unsupported on Windows only', () {
    expect(
      MethodChannelNativeProxyResolver(
        targetPlatform: TargetPlatform.windows,
      ).supportsChangeEvents,
      isFalse,
    );
    expect(
      MethodChannelNativeProxyResolver(
        targetPlatform: TargetPlatform.android,
      ).supportsChangeEvents,
      isTrue,
    );
  });

  test('forwards native change events', () async {
    const events = MethodChannelNativeProxyResolver.eventChannel;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success('network');
          sink.success('proxy');
        },
      ),
    );
    final received = await MethodChannelNativeProxyResolver(
      targetPlatform: TargetPlatform.macOS,
    ).onChange.take(2).length;
    expect(received, 2);
    messenger.setMockStreamHandler(events, null);
  });
}
