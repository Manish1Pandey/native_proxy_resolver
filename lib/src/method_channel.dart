import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bypass_rules.dart';
import 'platform_interface.dart';
import 'proxy_entry.dart';
import 'proxy_list_parser.dart';

/// The [NativeProxyResolverPlatform] used on Android, iOS, macOS and Windows: it
/// talks to the native resolver over a [MethodChannel].
///
/// Wire format of the `resolve` reply (all keys optional):
/// * `entries`: list of `{type, host, port, username, password}` maps,
/// * `proxyList` / `proxyBypass`: a Windows-style server list and bypass list
///   that are parsed and matched in Dart (used by Windows and by Android's
///   static-proxy fallback),
/// * `source`: a [ProxySource] name, `pacUrl`, `error`.
class MethodChannelNativeProxyResolver extends NativeProxyResolverPlatform {
  /// Creates the channel-based implementation.
  MethodChannelNativeProxyResolver({
    @visibleForTesting TargetPlatform? targetPlatform,
    @visibleForTesting DateTime Function()? clock,
  }) : _targetPlatform = targetPlatform,
       _clock = clock ?? DateTime.now;

  final TargetPlatform? _targetPlatform;
  final DateTime Function() _clock;

  /// The method channel used to resolve proxies.
  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel(
    'dev.manishpanday/native_proxy_resolver',
  );

  /// The event channel that reports network / proxy changes.
  @visibleForTesting
  static const EventChannel eventChannel = EventChannel(
    'dev.manishpanday/native_proxy_resolver/changes',
  );

  /// Extra time allowed for the channel round-trip beyond the native timeout.
  static const Duration _channelSlack = Duration(seconds: 2);

  Stream<void>? _changes;

  @override
  Future<ProxyResolution> resolve(Uri uri, {required Duration timeout}) async {
    try {
      final reply = await methodChannel
          .invokeMapMethod<Object?, Object?>('resolve', {
            'url': uri.toString(),
            'timeoutMs': timeout.inMilliseconds,
          })
          .timeout(timeout + _channelSlack);
      return decodeReply(uri, reply ?? const {}, _clock());
    } on TimeoutException {
      return _failure(uri, 'Proxy resolution timed out after $timeout');
    } on PlatformException catch (e) {
      return _failure(uri, 'Native resolver failed: ${e.code} ${e.message}');
    } on MissingPluginException {
      return _failure(
        uri,
        'native_proxy_resolver is not registered on this platform',
      );
    }
  }

  ProxyResolution _failure(Uri uri, String error) => ProxyResolution(
    uri: uri,
    entries: const [ProxyEntry.direct],
    source: ProxySource.unknown,
    resolvedAt: _clock(),
    error: error,
  );

  /// Converts a native reply into a [ProxyResolution] (exposed for tests).
  @visibleForTesting
  static ProxyResolution decodeReply(
    Uri uri,
    Map<Object?, Object?> reply,
    DateTime now,
  ) {
    final errors = <String>[];
    final nativeError = reply['error'];
    if (nativeError is String && nativeError.isNotEmpty) {
      errors.add(nativeError);
    }
    var entries = <ProxyEntry>[];
    final rawEntries = reply['entries'];
    if (rawEntries is List) {
      for (final raw in rawEntries) {
        if (raw is! Map) continue;
        try {
          entries.add(ProxyEntry.fromMap(raw));
        } on FormatException catch (e) {
          errors.add('Ignored malformed proxy entry: ${e.message}');
        }
      }
    }
    final proxyList = reply['proxyList'];
    if (entries.isEmpty && proxyList is String && proxyList.trim().isNotEmpty) {
      final bypassSpec = reply['proxyBypass'];
      final bypass = ProxyBypassRules.parse(
        bypassSpec is String ? bypassSpec : null,
        style: BypassStyle.wildcard,
      );
      entries = bypass.matches(uri)
          ? const [ProxyEntry.direct]
          : ProxyListParser.parseServerList(proxyList, uri);
    }
    final pac = reply['pacUrl'];
    return ProxyResolution(
      uri: uri,
      entries: entries,
      source: ProxySource.fromName(reply['source'] as String?),
      pacUrl: pac is String && pac.isNotEmpty ? Uri.tryParse(pac) : null,
      error: errors.isEmpty ? null : errors.join('; '),
      resolvedAt: now,
    );
  }

  @override
  bool get supportsChangeEvents =>
      (_targetPlatform ?? defaultTargetPlatform) != TargetPlatform.windows;

  @override
  Stream<void> get onChange {
    if (!supportsChangeEvents) return const Stream<void>.empty();
    return _changes ??= eventChannel
        .receiveBroadcastStream()
        .map<void>((_) {})
        .handleError((Object _) {}, test: (e) => e is PlatformException);
  }
}
