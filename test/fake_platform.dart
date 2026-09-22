import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

/// A scriptable platform implementation for tests.
class FakeProxyPlatform extends NativeProxyResolverPlatform
    with MockPlatformInterfaceMixin {
  FakeProxyPlatform(this.answer);

  /// Produces the entries for a URL.
  List<ProxyEntry> Function(Uri uri) answer;

  /// Optional gate to hold resolutions until completed.
  Completer<void>? gate;

  /// Error text to attach to the next resolutions.
  String? error;

  final List<Uri> calls = [];
  final StreamController<void> changes = StreamController<void>.broadcast();

  @override
  Future<ProxyResolution> resolve(Uri uri, {required Duration timeout}) async {
    calls.add(uri);
    final g = gate;
    if (g != null) await g.future;
    return ProxyResolution(
      uri: uri,
      entries: answer(uri),
      source: ProxySource.pac,
      resolvedAt: DateTime.now(),
      error: error,
    );
  }

  @override
  bool get supportsChangeEvents => true;

  @override
  Stream<void> get onChange => changes.stream;
}
