import 'dart:io';

import 'http_client.dart';
import 'proxy_entry.dart';
import 'resolver.dart';

/// Static entry point: resolve the operating system's proxy for a URL.
///
/// ```dart
/// final proxies = await SystemProxy.resolve(Uri.parse('https://example.com'));
/// // e.g. [PROXY proxy.corp:8080, DIRECT]
/// ```
///
/// All methods delegate to [resolver], a shared [SystemProxyResolver] with
/// default settings that you may replace.
abstract final class SystemProxy {
  static SystemProxyResolver? _resolver;

  /// The shared resolver used by the static methods, [ProxyAwareHttpClient]
  /// and [SystemProxyHttpOverrides] when no resolver is passed explicitly.
  static SystemProxyResolver get resolver =>
      _resolver ??= SystemProxyResolver();

  /// Replaces the shared resolver (e.g. to change TTL or timeout). The
  /// previous one is disposed.
  static set resolver(SystemProxyResolver value) {
    final old = _resolver;
    _resolver = value;
    if (old != null && !identical(old, value)) old.dispose();
  }

  /// The ordered proxy list for [uri]; see [SystemProxyResolver.resolve].
  static Future<List<ProxyEntry>> resolve(
    Uri uri, {
    bool forceRefresh = false,
  }) => resolver.resolve(uri, forceRefresh: forceRefresh);

  /// The full resolution for [uri]; see
  /// [SystemProxyResolver.resolveDetailed].
  static Future<ProxyResolution> resolveDetailed(
    Uri uri, {
    bool forceRefresh = false,
  }) => resolver.resolveDetailed(uri, forceRefresh: forceRefresh);

  /// Synchronous, cache-backed `HttpClient.findProxy` answer for [uri]; see
  /// [SystemProxyResolver.findProxy].
  static String findProxy(Uri uri, {String fallback = 'DIRECT'}) =>
      resolver.findProxy(uri, fallback: fallback);

  /// Pre-resolves [uris] so later synchronous lookups hit the cache.
  static Future<void> warmUp(Iterable<Uri> uris) => resolver.warmUp(uris);

  /// Clears cached resolutions.
  static void clearCache() => resolver.clearCache();

  /// Emits when the network or proxy configuration changes.
  static Stream<void> get onChange => resolver.onChange;

  /// Whether [onChange] delivers events on this platform.
  static bool get supportsChangeEvents => resolver.supportsChangeEvents;

  /// Makes every `HttpClient()` created afterwards in this isolate a
  /// [ProxyAwareHttpClient] by setting `HttpOverrides.global`. Any overrides
  /// already installed are kept and used to build the inner client.
  ///
  /// Returns the installed overrides.
  static SystemProxyHttpOverrides installHttpOverrides({
    SystemProxyResolver? resolver,
    String fallback = 'DIRECT',
    bool preResolve = true,
  }) {
    final current = HttpOverrides.current;
    final overrides = SystemProxyHttpOverrides(
      resolver: resolver,
      fallback: fallback,
      preResolve: preResolve,
      previous: current is SystemProxyHttpOverrides
          ? current.previous
          : current,
    );
    HttpOverrides.global = overrides;
    return overrides;
  }
}
