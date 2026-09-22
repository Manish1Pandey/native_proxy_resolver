import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'bypass_rules.dart';
import 'environment_proxy.dart';
import 'platform_interface.dart';
import 'proxy_entry.dart';

/// Runs a process to completion (injectable for tests).
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Starts a long-running process (injectable for tests).
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Pure Dart [NativeProxyResolverPlatform] for Linux.
///
/// Linux has no system-wide proxy resolver, so this implementation reads
/// 1. the `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` environment
///    variables, and when none is set
/// 2. the GNOME desktop settings (`gsettings list-recursively
///    org.gnome.system.proxy`).
///
/// A GNOME `auto` (PAC / WPAD) configuration cannot be evaluated: the result
/// is DIRECT with [ProxyResolution.error] explaining why, and
/// [ProxyResolution.pacUrl] set so an application can fetch and evaluate the
/// script itself if it must.
class NativeProxyResolverLinux extends NativeProxyResolverPlatform {
  /// Creates the Linux implementation. All parameters exist for testing.
  NativeProxyResolverLinux({
    @visibleForTesting Map<String, String>? environment,
    @visibleForTesting ProcessRunner? runProcess,
    @visibleForTesting ProcessStarter? startProcess,
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting this.settingsSnapshotTtl = const Duration(seconds: 5),
  }) : _environment = environment,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start,
       _clock = clock ?? DateTime.now;

  /// Registers this class as the platform implementation (called by the
  /// Flutter tool through `dartPluginClass`).
  static void registerWith() {
    NativeProxyResolverPlatform.instance = NativeProxyResolverLinux();
  }

  /// The GNOME schema holding the proxy settings.
  static const String gnomeSchema = 'org.gnome.system.proxy';

  static const List<String> _monitoredSchemas = [
    gnomeSchema,
    '$gnomeSchema.http',
    '$gnomeSchema.https',
    '$gnomeSchema.socks',
  ];

  final Map<String, String>? _environment;
  final ProcessRunner _runProcess;
  final ProcessStarter _startProcess;
  final DateTime Function() _clock;

  /// How long a `gsettings` read is reused before running it again.
  final Duration settingsSnapshotTtl;

  Future<Map<String, String>?>? _snapshot;
  DateTime? _snapshotAt;
  bool? _gsettingsAvailable;
  StreamController<void>? _changes;
  final List<Process> _monitors = [];

  @override
  Future<ProxyResolution> resolve(Uri uri, {required Duration timeout}) async {
    final env = EnvironmentProxyConfig.fromEnvironment(
      _environment ?? Platform.environment,
    );
    if (env.hasProxy) {
      return ProxyResolution(
        uri: uri,
        entries: env.entriesFor(uri) ?? const [ProxyEntry.direct],
        source: ProxySource.environment,
        resolvedAt: _clock(),
      );
    }
    Map<String, String>? settings;
    String? readError;
    try {
      settings = await _readGnomeSettings().timeout(timeout);
    } on TimeoutException {
      readError = 'gsettings did not answer within $timeout';
    }
    if (settings == null) {
      return ProxyResolution(
        uri: uri,
        entries: const [ProxyEntry.direct],
        source: ProxySource.none,
        resolvedAt: _clock(),
        error: readError,
      );
    }
    return resolveFromGnomeSettings(uri, settings, _clock());
  }

  /// Applies parsed GNOME settings (`schema key` → raw GVariant text) to
  /// [uri]. Exposed for tests.
  @visibleForTesting
  static ProxyResolution resolveFromGnomeSettings(
    Uri uri,
    Map<String, String> settings,
    DateTime now,
  ) {
    String str(String key) => parseGVariantString(settings[key]) ?? '';
    int port(String key) => int.tryParse(settings[key]?.trim() ?? '') ?? 0;
    bool flag(String key) => settings[key]?.trim() == 'true';

    final mode = str('$gnomeSchema mode');
    switch (mode) {
      case 'manual':
        final ignore = ProxyBypassRules.fromList(
          parseGVariantStringList(settings['$gnomeSchema ignore-hosts']),
        );
        if (ignore.matches(uri)) {
          return ProxyResolution(
            uri: uri,
            entries: const [ProxyEntry.direct],
            source: ProxySource.manual,
            resolvedAt: now,
          );
        }
        ProxyEntry? proxyFor(String schema, ProxyType type) {
          final host = str('$schema host');
          final p = port('$schema port');
          if (host.isEmpty || p <= 0) return null;
          final auth =
              schema == '$gnomeSchema.http' &&
              flag('$schema use-authentication');
          return ProxyEntry(
            type: type,
            host: host,
            port: p,
            username: auth
                ? _nonEmpty(str('$schema authentication-user'))
                : null,
            password: auth
                ? _nonEmpty(str('$schema authentication-password'))
                : null,
          );
        }

        final http = proxyFor('$gnomeSchema.http', ProxyType.http);
        final https = proxyFor('$gnomeSchema.https', ProxyType.http);
        final socks = proxyFor('$gnomeSchema.socks', ProxyType.socks);
        final sameProxy = flag('$gnomeSchema use-same-proxy');
        final chosen = switch (uri.scheme) {
          'http' || 'ws' => http,
          'https' || 'wss' => https ?? (sameProxy ? http : null),
          _ => sameProxy ? http : null,
        };
        final entry = chosen ?? socks;
        return ProxyResolution(
          uri: uri,
          entries: [entry ?? ProxyEntry.direct],
          source: ProxySource.manual,
          resolvedAt: now,
        );
      case 'auto':
        final pac = str('$gnomeSchema autoconfig-url');
        return ProxyResolution(
          uri: uri,
          entries: const [ProxyEntry.direct],
          source: pac.isEmpty ? ProxySource.autoDetect : ProxySource.pac,
          pacUrl: pac.isEmpty ? null : Uri.tryParse(pac),
          resolvedAt: now,
          error: pac.isEmpty
              ? 'GNOME is set to WPAD auto-detection, which Linux cannot '
                    'evaluate without a PAC engine; using DIRECT.'
              : 'GNOME uses a PAC script ($pac); Linux has no system PAC '
                    'engine, so it was not evaluated; using DIRECT.',
        );
      default:
        return ProxyResolution(
          uri: uri,
          entries: const [ProxyEntry.direct],
          source: ProxySource.none,
          resolvedAt: now,
        );
    }
  }

