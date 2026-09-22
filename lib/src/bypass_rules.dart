import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:meta/meta.dart';

/// Syntax family of a proxy bypass list.
enum BypassStyle {
  /// curl / wget style `no_proxy`: comma or space separated; `example.com`
  /// and `.example.com` both match the domain and all its sub-domains; `*`
  /// alone disables the proxy for everything; IP literals, CIDR blocks and
  /// an optional `:port` are supported.
  noProxy,

  /// Wildcard style used by Windows (`ProxyOverride`), Android exclusion lists
  /// and GNOME `ignore-hosts`: `;`, `,` or space separated glob patterns
  /// (`*.corp.example`, `10.*`), exact host names, CIDR blocks, and the
  /// Windows token `<local>` (host names without a dot).
  wildcard,
}

/// A parsed list of hosts that must be reached without a proxy.
@immutable
class ProxyBypassRules {
  const ProxyBypassRules._(this._rules, this.style);

  /// An empty rule list that bypasses nothing.
  static const ProxyBypassRules none = ProxyBypassRules._(
    <_Rule>[],
    BypassStyle.noProxy,
  );

  /// Parses [spec] according to [style]. Empty or malformed items are ignored.
  factory ProxyBypassRules.parse(
    String? spec, {
    BypassStyle style = BypassStyle.noProxy,
  }) {
    if (spec == null || spec.trim().isEmpty) return none;
    final separators = style == BypassStyle.noProxy
        ? RegExp(r'[,\s]+')
        : RegExp(r'[;,\s]+');
    final rules = <_Rule>[];
    for (final raw in spec.split(separators)) {
      final item = raw.trim();
      if (item.isEmpty) continue;
      final rule = style == BypassStyle.noProxy
          ? _parseNoProxy(item)
          : _parseWildcard(item);
      if (rule != null) rules.add(rule);
    }
    return ProxyBypassRules._(List.unmodifiable(rules), style);
  }

  /// Parses a list of individual patterns (e.g. an Android exclusion list or
  /// a GNOME `ignore-hosts` array).
  factory ProxyBypassRules.fromList(
    Iterable<String> patterns, {
    BypassStyle style = BypassStyle.wildcard,
  }) => ProxyBypassRules.parse(patterns.join(','), style: style);

  final List<_Rule> _rules;

  /// The syntax the rules were parsed with.
  final BypassStyle style;

  /// Whether there are no rules.
  bool get isEmpty => _rules.isEmpty;

  /// Whether requests to [uri] should skip the proxy.
  bool matches(Uri uri) {
    if (_rules.isEmpty || uri.host.isEmpty) return false;
    final host = _normalizeHost(uri.host);
    final port = uri.hasPort ? uri.port : _defaultPort(uri.scheme);
    final address = InternetAddress.tryParse(host);
    for (final rule in _rules) {
      if (rule.matches(host, port, address)) return true;
    }
    return false;
  }

  static int _defaultPort(String scheme) => switch (scheme) {
    'https' || 'wss' => 443,
    'http' || 'ws' => 80,
    'ftp' => 21,
    _ => 0,
  };

  static String _normalizeHost(String host) {
    var h = host.toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    return h;
  }

  static _Rule? _parseNoProxy(String item) {
    if (item == '*') return const _MatchAll();
    final (hostPart, port) = _splitPort(item);
    if (hostPart.isEmpty) return null;
    final cidr = _Cidr.tryParse(hostPart);
    if (cidr != null) return _PortRule(cidr, port);
    var host = _normalizeHost(hostPart);
    if (host.startsWith('*.')) host = host.substring(1);
    if (host.startsWith('.')) host = host.substring(1);
    if (host.isEmpty) return null;
    final address = InternetAddress.tryParse(host);
    if (address != null) return _PortRule(_Cidr.single(address), port);
    return _PortRule(_DomainSuffix(host), port);
  }

