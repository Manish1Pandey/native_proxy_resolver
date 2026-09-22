// Dio integration for native_proxy_resolver.
//
// The plugin does not depend on Dio. Copy this file into an app that already
// uses Dio (5.x) to route its requests through the OS proxy (PAC / WPAD
// included).
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

/// Creates a [Dio] whose adapter builds a [ProxyAwareHttpClient], so each
/// request waits for the OS proxy decision for its origin.
Dio createSystemProxyDio({
  SystemProxyResolver? resolver,
  BaseOptions? options,
}) {
  final dio = Dio(options);
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => ProxyAwareHttpClient(resolver: resolver),
  );
  return dio;
}
