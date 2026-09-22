import 'proxy_entry.dart';

/// Parsers for the textual proxy-list formats used by PAC scripts, Windows
/// (WinHTTP / Internet Settings) and environment variables.
abstract final class ProxyListParser {
  /// Parses the return value of a PAC `FindProxyForURL` call, e.g.
  /// `PROXY a.corp:8080; SOCKS5 b.corp:1080; DIRECT`.
  ///
  /// Recognised directives: `DIRECT`, `PROXY`, `HTTP`, `HTTPS`, `SOCKS`,
  /// `SOCKS4`, `SOCKS5` (case-insensitive). Unknown or malformed directives
  /// are skipped. Returns an empty list when nothing could be parsed.
  static List<ProxyEntry> parsePacResult(String result) {
    final entries = <ProxyEntry>[];
    for (final raw in result.split(';')) {
      final item = raw.trim();
      if (item.isEmpty) continue;
      final parts = item.split(RegExp(r'\s+'));
      final keyword = parts.first.toUpperCase();
      if (keyword == 'DIRECT') {
        entries.add(ProxyEntry.direct);
        continue;
      }
      if (parts.length < 2) continue;
      final type = switch (keyword) {
        'PROXY' || 'HTTP' => ProxyType.http,
        'HTTPS' => ProxyType.https,
        'SOCKS' => ProxyType.socks,
        'SOCKS4' => ProxyType.socks4,
        'SOCKS5' => ProxyType.socks5,
        _ => null,
      };
      if (type == null) continue;
      final entry = _hostPortEntry(type, parts[1]);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  /// Parses a Windows-style proxy server list (as returned by
  /// `WinHttpGetIEProxyConfigForCurrentUser`, `WinHttpGetProxyForUrl` or the
  /// `ProxyServer` registry value) and selects the entries that apply to
  /// [target].
  ///
  /// Items are separated by `;` or whitespace and may be
  /// * `host:port` / `host` — applies to every scheme,
  /// * `scheme=host:port` — applies only to that target scheme (`http`,
  ///   `https`, `ftp`); `socks=host:port` applies to every scheme that has no
  ///   specific entry,
  /// * `scheme://host:port` — the proxy protocol is given explicitly
  ///   (`http`, `https`, `socks`, `socks4`, `socks5`),
  /// * `DIRECT`.
  static List<ProxyEntry> parseServerList(String spec, Uri target) {
    final scheme = switch (target.scheme) {
      'ws' => 'http',
      'wss' => 'https',
      final s => s,
    };
    final specific = <ProxyEntry>[];
    final generic = <ProxyEntry>[];
    final socks = <ProxyEntry>[];
    for (final raw in spec.split(RegExp(r'[;\s]+'))) {
      final item = raw.trim();
      if (item.isEmpty) continue;
      if (item.toUpperCase() == 'DIRECT') {
        generic.add(ProxyEntry.direct);
        continue;
      }
      final eq = item.indexOf('=');
      if (eq > 0) {
        final key = item.substring(0, eq).toLowerCase();
        final value = item.substring(eq + 1);
        if (key == 'socks') {
          final entry = _urlLikeEntry(value, defaultType: ProxyType.socks);
          if (entry != null) socks.add(entry);
        } else if (key == scheme) {
          final entry = _urlLikeEntry(value, defaultType: ProxyType.http);
          if (entry != null) specific.add(entry);
        }
        continue;
      }
      final entry = _urlLikeEntry(item, defaultType: ProxyType.http);
      if (entry != null) generic.add(entry);
    }
    if (specific.isNotEmpty) return specific;
    if (generic.isNotEmpty) return generic;
    return socks;
  }

  /// Parses a proxy URL such as `http://user:pass@proxy:3128`,
  /// `socks5://proxy:1080` or a bare `proxy:3128` (as found in `http_proxy`
  /// environment variables). Returns `null` when [value] is not a usable
  /// proxy address.
  static ProxyEntry? parseProxyUrl(String value) =>
      _urlLikeEntry(value.trim(), defaultType: ProxyType.http);

  static ProxyEntry? _urlLikeEntry(
    String value, {
    required ProxyType defaultType,
  }) {
    if (value.isEmpty) return null;
    var type = defaultType;
    var rest = value;
    final schemeEnd = value.indexOf('://');
    if (schemeEnd > 0) {
      final scheme = value.substring(0, schemeEnd).toLowerCase();
      final parsed = switch (scheme) {
        'http' => ProxyType.http,
        'https' => ProxyType.https,
        'socks' || 'socks4a' => ProxyType.socks,
        'socks4' => ProxyType.socks4,
        'socks5' || 'socks5h' => ProxyType.socks5,
        _ => null,
      };
      if (parsed == null) return null;
      type = parsed;
      rest = value.substring(schemeEnd + 3);
    }
    // Drop any path ("proxy:3128/").
    final slash = rest.indexOf('/');
    if (slash >= 0) rest = rest.substring(0, slash);
    String? username;
    String? password;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      final userinfo = rest.substring(0, at);
      rest = rest.substring(at + 1);
      final colon = userinfo.indexOf(':');
      if (colon >= 0) {
        username = Uri.decodeComponent(userinfo.substring(0, colon));
        password = Uri.decodeComponent(userinfo.substring(colon + 1));
      } else {
        username = Uri.decodeComponent(userinfo);
      }
    }
    return _hostPortEntry(type, rest, username: username, password: password);
  }

  static ProxyEntry? _hostPortEntry(
    ProxyType type,
    String hostPort, {
    String? username,
    String? password,
  }) {
    var host = hostPort.trim();
    int? port;
    if (host.startsWith('[')) {
      final close = host.indexOf(']');
      if (close < 0) return null;
      final rest = host.substring(close + 1);
      host = host.substring(1, close);
      if (rest.startsWith(':')) port = int.tryParse(rest.substring(1));
      if (rest.isNotEmpty && port == null) return null;
    } else {
      final colon = host.lastIndexOf(':');
      if (colon >= 0 && host.indexOf(':') == colon) {
        port = int.tryParse(host.substring(colon + 1));
        if (port == null) return null;
        host = host.substring(0, colon);
      }
    }
    if (host.isEmpty) return null;
    port ??= _defaultPort(type);
    if (port <= 0 || port > 65535) return null;
    return ProxyEntry(
      type: type,
      host: host,
      port: port,
      username: username == null || username.isEmpty ? null : username,
      password: password == null || password.isEmpty ? null : password,
    );
  }

  static int _defaultPort(ProxyType type) => switch (type) {
    ProxyType.https => 443,
    ProxyType.socks || ProxyType.socks4 || ProxyType.socks5 => 1080,
    _ => 80,
  };
}
