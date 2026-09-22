/// `package:http` integration for `native_proxy_resolver`.
///
/// ```dart
/// import 'package:native_proxy_resolver/http.dart';
///
/// final client = createSystemProxyHttpClient();
/// final response = await client.get(Uri.parse('https://example.com'));
/// ```
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'src/http_client.dart';
import 'src/resolver.dart';

export 'src/http_client.dart' show ProxyAwareHttpClient;

/// Creates a `package:http` [http.Client] whose requests are routed through
/// the operating system's proxy for each URL (PAC / WPAD included).
///
/// It is an [IOClient] over a [ProxyAwareHttpClient] wrapping [inner] (a new
/// `HttpClient()` by default), so each request waits for the proxy of its
/// origin to be resolved (cached per [SystemProxyResolver.cacheTtl]).
/// Close the returned client when done.
http.Client createSystemProxyHttpClient({
  HttpClient? inner,
  SystemProxyResolver? resolver,
  String fallback = 'DIRECT',
  bool preResolve = true,
}) => IOClient(
  ProxyAwareHttpClient(
    inner: inner,
    resolver: resolver,
    fallback: fallback,
    preResolve: preResolve,
  ),
);
