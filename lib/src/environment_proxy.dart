import 'package:meta/meta.dart';

import 'bypass_rules.dart';
import 'proxy_entry.dart';
import 'proxy_list_parser.dart';

/// Proxy configuration taken from the conventional environment variables
/// (`http_proxy`, `https_proxy`, `all_proxy`, `no_proxy`, lower or upper
/// case; the lower-case form wins, as in curl).
@immutable
class EnvironmentProxyConfig {
  /// Creates a configuration from already parsed values.
  const EnvironmentProxyConfig({
    this.httpProxy,
    this.httpsProxy,
    this.allProxy,
    this.noProxy = ProxyBypassRules.none,
  });

  /// Reads the variables from [environment] (usually
  /// `Platform.environment`).
  ///
  /// Following curl, upper-case `HTTP_PROXY` is ignored (it can be injected
  /// by CGI servers through the `Proxy:` request header); `http_proxy` must
  /// be lower case. The other variables may be either case.
  factory EnvironmentProxyConfig.fromEnvironment(
    Map<String, String> environment,
  ) {
    String? read(String name, {bool allowUpper = true}) {
      final lower = environment[name];
      if (lower != null && lower.trim().isNotEmpty) return lower.trim();
      if (!allowUpper) return null;
      final upper = environment[name.toUpperCase()];
      if (upper != null && upper.trim().isNotEmpty) return upper.trim();
      return null;
    }

    ProxyEntry? entry(String? value) =>
        value == null ? null : ProxyListParser.parseProxyUrl(value);

    return EnvironmentProxyConfig(
      httpProxy: entry(read('http_proxy', allowUpper: false)),
      httpsProxy: entry(read('https_proxy')),
      allProxy: entry(read('all_proxy')),
      noProxy: ProxyBypassRules.parse(read('no_proxy')),
    );
  }

  /// Proxy for `http://` and `ws://` URLs.
  final ProxyEntry? httpProxy;

  /// Proxy for `https://` and `wss://` URLs.
  final ProxyEntry? httpsProxy;

  /// Proxy for any scheme without a specific variable.
  final ProxyEntry? allProxy;

  /// Hosts that must be reached directly.
  final ProxyBypassRules noProxy;

  /// Whether any proxy variable is set.
  bool get hasProxy =>
      httpProxy != null || httpsProxy != null || allProxy != null;

  /// The routes for [uri]: `null` when no variable applies to its scheme,
  /// `[DIRECT]` when [noProxy] matches, otherwise the configured proxy.
  List<ProxyEntry>? entriesFor(Uri uri) {
    final proxy = switch (uri.scheme) {
      'http' || 'ws' => httpProxy ?? allProxy,
      'https' || 'wss' => httpsProxy ?? allProxy,
      _ => allProxy,
    };
    if (proxy == null) return null;
    if (noProxy.matches(uri)) return const [ProxyEntry.direct];
    return [proxy];
  }
}
