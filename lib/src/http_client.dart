import 'dart:async';
import 'dart:io';

import 'resolver.dart';
import 'system_proxy.dart';

/// An [HttpClient] that routes every request through the proxy the operating
/// system chooses for its URL (including PAC / WPAD).
///
/// `HttpClient.findProxy` is a *synchronous* callback, while asking the OS is
/// asynchronous. This client bridges the gap with a **pre-resolving**
/// strategy: each `open*` / `get` / `post` / … call first awaits
/// [SystemProxyResolver.resolveDetailed] for the URL's origin, then opens the
/// request on the wrapped client, whose `findProxy` reads the now-warm cache.
///
/// Trade-offs:
/// * The first request to an origin waits for the OS (usually < 1 ms for a
///   static configuration; a PAC download or WPAD lookup can take longer,
///   bounded by [SystemProxyResolver.timeout]). Later requests within the
///   TTL are not delayed.
/// * Redirects are followed inside `dart:io` and only call the synchronous
///   callback; a redirect to a not-yet-resolved origin uses [fallback]
///   (default `DIRECT`) and warms the cache in the background. Set
///   `request.followRedirects = false` and re-issue redirects yourself if
///   every hop must use its PAC decision.
/// * `dart:io` only speaks HTTP proxies: SOCKS and HTTPS-to-proxy entries are
///   skipped (see `ProxyEntry.toFindProxyString`).
///
/// Setting [findProxy] explicitly disables the system resolution for this
/// client and uses the given callback instead.
class ProxyAwareHttpClient implements HttpClient {
  /// Wraps [inner] (a fresh `HttpClient()` by default; note that a fresh
  /// client honours `HttpOverrides.current`).
  ///
  /// * [resolver]: the resolver to use; defaults to [SystemProxy.resolver].
  /// * [fallback]: `findProxy` answer when an origin has not been resolved.
  /// * [preResolve]: when false, requests are not delayed; `findProxy` uses
  ///   whatever is cached and resolves misses in the background (the
  ///   "warmed cache" strategy — pair it with [SystemProxyResolver.warmUp]).
  ProxyAwareHttpClient({
    HttpClient? inner,
    SystemProxyResolver? resolver,
    this.fallback = 'DIRECT',
    this.preResolve = true,
  }) : _inner = inner ?? HttpClient(),
       _resolver = resolver {
    _inner.findProxy = _findProxy;
  }

  final HttpClient _inner;
  final SystemProxyResolver? _resolver;
  bool _customFindProxy = false;

  /// The `findProxy` answer used when an origin has not been resolved yet.
  final String fallback;

  /// Whether requests wait for the proxy resolution of their origin.
  final bool preResolve;

  /// The client that performs the requests.
  HttpClient get inner => _inner;

  SystemProxyResolver get _activeResolver => _resolver ?? SystemProxy.resolver;

  String _findProxy(Uri url) =>
      _activeResolver.findProxy(url, fallback: fallback);

  Future<void> _prepare(Uri url) async {
    if (!preResolve || _customFindProxy || url.host.isEmpty) return;
    await _activeResolver.resolveDetailed(url);
  }

  Future<HttpClientRequest> _openAfterResolve(
    Uri target,
    Future<HttpClientRequest> Function() open,
  ) async {
    await _prepare(target);
    return open();
  }

  static Uri _hostUri(String host, int port) =>
      Uri(scheme: 'http', host: host, port: port);

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _openAfterResolve(
    _hostUri(host, port),
    () => _inner.open(method, host, port, path),
  );

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _openAfterResolve(url, () => _inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _openAfterResolve(
        _hostUri(host, port),
        () => _inner.get(host, port, path),
      );

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _openAfterResolve(url, () => _inner.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _openAfterResolve(
        _hostUri(host, port),
        () => _inner.post(host, port, path),
      );

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _openAfterResolve(url, () => _inner.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _openAfterResolve(
        _hostUri(host, port),
        () => _inner.put(host, port, path),
      );

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _openAfterResolve(url, () => _inner.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _openAfterResolve(
        _hostUri(host, port),
        () => _inner.delete(host, port, path),
      );

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _openAfterResolve(url, () => _inner.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _openAfterResolve(
        _hostUri(host, port),
        () => _inner.patch(host, port, path),
      );

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _openAfterResolve(url, () => _inner.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _openAfterResolve(
        _hostUri(host, port),
        () => _inner.head(host, port, path),
      );

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _openAfterResolve(url, () => _inner.headUrl(url));

  @override
  set findProxy(String Function(Uri url)? f) {
    _customFindProxy = f != null;
    _inner.findProxy = f ?? _findProxy;
  }

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// [HttpOverrides] that make every `HttpClient()` created in the zone (or
/// globally, via `HttpOverrides.global`) a [ProxyAwareHttpClient].
///
/// This covers code you do not control that creates its own `HttpClient`,
/// e.g. `package:http`'s default client on the VM, `NetworkImage` and most
/// SDKs. Install it with [SystemProxy.installHttpOverrides].
class SystemProxyHttpOverrides extends HttpOverrides {
  /// Creates the overrides. [previous] (typically the value of
  /// `HttpOverrides.current` before installing) is used to create the
  /// underlying client, so existing overrides keep working.
  SystemProxyHttpOverrides({
    this.resolver,
    this.fallback = 'DIRECT',
    this.preResolve = true,
    this.previous,
  });

  /// The resolver to use; `null` means [SystemProxy.resolver].
  final SystemProxyResolver? resolver;

  /// See [ProxyAwareHttpClient.fallback].
  final String fallback;

  /// See [ProxyAwareHttpClient.preResolve].
  final bool preResolve;

  /// Overrides that were active before these, used to build the inner
  /// client.
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return ProxyAwareHttpClient(
      inner: inner,
      resolver: resolver,
      fallback: fallback,
      preResolve: preResolve,
    );
  }
}
