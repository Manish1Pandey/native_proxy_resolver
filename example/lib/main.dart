import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:native_proxy_resolver/http.dart';
import 'package:native_proxy_resolver/native_proxy_resolver.dart';

import 'dio_integration.dart';

void main() {
  runApp(const ProxyDemoApp());
}

/// Demo app: resolves the OS proxy for a URL and fetches it through
/// `HttpClient`, `package:http` and Dio.
class ProxyDemoApp extends StatelessWidget {
  /// Creates the app. [resolver] defaults to [SystemProxy.resolver].
  const ProxyDemoApp({super.key, this.resolver});

  /// The resolver used by every demo; injectable for tests.
  final SystemProxyResolver? resolver;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'native_proxy_resolver',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: ProxyDemoPage(resolver: resolver ?? SystemProxy.resolver),
    );
  }
}

/// The single page of the demo.
class ProxyDemoPage extends StatefulWidget {
  /// Creates the page.
  const ProxyDemoPage({super.key, required this.resolver});

  /// The resolver used by the page.
  final SystemProxyResolver resolver;

  @override
  State<ProxyDemoPage> createState() => _ProxyDemoPageState();
}

class _ProxyDemoPageState extends State<ProxyDemoPage> {
  final _url = TextEditingController(text: 'https://example.com/');
  final _events = <String>[];
  StreamSubscription<void>? _changes;
  ProxyResolution? _resolution;
  String? _fetchResult;
  bool _busy = false;
  bool _overridesInstalled = false;
  HttpOverrides? _previousOverrides;

  SystemProxyResolver get _resolver => widget.resolver;

  @override
  void initState() {
    super.initState();
    if (_resolver.supportsChangeEvents) {
      _changes = _resolver.onChange.listen((_) {
        setState(() {
          _events.insert(0, '${_time()} network/proxy changed, cache cleared');
        });
      });
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _url.dispose();
    super.dispose();
  }

  static String _time() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  Uri? _parsedUrl() {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter an absolute URL, e.g. https://example.com'),
        ),
      );
      return null;
    }
    return uri;
  }

  Future<void> _run(Future<void> Function(Uri uri) action) async {
    final uri = _parsedUrl();
    if (uri == null) return;
    setState(() => _busy = true);
    try {
      await action(uri);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolve({bool force = false}) => _run((uri) async {
    final resolution = await _resolver.resolveDetailed(
      uri,
      forceRefresh: force,
    );
    setState(() => _resolution = resolution);
  });

  String _describe(String via, int status, Duration elapsed) =>
      '$via: HTTP $status in ${elapsed.inMilliseconds} ms '
      '(route: ${_resolver.findProxy(Uri.parse(_url.text.trim()))})';

  Future<void> _fetchWithHttpClient() => _run((uri) async {
    final watch = Stopwatch()..start();
    final client = ProxyAwareHttpClient(resolver: _resolver);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      _setFetch(_describe('HttpClient', response.statusCode, watch.elapsed));
    } catch (e) {
      _setFetch('HttpClient failed: $e');
    } finally {
      client.close();
    }
  });

  Future<void> _fetchWithPackageHttp() => _run((uri) async {
    final watch = Stopwatch()..start();
    final http.Client client = createSystemProxyHttpClient(resolver: _resolver);
    try {
      final response = await client.get(uri);
      _setFetch(_describe('package:http', response.statusCode, watch.elapsed));
    } catch (e) {
      _setFetch('package:http failed: $e');
    } finally {
      client.close();
    }
  });

  Future<void> _fetchWithDio() => _run((uri) async {
    final watch = Stopwatch()..start();
    final dio = createSystemProxyDio(resolver: _resolver);
    try {
      final response = await dio.getUri<String>(uri);
      _setFetch(_describe('Dio', response.statusCode ?? 0, watch.elapsed));
    } catch (e) {
      _setFetch('Dio failed: $e');
    } finally {
      dio.close();
    }
  });

  Future<void> _fetchWithPlainHttpClient() => _run((uri) async {
    // A plain HttpClient(): proxy-aware only while the overrides are on.
    final watch = Stopwatch()..start();
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      _setFetch(
        _describe(
          'HttpClient() ${_overridesInstalled ? 'with' : 'without'} overrides',
          response.statusCode,
          watch.elapsed,
        ),
      );
    } catch (e) {
      _setFetch('HttpClient() failed: $e');
    } finally {
      client.close();
    }
  });

  void _setFetch(String text) {
    if (mounted) setState(() => _fetchResult = text);
  }

  void _toggleOverrides(bool enable) {
    if (enable) {
      _previousOverrides = HttpOverrides.current;
      SystemProxy.installHttpOverrides(resolver: _resolver);
    } else {
      HttpOverrides.global = _previousOverrides;
    }
    setState(() => _overridesInstalled = enable);
  }

  Future<void> _warmUp() => _run((uri) async {
    await _resolver.warmUp([uri, Uri.parse('https://pub.dev/')]);
    setState(() {
      _events.insert(0, '${_time()} warmed ${_resolver.cacheSize} origin(s)');
    });
  });

  @override
  Widget build(BuildContext context) {
    final resolution = _resolution;
    return Scaffold(
      appBar: AppBar(title: const Text('System proxy (PAC/WPAD)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('url'),
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('resolve'),
                onPressed: _busy ? null : _resolve,
                child: const Text('Resolve'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _resolve(force: true),
                child: const Text('Resolve (bypass cache)'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _warmUp,
                child: const Text('Warm up cache'),
              ),
              OutlinedButton(
                onPressed: () {
                  _resolver.clearCache();
                  setState(() => _events.insert(0, '${_time()} cache cleared'));
                },
                child: const Text('Clear cache'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (resolution != null) _ResolutionCard(resolution: resolution),
          const SizedBox(height: 16),
          Text(
            'Fetch through the OS proxy',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : _fetchWithHttpClient,
                child: const Text('ProxyAwareHttpClient'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _fetchWithPackageHttp,
                child: const Text('package:http'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _fetchWithDio,
                child: const Text('Dio'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _fetchWithPlainHttpClient,
                child: const Text('plain HttpClient()'),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Install HttpOverrides globally'),
            subtitle: const Text('Makes every HttpClient() proxy-aware'),
            value: _overridesInstalled,
            onChanged: _toggleOverrides,
          ),
          if (_fetchResult != null)
            SelectableText(_fetchResult!, key: const Key('fetch-result')),
          const Divider(height: 32),
          Text(
            _resolver.supportsChangeEvents
                ? 'Change events (cache is cleared automatically)'
                : 'Change events are not available on this platform; '
                      'the cache expires after ${_resolver.cacheTtl.inMinutes} min',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final event in _events.take(20)) Text(event),
        ],
      ),
    );
  }
}

class _ResolutionCard extends StatelessWidget {
  const _ResolutionCard({required this.resolution});

  final ProxyResolution resolution;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Routes for ${resolution.uri}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            for (final (i, entry) in resolution.entries.indexed)
              Text(
                '${i + 1}. $entry'
                '${entry.isSupportedByDartIo ? '' : '  (not usable by dart:io)'}',
                key: Key('entry-$i'),
              ),
            const SizedBox(height: 8),
            Text('Source: ${resolution.source.name}', key: const Key('source')),
            if (resolution.pacUrl != null) Text('PAC: ${resolution.pacUrl}'),
            SelectableText(
              'findProxy: ${resolution.toFindProxyString()}',
              key: const Key('find-proxy'),
            ),
            if (resolution.error != null)
              Text(
                'Note: ${resolution.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
