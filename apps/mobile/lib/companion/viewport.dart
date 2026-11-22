import 'image.dart';
import 'package:flutter/material.dart';
import '../shared/api.dart';
import 'viewport_native.dart' if (dart.library.js_interop) 'viewport_web.dart';

class CompanionView extends StatefulWidget {
  const CompanionView({
    super.key,
    required this.config,
    this.state = 'idle',
    this.motion = 'standard',
    this.view = 'bust',
    this.paused = false,
    this.reset = 0,
    this.controls = false,
  });
  final Data config;
  final String state, motion, view;
  final bool paused, controls;
  final int reset;
  @override
  State<CompanionView> createState() => _CompanionViewState();
}

class _CompanionViewState extends State<CompanionView>
    with WidgetsBindingObserver {
  bool awake = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() => awake = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final covered = ModalRoute.of(context)?.isCurrent == false;
    final pause = widget.paused || !awake || covered;
    final still = MediaQuery.disableAnimationsOf(context);
    final preset = text(widget.config, 'preset', 'clear');
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: ColoredBox(
        color: dark ? const Color(0xff293a32) : const Color(0xffe7eee7),
        child: PlatformCompanion(
          config: widget.config,
          state: widget.state,
          motion: still ? 'still' : widget.motion,
          theme: dark ? 'dark' : 'light',
          paused: pause,
          view: widget.view,
          reset: widget.reset,
          controls: widget.controls,
          fallback: CompanionImage(
            'poster-$preset.png',
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
