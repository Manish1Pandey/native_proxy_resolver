# native_proxy_resolver

Resolve the **operating system's proxy for each URL** — including **PAC
scripts and WPAD auto-discovery** used on corporate networks — and plug the
answer into `dart:io` `HttpClient`, `package:http` and Dio.

<img src="https://raw.githubusercontent.com/Manish1Pandey/native_proxy_resolver/main/screenshots/ios_resolve_direct.png" width="300" alt="Example app on the iOS simulator: https://example.com/ resolves to DIRECT (source none) and ProxyAwareHttpClient gets HTTP 200">

## Why

Dart's `HttpClient` ignores the OS proxy settings
([flutter/flutter#26359](https://github.com/flutter/flutter/issues/26359)).
Existing packages only read one static `host:port` (`system_proxy` is
unmaintained since 2021, `native_flutter_proxy` is static only). In a company
network the proxy is usually chosen per URL by a PAC script, so a static value
is wrong for half the hosts. This plugin asks the OS resolver itself, so your
app routes exactly like the platform's native networking stack.

## Install

```yaml
dependencies:
  native_proxy_resolver: ^0.1.0
```

## Usage

### Resolve a URL

```dart
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

final proxies = await SystemProxy.resolve(Uri.parse('https://example.com'));
// [PROXY proxy.corp:8080, DIRECT]   or   [DIRECT]

final detail = await SystemProxy.resolveDetailed(Uri.parse('https://example.com'));
print(detail.source);   // pac, autoDetect, manual, environment, none
print(detail.pacUrl);   // http://wpad.corp/wpad.dat
print(detail.error);    // e.g. "PAC evaluation timed out" (entries fall back to DIRECT)
print(detail.toFindProxyString()); // "PROXY proxy.corp:8080; DIRECT"
```

Resolution never throws for resolver failures: you get `[DIRECT]` plus
`error`. Results are cached per origin (`scheme://host:port`, TTL 5 min,
failures 30 s, 256 origins LRU) and concurrent lookups share one native call.
Tune it with your own resolver:

```dart
SystemProxy.resolver = SystemProxyResolver(
  cacheTtl: const Duration(minutes: 2),
  timeout: const Duration(seconds: 5),
);
SystemProxy.onChange.listen((_) => print('network or proxy changed'));
```

### dart:io HttpClient

`HttpClient.findProxy` is a **synchronous** callback, but asking the OS (and
running a PAC script) is asynchronous. `ProxyAwareHttpClient` solves this with
**pre-resolution**: every `getUrl`/`openUrl`/`post`/… first awaits the proxy
decision for the URL's origin, then opens the request on the wrapped client,
whose `findProxy` reads the now-warm cache.

```dart
final client = ProxyAwareHttpClient();            // wraps HttpClient()
final response = await (await client.getUrl(url)).close();
```

Or make **every** `HttpClient()` in the app proxy-aware (covers SDKs,
`NetworkImage`, `package:http`'s default client on the VM…):

```dart
void main() {
  SystemProxy.installHttpOverrides();
  runApp(const MyApp());
}
```

Trade-offs you should know:

| Strategy | How | Cost |
|----------|-----|------|
| Pre-resolve (default) | `ProxyAwareHttpClient()` | First request to an origin waits for the OS (≈ instant for static config; PAC download/WPAD bounded by `timeout`). |
| Warmed cache | `ProxyAwareHttpClient(preResolve: false)` + `SystemProxy.warmUp([...])` | No waiting; a not-yet-warmed origin uses `fallback` (`DIRECT`) once and is resolved in the background. |
| Plain callback | `client.findProxy = SystemProxy.resolver.findProxyCallback()` | Same as warmed cache, for a client you already own. |

Redirects are followed inside `dart:io` and only hit the synchronous callback;
a redirect to a never-seen origin uses `fallback` for that hop. Set
`request.followRedirects = false` if every hop must use its PAC decision.

### package:http

```dart
import 'package:native_proxy_resolver/http.dart';

final client = createSystemProxyHttpClient();
final response = await client.get(Uri.parse('https://example.com'));
client.close();
```

### Dio

The package does **not** depend on Dio. Copy
[`example/lib/dio_integration.dart`](example/lib/dio_integration.dart):

```dart
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

Dio createSystemProxyDio({SystemProxyResolver? resolver}) {
  final dio = Dio();
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => ProxyAwareHttpClient(resolver: resolver),
  );
  return dio;
}
```

### Helpers

* `ProxyEntry.toFindProxyString(entries)` — `PROXY host:port; DIRECT` syntax.
* `ProxyBypassRules.parse(spec, style: BypassStyle.noProxy | wildcard)` —
  curl-style `no_proxy` (suffixes, `*`, IPs, CIDR, ports) and Windows /
  Android / GNOME exclusion lists (`<local>`, globs, CIDR).
* `EnvironmentProxyConfig.fromEnvironment(Platform.environment)`.
* `ProxyListParser.parsePacResult` / `parseServerList` / `parseProxyUrl`.

## Platform support

| Platform | Mechanism | PAC | WPAD | Change events |
|----------|-----------|-----|------|---------------|
| Android 7+ (API 24) | `ProxySelector.select(URI)` + `ConnectivityManager.getDefaultProxy()` | Yes — via Android's local PAC proxy (`localhost:<port>`) | Where the OS supports it | Yes |
| iOS 13+ | `CFNetworkCopyProxiesForURL`; PAC run with `CFNetworkExecuteProxyAutoConfigurationURL/Script` on a background run loop with timeout | Yes | Yes | Network path changes |
| macOS 10.15+ | same as iOS | Yes | Yes | Yes (`SCDynamicStore` proxies key + path) |
| Windows 10+ | `WinHttpGetIEProxyConfigForCurrentUser` + `WinHttpGetProxyForUrl` (auto-detect DHCP/DNS, PAC URL, auto-logon retry), worker thread | Yes | Yes | No — cache TTL |
| Linux | `http_proxy`/`https_proxy`/`all_proxy`/`no_proxy`, else GNOME `gsettings` | **No** (reported) | **No** | GNOME (`gsettings monitor`) |
| Web | not supported (the browser applies its own proxy) | | | |

macOS apps need the `com.apple.security.network.client` entitlement to
download PAC scripts from inside the sandbox. Android adds
`ACCESS_NETWORK_STATE` to your manifest.

## Limitations

* **Linux has no PAC engine**: a GNOME `auto` configuration resolves to
  `DIRECT` with `source: pac`, `pacUrl` and an explanatory `error`.
* **Android** hides the individual PAC decision behind its local PAC proxy,
  so PAC networks report `PROXY localhost:<port>`.
* `dart:io` can only use HTTP proxies. SOCKS and `HTTPS` (TLS-to-proxy)
  entries are returned by `resolve` but skipped in `findProxy` strings.
* The cache key is the origin; PAC rules that branch on the URL path are
  re-evaluated only when the entry expires.
* Proxy passwords held in the Keychain / Windows credential store are not
  read; use `HttpClient.addProxyCredentials` / `authenticateProxy`.
* Windows has no change notification (entries expire after the TTL).
* Uses platform channels: call from the root isolate, or run
  `BackgroundIsolateBinaryMessenger.ensureInitialized` first.

## Example

[`example/`](example/) resolves any URL, shows source/PAC/errors, fetches it
through `ProxyAwareHttpClient`, `package:http`, Dio and a plain `HttpClient()`
with the global overrides toggled, and lists change events.

## Links

- **Documentation:** [flutterdev.in/packages/native_proxy_resolver](https://flutterdev.in/packages/native_proxy_resolver/)
- **More Flutter packages:** [flutterdev.in](https://flutterdev.in)
- **Learn data structures & algorithms in Dart:** [Algoistan](https://algoistan.flutterdev.in)
