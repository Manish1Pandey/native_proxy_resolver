# native_proxy_resolver — Specification

## Purpose

Dart's `HttpClient` ignores the operating system's proxy configuration
([flutter/flutter#26359](https://github.com/flutter/flutter/issues/26359)).
On corporate networks the proxy is usually not a single static `host:port`
but a PAC script (Proxy Auto-Config) or WPAD auto-discovery, which picks a
proxy per URL. Existing packages only read a static proxy.

`native_proxy_resolver` asks the **operating system's own proxy resolver** which
proxies to use for a given URL, so PAC and WPAD are honoured exactly like the
platform's native networking stack honours them, and provides adapters that
feed the answer into `dart:io` `HttpClient`, `package:http` and Dio.

## Functional requirements

| ID | Requirement |
|----|-------------|
| FR1 | `SystemProxy.resolve(Uri)` returns an ordered `List<ProxyEntry>`; each entry is `DIRECT`, an HTTP proxy, an HTTPS (TLS-to-proxy) proxy or a SOCKS(4/5) proxy with host and port. |
| FR2 | `SystemProxy.resolveDetailed(Uri)` also returns where the answer came from (`pac`, `autoDetect`, `manual`, `environment`, `none`), the PAC URL when known and any non-fatal error. |
| FR3 | Resolution never throws for resolver failures: on native error or timeout the result is `[DIRECT]` with `error` set. Invalid input (a URI without a host) throws `ArgumentError`. |
| FR4 | iOS/macOS: `CFNetworkCopySystemProxySettings` + `CFNetworkCopyProxiesForURL`; entries of type AutoConfigurationURL / AutoConfigurationJavaScript are executed with `CFNetworkExecuteProxyAutoConfigurationURL` / `...Script` on a background run loop in a private mode, bounded by a timeout. |
| FR5 | Android: `ProxySelector.getDefault().select(URI)`, completed by `ConnectivityManager.getDefaultProxy()`; for PAC configurations the system's local PAC proxy (`ProxyInfo.getPacFileUrl` + localhost port) is returned, with the exclusion list applied for static proxies. |
| FR6 | Windows: `WinHttpGetIEProxyConfigForCurrentUser`; when auto-detect or an auto-config URL is set, `WinHttpGetProxyForUrl` (WPAD DHCP+DNS and/or PAC URL, retrying with auto-logon); falls back to the manual proxy + bypass list. Runs on a worker thread; results are marshalled back to the platform thread. |
| FR7 | Linux: `http_proxy`/`https_proxy`/`all_proxy`/`no_proxy` (either case) first; otherwise GNOME `gsettings org.gnome.system.proxy` (manual hosts, ignore-hosts). PAC (`mode 'auto'`) is reported honestly (`source: pac`, `pacUrl`, `error`) and resolves to DIRECT. |
| FR8 | Results are cached per origin (`scheme://host:port`) with a TTL (default 5 min, errors 30 s), bounded size (LRU), and concurrent lookups for the same origin are de-duplicated. |
| FR9 | `SystemProxy.onChange` emits when the network or proxy configuration changes (Android, iOS, macOS, Linux/GNOME); the cache is invalidated automatically. |
| FR10 | `ProxyEntry.toFindProxyString(entries)` formats the list in `HttpClient.findProxy` syntax (`PROXY host:port; DIRECT`), bracketing IPv6, adding credentials only when safe, skipping entries `dart:io` cannot use (SOCKS, HTTPS-to-proxy). |
| FR11 | `ProxyAwareHttpClient` wraps an `HttpClient`: every `open*`/`get`/`post`/… call awaits `resolve()` first (pre-resolving strategy), so the synchronous `findProxy` callback then reads a warm cache. `SystemProxyHttpOverrides` installs it process-wide. |
| FR12 | `package:native_proxy_resolver/http.dart` gives a `package:http` `Client` (`IOClient` over `ProxyAwareHttpClient`). The example app shows a Dio adapter without making Dio a dependency of the package. |
| FR13 | No-proxy / bypass rules: curl-style `no_proxy` (suffix domains, `*`, IPs, CIDR, ports) and wildcard style (Windows `<local>`, `*.corp`, `10.*`, GNOME/Android exclusion lists). |

## Can / Cannot

| Can | Cannot |
|-----|--------|
| Evaluate PAC scripts and WPAD on iOS, macOS, Windows through the OS | Evaluate PAC on Linux (no system PAC engine; reported as an error, resolves DIRECT) |
| Use Android's system PAC proxy (the OS runs the PAC in its local proxy) | Return the individual PAC decision on Android — Android hides it behind `localhost:<port>` |
| Report SOCKS proxies from the OS | Make `dart:io` `HttpClient` speak SOCKS or TLS-to-proxy (`HTTPS` PAC directive); those entries are skipped in `findProxy` strings |
| Resolve asynchronously before each request (ProxyAwareHttpClient) | Resolve inside the synchronous `findProxy` callback itself — a cache miss there (e.g. a redirect to a new host) uses the fallback (`DIRECT` by default) and warms the cache in the background |
| Cache by origin with TTL and change-driven invalidation | Honour PAC rules that branch on URL *path* within the TTL (cache key is the origin) |
| Pass proxy usernames supplied by the OS | Read proxy passwords from the macOS/iOS keychain or Windows credential store; use `HttpClient.addProxyCredentials` |
| Watch changes on Android, iOS, macOS, Linux (GNOME) | Watch changes on Windows (TTL expiry is used instead) |
| Run in the main isolate, or background isolates after `BackgroundIsolateBinaryMessenger.ensureInitialized` | Work on the web (the browser applies its own proxy; not a supported platform) |

## Public API sketch

```dart
enum ProxyType { direct, http, https, socks4, socks5, socks }
enum ProxySource { pac, autoDetect, manual, environment, none, unknown }

class ProxyEntry { ProxyType type; String? host; int? port; String? username; String? password;
  String? toFindProxyDirective(); static String toFindProxyString(List<ProxyEntry>, {String fallback}); }
class ProxyResolution { Uri uri; List<ProxyEntry> entries; ProxySource source; Uri? pacUrl; String? error; DateTime resolvedAt; }
class ProxyBypassRules { factory ProxyBypassRules.parse(String, {BypassStyle style}); bool matches(Uri); }
class EnvironmentProxyConfig { factory EnvironmentProxyConfig.fromEnvironment(Map<String,String>); List<ProxyEntry>? entriesFor(Uri); }

class SystemProxyResolver { resolve(), resolveDetailed(), findProxy(), warmUp(), cached(), clearCache(), onChange, dispose() }
abstract final class SystemProxy { static resolve/resolveDetailed/findProxy/warmUp/clearCache/onChange/installHttpOverrides, resolver }
class ProxyAwareHttpClient implements HttpClient { ProxyAwareHttpClient(HttpClient inner, {resolver, fallback, preResolve}); }
class SystemProxyHttpOverrides extends HttpOverrides {}
// package:native_proxy_resolver/http.dart
http.Client createSystemProxyHttpClient({...});
```

## Platform matrix

| Platform | Mechanism | PAC | WPAD | Change events |
|----------|-----------|-----|------|---------------|
| Android (API 24+) | Kotlin: `ProxySelector` + `ConnectivityManager.getDefaultProxy` | Yes (via system local PAC proxy) | Via OS PAC proxy where the OS supports it | Yes (`NetworkCallback` + `PROXY_CHANGE` broadcast) |
| iOS 13+ | Swift: CFNetwork | Yes | Yes (as delivered by CFNetwork) | Network path changes (`NWPathMonitor`) |
| macOS 10.15+ | Swift: CFNetwork | Yes | Yes | Yes (`SCDynamicStore` proxies key + `NWPathMonitor`) |
| Windows 10+ | C++: WinHTTP | Yes | Yes (DHCP + DNS) | No (TTL) |
| Linux | Dart: env vars + GNOME `gsettings` | No (reported) | No | GNOME via `gsettings monitor` |
| Web | — | — | — | Not supported |
