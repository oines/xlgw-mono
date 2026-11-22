import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'assets_web.dart';

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
  State<PlatformCompanion> createState() => _WebView();
}

class _WebView extends State<PlatformCompanion> {
  static int _index = 0;
  static const _type = 'harbor-companion';
  static bool _registered = false;
  late final int _id;
  late final web.HTMLIFrameElement frame;
  late final JSFunction _listener;
  bool ready = false;
  bool remote = false;
  static const localEntry = 'assets/assets/companion/';

  @override
  void initState() {
    super.initState();
    _id = _index++;
    frame = web.HTMLIFrameElement()
      ..src = localEntry
      ..title = '可定制的三维伙伴'
      ..setAttribute('tabindex', '-1');
    frame.style
      ..width = '100%'
      ..height = '100%'
      ..border = '0'
      ..background = 'transparent';
    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(
        _type,
        (int _, {Object? params}) => _frames[params as int]!,
      );
      _registered = true;
    }
    _frames[_id] = frame;
    _listener = ((web.MessageEvent event) {
      if (event.origin != Uri.base.origin ||
          event.source != frame.contentWindow)
        return;
      final msg = event.data.dartify();
      if (msg is! Map || msg['source'] != 'harbor-companion' || !mounted)
        return;
      if (msg['type'] == 'ready') {
        setState(() => ready = true);
        _sync();
      }
      if (msg['type'] == 'error') {
        setState(() => ready = false);
        if (remote) {
          remote = false;
          frame.src = localEntry;
        }
      }
    }).toJS;
    web.window.addEventListener('message', _listener);
    _sync();
    refresh();
  }

  Future<void> refresh() async {
    final bundle = await refreshWebBundle();
    if (!mounted || bundle == null) return;
    if (!bundle.has("companion.glb")) return;
    final root = '/companion-assets/${bundle.release}/';
    remote = true;
    setState(() => ready = false);
    frame.src = Uri.parse(
      localEntry,
    ).replace(queryParameters: {'assetRoot': root}).toString();
  }

  static final _frames = <int, web.HTMLIFrameElement>{};
  void _send(String type, [Object? value]) {
    final payload = <String, Object?>{
      'type': type,
      if (value != null) type: value,
    };
    frame.contentWindow?.postMessage(payload.jsify(), Uri.base.origin.toJS);
  }

  void _sync({bool reset = false}) {
    frame.style.pointerEvents = widget.controls ? 'auto' : 'none';
    if (!ready) return;
    _send('config', widget.config);
    _send('state', widget.state);
    _send('motion', widget.motion);
    _send('theme', widget.theme);
    _send('view', widget.view);
    _send('paused', widget.paused);
    if (reset) _send('reset');
  }

  @override
  void didUpdateWidget(covariant PlatformCompanion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(reset: oldWidget.reset != widget.reset);
  }

  @override
  void dispose() {
    _send('paused', true);
    web.window.removeEventListener('message', _listener);
    _frames.remove(_id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.fallback,
      Opacity(
        opacity: ready ? 1 : 0,
        child: HtmlElementView(viewType: _type, creationParams: _id),
      ),
    ],
  );
}
