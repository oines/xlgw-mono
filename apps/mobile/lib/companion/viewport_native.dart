import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../shared/api.dart';
import 'assets.dart';
import 'assets_native.dart';

class PlatformCompanion extends StatefulWidget {
  const PlatformCompanion({
    super.key,
    required this.config,
    required this.state,
    required this.motion,
    required this.theme,
    required this.paused,
    required this.view,
    required this.reset,
    required this.controls,
    required this.fallback,
  });
  final Map<String, dynamic> config;
  final String state, motion, theme, view;
  final bool paused, controls;
  final int reset;
  final Widget fallback;
  @override
  State<PlatformCompanion> createState() => _NativeView();
}

class _NativeView extends State<PlatformCompanion> {
  static Future<HttpServer>? _assetListener;
  WebViewController? _controller;
  bool _ready = false;
  String? _release;
  bool _checked = false;
  Uri? _entry;

  static Future<HttpServer> _listen() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final segments = req.uri.pathSegments;
      final remote = segments.length > 2 && segments.first == 'updates';
      final name = remote ? segments.skip(2).join('/') : segments.join('/');
      final type = switch (name.split('.').last) {
        'html' when !remote && name == 'index.html' => 'text/html',
        'js' when !remote && name == 'viewer.js' => 'text/javascript',
        'glb' ||
        'vrm' when CompanionBundle.validPath(name) => 'model/gltf-binary',
        'png' when CompanionBundle.validPath(name) => 'image/png',
        'jpg' || 'jpeg' when CompanionBundle.validPath(name) => 'image/jpeg',
        'webp' when CompanionBundle.validPath(name) => 'image/webp',
        _ => null,
      };
      if (type == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      try {
        final downloaded = remote ? await cachedAsset(segments[1], name) : null;
        if (remote && downloaded == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        req.response.headers.set(HttpHeaders.contentTypeHeader, type);
        req.response.headers.set(
          HttpHeaders.cacheControlHeader,
          remote ? 'public, max-age=31536000, immutable' : 'no-cache',
        );
        if (downloaded != null) {
          req.response.headers.contentLength = await downloaded.length();
          await req.response.addStream(downloaded.openRead());
        } else {
          final bytes = await rootBundle.load('$bundledCompanion/$name');
          req.response.add(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
        }
      } catch (_) {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    return server;
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS)
      return;
    try {
      final local = await (_assetListener ??= _listen());
      if (!mounted) return;
      final controller = WebViewController();
      _release = harborOffline ? null : await cachedRelease();
      if (!mounted) return;
      _entry = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: local.port,
        path: '/index.html',
      );
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.transparent);
      await controller.addJavaScriptChannel(
        'CompanionBridge',
        onMessageReceived: (msg) {
          if (!mounted) return;
          final event = jsonDecode(msg.message);
          if (event['type'] == 'ready') {
            setState(() => _ready = true);
            _sync();
          }
          if (event['type'] == 'error') {
            setState(() => _ready = false);
            if (_release != null) {
              _release = null;
              controller.loadRequest(_entry!);
            }
          }
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              Uri.tryParse(request.url)?.origin == _entry?.origin
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
      await controller.loadRequest(_initialPage());
      if (mounted) setState(() => _controller = controller);
      _sync();
      _refreshWhenIdle();
    } catch (_) {
      if (mounted) setState(() => _ready = false);
    }
  }

  Uri _initialPage() {
    final release = _release;
    return release == null
        ? _entry!
        : _entry!.replace(queryParameters: {'assetRoot': '/updates/$release/'});
  }

  Future<void> _refreshWhenIdle() async {
    if (_checked || harborOffline) return;
    _checked = true;
    final api = HarborApi();
    final updated = await refreshAssets(api);
    api.client.close();
    if (!mounted || updated == null || updated == _release) return;
    // The editor keeps its active draft. The next open already sees the new cache.
    if (widget.controls) return;
    _release = updated;
    setState(() => _ready = false);
    await _controller?.loadRequest(_initialPage());
  }

  Future<void> _sync({bool reset = false}) async {
    final v = _controller;
    if (v == null || !_ready) return;
    final commands = <String, Object>{
      'setConfig': widget.config,
      'setState': widget.state,
      'setMotion': widget.motion,
      'setTheme': widget.theme,
      'setView': widget.view,
      'setPaused': widget.paused,
    };
    final commandsJs = commands.entries
        .map((e) => 'window.Companion.${e.key}(${jsonEncode(e.value)});')
        .join();
    try {
      await v.runJavaScript(
        commandsJs + (reset ? 'window.Companion.resetCamera();' : ''),
      );
    } catch (_) {
      /* a disposed WebView can drop a visual update */
    }
  }

  @override
  void didUpdateWidget(covariant PlatformCompanion previous) {
    super.didUpdateWidget(previous);
    _sync(reset: previous.reset != widget.reset);
  }

  @override
  void dispose() {
    _controller
        ?.runJavaScript('window.Companion?.setPaused(true);')
        .catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.fallback,
      if (_controller != null)
        Opacity(
          opacity: _ready ? 1 : 0,
          child: IgnorePointer(
            ignoring: !widget.controls,
            child: WebViewWidget(controller: _controller!),
          ),
        ),
    ],
  );
}
