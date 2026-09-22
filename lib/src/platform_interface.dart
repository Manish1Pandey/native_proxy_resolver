import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel.dart';
import 'proxy_entry.dart';

/// The interface each platform implementation of `native_proxy_resolver` extends.
///
/// Platform implementations must `extends` this class (not `implements`) so
/// that new methods can be added without breaking them.
abstract class NativeProxyResolverPlatform extends PlatformInterface {
  /// Constructs the platform interface.
  NativeProxyResolverPlatform() : super(token: _token);

  static final Object _token = Object();

  static NativeProxyResolverPlatform _instance =
      MethodChannelNativeProxyResolver();

  /// The active implementation. Defaults to [MethodChannelNativeProxyResolver]
  /// (Android, iOS, macOS, Windows); Linux registers a pure Dart
  /// implementation.
  static NativeProxyResolverPlatform get instance => _instance;

  /// Replaces the active implementation (used by platform packages and tests).
  static set instance(NativeProxyResolverPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Asks the operating system which routes to use for [uri].
  ///
  /// [uri] always has an `http` or `https` scheme and a host (the caller maps
  /// `ws`/`wss`). Implementations should bound slow work (PAC download, WPAD)
  /// by [timeout] and report failures through [ProxyResolution.error] rather
  /// than throwing.
  Future<ProxyResolution> resolve(Uri uri, {required Duration timeout});

  /// Whether [onChange] delivers events on this platform.
  bool get supportsChangeEvents;

  /// Emits whenever the network or proxy configuration may have changed.
  /// A broadcast stream; empty when [supportsChangeEvents] is false.
  Stream<void> get onChange;
}
