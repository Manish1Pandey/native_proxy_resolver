import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';
import 'package:native_proxy_resolver_example/main.dart';

class _FakePlatform extends NativeProxyResolverPlatform
    with MockPlatformInterfaceMixin {
  final changes = StreamController<void>.broadcast();
  final requested = <Uri>[];

  @override
  Future<ProxyResolution> resolve(Uri uri, {required Duration timeout}) async {
    requested.add(uri);
    return ProxyResolution(
      uri: uri,
      entries: const [
        ProxyEntry.http('proxy.corp', 8080),
        ProxyEntry(type: ProxyType.socks5, host: 'socks.corp', port: 1080),
        ProxyEntry.direct,
      ],
      source: ProxySource.pac,
      pacUrl: Uri.parse('http://wpad.corp/wpad.dat'),
      resolvedAt: DateTime.now(),
    );
  }

  @override
  bool get supportsChangeEvents => true;

  @override
  Stream<void> get onChange => changes.stream;
}

void main() {
  testWidgets('resolves and shows the OS proxy decision', (tester) async {
    final platform = _FakePlatform();
    final resolver = SystemProxyResolver(platform: platform);
    await tester.pumpWidget(ProxyDemoApp(resolver: resolver));

    await tester.tap(find.byKey(const Key('resolve')));
    await tester.pumpAndSettle();

    expect(platform.requested.single, Uri.parse('https://example.com/'));
    expect(find.text('1. PROXY proxy.corp:8080'), findsOneWidget);
    expect(
      find.text('2. SOCKS5 socks.corp:1080  (not usable by dart:io)'),
      findsOneWidget,
    );
    expect(find.text('3. DIRECT'), findsOneWidget);
    expect(find.text('Source: pac'), findsOneWidget);
    expect(find.text('PAC: http://wpad.corp/wpad.dat'), findsOneWidget);
    expect(
      find.text('findProxy: PROXY proxy.corp:8080; DIRECT'),
      findsOneWidget,
    );

    // A second resolve is served from the cache.
    await tester.tap(find.byKey(const Key('resolve')));
    await tester.pumpAndSettle();
    expect(platform.requested, hasLength(1));

    // A change event clears the cache and is listed.
    platform.changes.add(null);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('network/proxy changed'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('network/proxy changed'), findsOneWidget);
    expect(resolver.cacheSize, 0);

    await platform.changes.close();
  });
}
