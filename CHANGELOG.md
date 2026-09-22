## 0.1.0

* Initial release.
* `SystemProxy.resolve(Uri)` / `resolveDetailed` — per-URL proxy resolution
  through the OS: CFNetwork with PAC execution (iOS, macOS), `ProxySelector` +
  `ConnectivityManager.getDefaultProxy` incl. the system PAC proxy (Android),
  WinHTTP with WPAD and PAC (Windows), environment variables + GNOME
  `gsettings` (Linux, no PAC evaluation).
* Origin-keyed TTL cache with LRU bound, request de-duplication and
  invalidation on network / proxy change events (Android, iOS, macOS, GNOME).
* `ProxyAwareHttpClient`, `SystemProxyHttpOverrides`,
  `SystemProxy.installHttpOverrides()` for `dart:io`.
* `package:native_proxy_resolver/http.dart` — `createSystemProxyHttpClient()` for
  `package:http`; Dio adapter shown in the example.
* `ProxyBypassRules` (no_proxy and wildcard styles), `ProxyListParser`,
  `EnvironmentProxyConfig`.