  static _Rule? _parseWildcard(String item) {
    if (item.toLowerCase() == '<local>') return const _SimpleHostname();
    if (item == '*') return const _MatchAll();
    final cidr = _Cidr.tryParse(item);
    if (cidr != null) return cidr;
    final (hostPart, port) = _splitPort(item);
    if (hostPart.isEmpty) return null;
    final host = _normalizeHost(hostPart);
    final address = InternetAddress.tryParse(host);
    if (address != null) return _PortRule(_Cidr.single(address), port);
    if (host.startsWith('.')) {
      // `.example.com` in wildcard lists means "any sub-domain".
      return _PortRule(_Glob('*$host'), port);
    }
    return _PortRule(_Glob(host), port);
  }

  /// Splits an optional trailing `:port`, leaving bare IPv6 literals intact.
  static (String, int?) _splitPort(String item) {
    if (item.startsWith('[')) {
      final close = item.indexOf(']');
      if (close < 0) return (item, null);
      final rest = item.substring(close + 1);
      final port = rest.startsWith(':')
          ? int.tryParse(rest.substring(1))
          : null;
      return (item.substring(1, close), port);
    }
    final colon = item.lastIndexOf(':');
    if (colon < 0 || item.indexOf(':') != colon) return (item, null);
    final port = int.tryParse(item.substring(colon + 1));
    if (port == null) return (item, null);
    return (item.substring(0, colon), port);
  }
}

abstract class _Rule {
  const _Rule();
  bool matches(String host, int port, InternetAddress? address);
}

class _MatchAll extends _Rule {
  const _MatchAll();
  @override
  bool matches(String host, int port, InternetAddress? address) => true;
}

class _SimpleHostname extends _Rule {
  const _SimpleHostname();
  @override
  bool matches(String host, int port, InternetAddress? address) =>
      address == null && !host.contains('.');
}

class _PortRule extends _Rule {
  const _PortRule(this.inner, this.port);
  final _Rule inner;
  final int? port;
  @override
  bool matches(String host, int port, InternetAddress? address) =>
      (this.port == null || this.port == port) &&
      inner.matches(host, port, address);
}

class _DomainSuffix extends _Rule {
  const _DomainSuffix(this.domain);
  final String domain;
  @override
  bool matches(String host, int port, InternetAddress? address) =>
      host == domain || host.endsWith('.$domain');
}

class _Glob extends _Rule {
  _Glob(String pattern)
    : _regex = RegExp(
        '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
        caseSensitive: false,
      );
  final RegExp _regex;
  @override
  bool matches(String host, int port, InternetAddress? address) =>
      _regex.hasMatch(host);
}

class _Cidr extends _Rule {
  _Cidr(this.network, this.prefixLength);

  factory _Cidr.single(InternetAddress address) =>
      _Cidr(address, address.rawAddress.length * 8);

  static _Cidr? tryParse(String item) {
    final slash = item.indexOf('/');
    if (slash < 0) return null;
    var addressPart = item.substring(0, slash);
    if (addressPart.startsWith('[') && addressPart.endsWith(']')) {
      addressPart = addressPart.substring(1, addressPart.length - 1);
    }
    final address = InternetAddress.tryParse(addressPart);
    final prefix = int.tryParse(item.substring(slash + 1));
    if (address == null || prefix == null) return null;
    final bits = address.rawAddress.length * 8;
    if (prefix < 0 || prefix > bits) return null;
    return _Cidr(address, prefix);
  }

  final InternetAddress network;
  final int prefixLength;

  @override
  bool matches(String host, int port, InternetAddress? address) {
    if (address == null) return false;
    var candidate = address;
    if (candidate.type != network.type) {
      // Allow IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) to match v4 rules.
      final raw = candidate.rawAddress;
      if (network.type == InternetAddressType.IPv4 &&
          raw.length == 16 &&
          raw.sublist(0, 10).every((b) => b == 0) &&
          raw[10] == 0xff &&
          raw[11] == 0xff) {
        candidate = InternetAddress.fromRawAddress(raw.sublist(12));
      } else {
        return false;
      }
    }
    final a = candidate.rawAddress;
    final b = network.rawAddress;
    var remaining = prefixLength;
    for (var i = 0; i < a.length && remaining > 0; i++) {
      final take = remaining >= 8 ? 8 : remaining;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((a[i] & mask) != (b[i] & mask)) return false;
      remaining -= take;
    }
    return true;
  }
}
