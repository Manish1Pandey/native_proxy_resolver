import 'package:meta/meta.dart';

/// The kind of connection a [ProxyEntry] describes.
enum ProxyType {
  /// Connect to the target directly, without a proxy.
  direct,

  /// A plain HTTP proxy (`PROXY host:port` in PAC syntax). HTTPS targets are
  /// tunnelled through it with `CONNECT`.
  http,

  /// A proxy reached over TLS (`HTTPS host:port` in PAC syntax). `dart:io`
  /// cannot use this kind of proxy.
  https,

  /// A SOCKS version 4 proxy. `dart:io` cannot use this kind of proxy.
  socks4,

  /// A SOCKS version 5 proxy. `dart:io` cannot use this kind of proxy.
  socks5,

  /// A SOCKS proxy whose protocol version the OS did not specify.
  /// `dart:io` cannot use this kind of proxy.
  socks,
}

/// Where a proxy decision came from.
enum ProxySource {
  /// A PAC (proxy auto-config) script configured by URL or inline script.
  pac,

  /// WPAD auto-discovery (DHCP / DNS) found and ran a PAC script.
  autoDetect,

  /// A static proxy configured in the OS settings.
  manual,

  /// Environment variables such as `http_proxy` / `no_proxy`.
  environment,

  /// No proxy is configured; the connection is direct.
  none,

  /// The platform did not say how the decision was made.
  unknown;

  /// Parses the wire name sent by the native side; unknown names map to
  /// [ProxySource.unknown].
  static ProxySource fromName(String? name) {
    for (final value in ProxySource.values) {
      if (value.name == name) return value;
    }
    return ProxySource.unknown;
  }
}

/// One candidate route for a request: either [ProxyType.direct] or a proxy
/// server at [host]:[port].
///
/// Proxy lists are ordered; a client should try the entries in order and move
/// on to the next one when a proxy cannot be reached.
@immutable
class ProxyEntry {
  /// Creates a proxy entry. [host] and [port] are required for every type
  /// except [ProxyType.direct].
  const ProxyEntry({
    required this.type,
    this.host,
    this.port,
    this.username,
    this.password,
  }) : assert(
         type == ProxyType.direct || (host != null && port != null),
         'Proxy entries other than DIRECT need a host and a port.',
       );

  /// A direct (no proxy) entry.
  static const ProxyEntry direct = ProxyEntry(type: ProxyType.direct);

  /// Convenience constructor for an HTTP proxy.
  const ProxyEntry.http(
    String this.host,
    int this.port, {
    this.username,
    this.password,
  }) : type = ProxyType.http;

  /// The kind of route.
  final ProxyType type;

  /// Proxy host name or IP literal (without IPv6 brackets). `null` for
  /// [ProxyType.direct].
  final String? host;

  /// Proxy port. `null` for [ProxyType.direct].
  final int? port;

  /// User name supplied by the OS configuration, if any.
  final String? username;

  /// Password supplied by the OS configuration, if any. Most platforms keep
  /// proxy passwords in a credential store and do not expose them.
  final String? password;

  /// Whether this entry is a direct connection.
  bool get isDirect => type == ProxyType.direct;

  /// Whether `dart:io` `HttpClient` can use this entry (DIRECT or an HTTP
  /// proxy).
  bool get isSupportedByDartIo =>
      type == ProxyType.direct || type == ProxyType.http;

