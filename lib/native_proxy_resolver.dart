/// Per-URL proxy resolution through the operating system — including PAC
/// scripts and WPAD auto-discovery — for `dart:io` `HttpClient`,
/// `package:http` and Dio.
///
/// Start with [SystemProxy.resolve], or make every `HttpClient` proxy-aware
/// with [SystemProxy.installHttpOverrides].
library;

export 'src/bypass_rules.dart' show BypassStyle, ProxyBypassRules;
export 'src/environment_proxy.dart' show EnvironmentProxyConfig;
export 'src/http_client.dart'
    show ProxyAwareHttpClient, SystemProxyHttpOverrides;
export 'src/linux.dart' show NativeProxyResolverLinux;
export 'src/method_channel.dart' show MethodChannelNativeProxyResolver;
export 'src/platform_interface.dart' show NativeProxyResolverPlatform;
export 'src/proxy_entry.dart'
    show ProxyEntry, ProxyResolution, ProxySource, ProxyType;
export 'src/proxy_list_parser.dart' show ProxyListParser;
export 'src/resolver.dart' show SystemProxyResolver;
export 'src/system_proxy.dart' show SystemProxy;