  static String? _nonEmpty(String value) => value.isEmpty ? null : value;

  Future<Map<String, String>?> _readGnomeSettings() {
    final now = _clock();
    final at = _snapshotAt;
    final cached = _snapshot;
    if (cached != null &&
        at != null &&
        now.difference(at) < settingsSnapshotTtl) {
      return cached;
    }
    _snapshotAt = now;
    return _snapshot = _runGsettings();
  }

  Future<Map<String, String>?> _runGsettings() async {
    final ProcessResult result;
    try {
      result = await _runProcess('gsettings', [
        'list-recursively',
        gnomeSchema,
      ]);
    } on ProcessException {
      _gsettingsAvailable = false;
      return null;
    }
    if (result.exitCode != 0) {
      _gsettingsAvailable = false;
      return null;
    }
    _gsettingsAvailable = true;
    return parseGsettingsListing(result.stdout.toString());
  }

  /// Parses `gsettings list-recursively` output into `schema key` → value.
  @visibleForTesting
  static Map<String, String> parseGsettingsListing(String output) {
    final settings = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final first = line.indexOf(' ');
      if (first < 0) continue;
      final second = line.indexOf(' ', first + 1);
      if (second < 0) continue;
      settings[line.substring(0, second)] = line.substring(second + 1).trim();
    }
    return settings;
  }

  /// Parses a GVariant text string such as `'proxy.corp'` (returns `null`
  /// when [value] is not a string literal).
  @visibleForTesting
  static String? parseGVariantString(String? value) {
    if (value == null) return null;
    final list = _parseStrings(value.trim());
    return list.length == 1 ? list.single : null;
  }

  /// Parses a GVariant text string array such as `['localhost', '::1']` or
  /// `@as []`.
  @visibleForTesting
  static List<String> parseGVariantStringList(String? value) {
    if (value == null) return const [];
    var v = value.trim();
    if (v.startsWith('@as')) v = v.substring(3).trim();
    if (!v.startsWith('[') || !v.endsWith(']')) return const [];
    return _parseStrings(v.substring(1, v.length - 1));
  }

  static List<String> _parseStrings(String text) {
    final out = <String>[];
    var i = 0;
    while (i < text.length) {
      final quote = text[i];
      if (quote != "'" && quote != '"') {
        i++;
        continue;
      }
      final buffer = StringBuffer();
      i++;
      while (i < text.length && text[i] != quote) {
        if (text[i] == r'\' && i + 1 < text.length) i++;
        buffer.write(text[i]);
        i++;
      }
      out.add(buffer.toString());
      i++;
    }
    return out;
  }

  @override
  bool get supportsChangeEvents => _gsettingsAvailable ?? true;

  @override
  Stream<void> get onChange {
    return (_changes ??= StreamController<void>.broadcast(
      onListen: _startMonitors,
      onCancel: _stopMonitors,
    )).stream;
  }

  Future<void> _startMonitors() async {
    for (final schema in _monitoredSchemas) {
      final Process process;
      try {
        process = await _startProcess('gsettings', ['monitor', schema]);
      } on ProcessException {
        _gsettingsAvailable = false;
        return;
      }
      if (!(_changes?.hasListener ?? false)) {
        process.kill();
        return;
      }
      _monitors.add(process);
      process.stdout.transform(utf8.decoder).listen((_) {
        _snapshot = null;
        _changes?.add(null);
      });
      process.stderr.drain<void>().ignore();
    }
  }

  void _stopMonitors() {
    for (final process in _monitors) {
      process.kill();
    }
    _monitors.clear();
  }
}