  /// Decodes the map produced by the platform channel.
  ///
  /// Throws [FormatException] when the map is not a valid entry.
  factory ProxyEntry.fromMap(Map<Object?, Object?> map) {
    final typeName = map['type'];
    final type = switch (typeName) {
      'direct' => ProxyType.direct,
      'http' => ProxyType.http,
      'https' => ProxyType.https,
      'socks4' => ProxyType.socks4,
      'socks5' => ProxyType.socks5,
      'socks' => ProxyType.socks,
      _ => throw FormatException('Unknown proxy type', typeName),
    };
    if (type == ProxyType.direct) return ProxyEntry.direct;
    final host = map['host'];
    final port = map['port'];
    if (host is! String || host.isEmpty || port is! int || port <= 0) {
      throw FormatException('Proxy entry needs a host and a port', map);
    }
    String? nonEmpty(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    return ProxyEntry(
      type: type,
      host: _stripBrackets(host),
      port: port,
      username: nonEmpty(map['username']),
      password: nonEmpty(map['password']),
    );
  }

  /// Encodes this entry as a map (the inverse of [ProxyEntry.fromMap]).
  Map<String, Object?> toMap() => {
    'type': type.name,
    if (host != null) 'host': host,
    if (port != null) 'port': port,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
  };

  /// `host:port`, with IPv6 literals in brackets. `null` for DIRECT.
  String? get hostPort {
    if (isDirect) return null;
    final h = host!;
    return h.contains(':') ? '[$h]:$port' : '$h:$port';
  }

  /// This entry as a single `HttpClient.findProxy` directive
  /// (`DIRECT` or `PROXY host:port`), or `null` when `dart:io` cannot use it.
  ///
  /// Credentials are embedded as `user:password@host:port` only when both are
  /// present and [includeCredentials] is true, and only if they contain no
  /// characters that the `dart:io` parser would mis-split (`;` and `@` in the
  /// user name, `;` in the password).
  String? toFindProxyDirective({bool includeCredentials = true}) {
    switch (type) {
      case ProxyType.direct:
        return 'DIRECT';
      case ProxyType.http:
        final user = username;
        final pass = password;
        final safeCredentials =
            includeCredentials &&
            user != null &&
            pass != null &&
            user.isNotEmpty &&
            pass.isNotEmpty &&
            !user.contains(RegExp('[;:@]')) &&
            !pass.contains(';');
        return safeCredentials
            ? 'PROXY $user:$pass@$hostPort'
            : 'PROXY $hostPort';
      case ProxyType.https:
      case ProxyType.socks4:
      case ProxyType.socks5:
      case ProxyType.socks:
        return null;
    }
  }

  /// Formats [entries] in `HttpClient.findProxy` syntax, e.g.
  /// `PROXY proxy.corp:8080; DIRECT`.
  ///
  /// Entries `dart:io` cannot use (SOCKS, HTTPS-to-proxy) are skipped. When
  /// nothing usable remains, [fallback] is returned (default `DIRECT`).
  static String toFindProxyString(
    Iterable<ProxyEntry> entries, {
    String fallback = 'DIRECT',
    bool includeCredentials = true,
  }) {
    final directives = <String>[];
    for (final entry in entries) {
      final directive = entry.toFindProxyDirective(
        includeCredentials: includeCredentials,
      );
      if (directive != null && !directives.contains(directive)) {
        directives.add(directive);
      }
    }
    return directives.isEmpty ? fallback : directives.join('; ');
  }

  static String _stripBrackets(String host) =>
      host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;

  @override
  bool operator ==(Object other) =>
      other is ProxyEntry &&
      other.type == type &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(type, host, port, username, password);

  @override
  String toString() => switch (type) {
    ProxyType.direct => 'DIRECT',
    ProxyType.http => 'PROXY $hostPort',
    ProxyType.https => 'HTTPS $hostPort',
    ProxyType.socks4 => 'SOCKS4 $hostPort',
    ProxyType.socks5 => 'SOCKS5 $hostPort',
    ProxyType.socks => 'SOCKS $hostPort',
  };
}

/// The outcome of resolving the proxy for one URL.
@immutable
class ProxyResolution {
  /// Creates a resolution result.
  ProxyResolution({
    required this.uri,
    required List<ProxyEntry> entries,
    required this.source,
    required this.resolvedAt,
    this.pacUrl,
    this.error,
  }) : entries = List.unmodifiable(
         entries.isEmpty ? const [ProxyEntry.direct] : entries,
       );

  /// The URL that was resolved.
  final Uri uri;

  /// The ordered routes to try. Never empty: a resolution with no proxy
  /// contains a single [ProxyEntry.direct].
  final List<ProxyEntry> entries;

  /// How the decision was made.
  final ProxySource source;

  /// The PAC script URL, when the configuration uses one and the platform
  /// reports it.
  final Uri? pacUrl;

  /// A non-fatal problem, e.g. a PAC download that failed or timed out. When
  /// set, [entries] is the best available fallback (often DIRECT).
  final String? error;

  /// When the decision was produced.
  final DateTime resolvedAt;

  /// Whether the resolution succeeded without errors.
  bool get isSuccess => error == null;

  /// [entries] in `HttpClient.findProxy` syntax.
  /// See [ProxyEntry.toFindProxyString].
  String toFindProxyString({String fallback = 'DIRECT'}) =>
      ProxyEntry.toFindProxyString(entries, fallback: fallback);

  @override
  String toString() =>
      'ProxyResolution($uri -> ${entries.join('; ')}, source: ${source.name}'
      '${pacUrl != null ? ', pac: $pacUrl' : ''}'
      '${error != null ? ', error: $error' : ''})';
}
