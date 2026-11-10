## 0.1.3

* README and pub.dev screenshots: the demo GIF (resolving https://flutterdev.in/) replaces the older example.com screenshot. No code changes.

## 0.1.2

* README: demo GIF.
* README samples, API docs and the example app use https://flutterdev.in instead of example.com. No code changes.

## 0.1.1

* Homepage and README now link to the package's documentation page on flutterdev.in. No code changes.

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
