import 'dart:async';
import 'dart:collection';

import 'platform_interface.dart';
import 'proxy_entry.dart';

/// Resolves proxies through the operating system, with an origin-keyed TTL
/// cache, request de-duplication and automatic invalidation on network or
/// proxy changes.
///
/// The cache key is the URL origin (`scheme://host:port`). PAC scripts may in
/// theory branch on the URL path; such rules are only re-evaluated once the
/// cached origin entry expires.
class SystemProxyResolver {
  /// Creates a resolver.
  ///
  /// * [cacheTtl]: how long a successful resolution is reused.
  /// * [errorTtl]: how long a failed resolution (native error or timeout) is
  ///   reused before retrying.
  /// * [timeout]: upper bound for one native resolution (PAC download and
  ///   evaluation, WPAD discovery).
  /// * [maxCacheEntries]: least-recently-used origins are evicted beyond this.
  /// * [invalidateOnChange]: clear the cache whenever [onChange] fires.
  SystemProxyResolver({
    NativeProxyResolverPlatform? platform,
    this.cacheTtl = const Duration(minutes: 5),
    this.errorTtl = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 10),
    this.maxCacheEntries = 256,
    this.invalidateOnChange = true,
    DateTime Function()? clock,
  }) : assert(maxCacheEntries > 0, 'maxCacheEntries must be positive'),
       _platform = platform,
       _clock = clock ?? DateTime.now;

  final NativeProxyResolverPlatform? _platform;
  final DateTime Function() _clock;

  /// How long a successful resolution is cached.
  final Duration cacheTtl;

  /// How long a failed resolution is cached.
  final Duration errorTtl;

  /// Upper bound for one native resolution.
  final Duration timeout;

  /// Maximum number of cached origins.
  final int maxCacheEntries;

  /// Whether change events clear the cache.
  final bool invalidateOnChange;

  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();
  final Map<String, Future<ProxyResolution>> _inFlight = {};
  StreamSubscription<void>? _changeSubscription;
  bool _disposed = false;
  int _generation = 0;

  NativeProxyResolverPlatform get _impl =>
      _platform ?? NativeProxyResolverPlatform.instance;

  /// Resolves the ordered proxy list for [uri]. Never empty; `[DIRECT]` when
  /// no proxy applies or resolution failed (see [resolveDetailed] for the
  /// reason).
  ///
  /// Throws [ArgumentError] if [uri] has no host.
  Future<List<ProxyEntry>> resolve(
    Uri uri, {
    bool forceRefresh = false,
  }) async => (await resolveDetailed(uri, forceRefresh: forceRefresh)).entries;

  /// Resolves [uri] and returns the full [ProxyResolution] (source, PAC URL,
  /// error). Served from the cache when a fresh entry exists unless
  /// [forceRefresh] is true.
  ///
  /// Throws [ArgumentError] if [uri] has no host, and [StateError] after
  /// [dispose].
  Future<ProxyResolution> resolveDetailed(
    Uri uri, {
    bool forceRefresh = false,
  }) {
    if (_disposed) throw StateError('SystemProxyResolver has been disposed');
    final key = cacheKey(uri);
    _ensureWatching();
    if (!forceRefresh) {
      final hit = _fresh(key);
      if (hit != null) return Future.value(hit);
      final pending = _inFlight[key];
      if (pending != null) return pending;
    }
    final target = _normalize(uri);
    final generation = _generation;
    Future<ProxyResolution>? self;
    final future = Future.sync(() => _impl.resolve(target, timeout: timeout))
        .onError<Object>(
          (error, _) => ProxyResolution(
            uri: target,
            entries: const [ProxyEntry.direct],
            source: ProxySource.unknown,
            resolvedAt: _clock(),
            error: 'Proxy resolver threw: $error',
          ),
          test: (error) => error is! Error,
        )
        .then((resolution) {
          // A change event during resolution makes this answer suspect:
          // return it to the caller but do not cache it.
          if (generation == _generation) _store(key, resolution);
          return resolution;
        })
        .whenComplete(() {
          if (identical(_inFlight[key], self)) _inFlight.remove(key);
        });
    self = future;
    _inFlight[key] = future;
    return future;
  }

  /// Resolves several URLs in parallel so later synchronous [findProxy]
  /// calls hit the cache.
  Future<void> warmUp(Iterable<Uri> uris) =>
      Future.wait(uris.map(resolveDetailed));

  /// The cached resolution for [uri]'s origin, or `null`. Expired entries are
  /// returned only when [allowStale] is true.
  ProxyResolution? cached(Uri uri, {bool allowStale = false}) {
    if (uri.host.isEmpty) return null;
    final key = cacheKey(uri);
    return allowStale ? _cache[key]?.resolution : _fresh(key);
  }

  /// A synchronous `HttpClient.findProxy`-compatible answer for [uri].
  ///
  /// Uses the cached resolution for the origin (a stale one if nothing fresh
  /// exists, so a request that was pre-resolved never falls back because the
  /// TTL expired in between). On a complete cache miss it returns [fallback]
  /// and, when [resolveOnMiss] is true, starts an asynchronous resolution so
  /// the next request to the origin is routed correctly.
  ///
  /// Also refreshes stale entries in the background.
  String findProxy(
    Uri uri, {
    String fallback = 'DIRECT',
    bool resolveOnMiss = true,
  }) {
    if (uri.host.isEmpty || _disposed) return fallback;
    final key = cacheKey(uri);
    final fresh = _fresh(key);
    if (fresh != null) return fresh.toFindProxyString(fallback: fallback);
    if (resolveOnMiss) {
      unawaited(resolveDetailed(uri).then((_) {}, onError: (Object _) {}));
    }
    final stale = _cache[key]?.resolution;
    return stale?.toFindProxyString(fallback: fallback) ?? fallback;
  }

  /// A closure suitable for `HttpClient.findProxy`.
  String Function(Uri) findProxyCallback({String fallback = 'DIRECT'}) =>
      (uri) => findProxy(uri, fallback: fallback);

  /// Removes every cached resolution.
  void clearCache() {
    _generation++;
    _cache.clear();
    _inFlight.clear();
  }

  /// Number of cached origins (fresh or stale).
  int get cacheSize => _cache.length;

  /// Emits when the platform reports a network or proxy change (see
  /// [NativeProxyResolverPlatform.supportsChangeEvents]).
  Stream<void> get onChange => _impl.onChange;

  /// Whether [onChange] delivers events on this platform.
  bool get supportsChangeEvents => _impl.supportsChangeEvents;

  /// Stops listening for change events and clears the cache. The resolver
  /// cannot be used afterwards.
  Future<void> dispose() async {
    _disposed = true;
    _cache.clear();
    await _changeSubscription?.cancel();
    _changeSubscription = null;
  }

  /// The cache key for [uri]: `scheme://host:port` with `ws`/`wss` folded
  /// into `http`/`https`.
  ///
  /// Throws [ArgumentError] if [uri] has no host.
  static String cacheKey(Uri uri) {
    final n = _normalize(uri);
    return '${n.scheme}://${n.host.toLowerCase()}:${n.port}';
  }

  static Uri _normalize(Uri uri) {
    if (uri.host.isEmpty) {
      throw ArgumentError.value(uri, 'uri', 'must be absolute with a host');
    }
    final scheme = switch (uri.scheme.toLowerCase()) {
      'ws' => 'http',
      'wss' => 'https',
      '' => 'http',
      final s => s,
    };
    if (scheme == uri.scheme) return uri;
    return uri.replace(
      scheme: scheme,
      port: uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80),
    );
  }

  ProxyResolution? _fresh(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    final ttl = entry.resolution.isSuccess ? cacheTtl : errorTtl;
    if (_clock().difference(entry.storedAt) >= ttl) return null;
    // Refresh LRU position.
    _cache.remove(key);
    _cache[key] = entry;
    return entry.resolution;
  }

  void _store(String key, ProxyResolution resolution) {
    if (_disposed) return;
    _cache.remove(key);
    _cache[key] = _CacheEntry(resolution, _clock());
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void _ensureWatching() {
    if (!invalidateOnChange || _changeSubscription != null) return;
    if (!_impl.supportsChangeEvents) return;
    _changeSubscription = _impl.onChange.listen(
      (_) => clearCache(),
      onError: (Object _) {},
    );
  }
}

class _CacheEntry {
  const _CacheEntry(this.resolution, this.storedAt);
  final ProxyResolution resolution;
  final DateTime storedAt;
}
