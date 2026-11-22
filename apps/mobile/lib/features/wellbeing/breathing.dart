import 'package:flutter/material.dart';

import '../student_surface.dart';
import 'common.dart';

const breathingPracticeDuration = Duration(minutes: 3);

enum BreathingPattern {
  square('方框呼吸', [
    ('吸气', 4, 0.72, 1.0),
    ('停一停', 4, 1.0, 1.0),
    ('呼气', 4, 1.0, 0.72),
    ('停一停', 4, 0.72, 0.72),
  ]),
  slow('4-7-8 呼吸', [
    ('吸气', 4, 0.72, 1.0),
    ('停一停', 7, 1.0, 1.0),
    ('呼气', 8, 1.0, 0.72),
  ]);

  const BreathingPattern(this.label, this.phases);

  final String label;
  final List<(String, int, double, double)> phases;

  (String, int, double) cue(Duration elapsed) {
    final cycle = phases.fold(0, (seconds, phase) => seconds + phase.$2);
    var second = (elapsed.inMilliseconds / 1000) % cycle;
    for (final phase in phases) {
      if (second < phase.$2) {
        final scale = phase.$3 + (phase.$4 - phase.$3) * (second / phase.$2);
        return (phase.$1, (phase.$2 - second).ceil(), scale);
      }
      second -= phase.$2;
    }
    return ('吸气', 4, 0.72);
  }
}

class BreathingCue extends StatelessWidget {
  const BreathingCue({
    required this.pattern,
    required this.elapsed,
    required this.active,
    super.key,
  });

  final BreathingPattern pattern;
  final Duration elapsed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (label, seconds, scale) = pattern.cue(elapsed);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: 192,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: active && !reduceMotion ? scale : 0.85,
              child: ExcludeSemantics(
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primaryContainer,
                    border: Border.all(
                      color: colors.primary.withValues(alpha: 0.22),
                    ),
                  ),
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  active ? label : '准备好了就开始',
                  style: theme.textTheme.titleMedium,
                ),
                if (active)
                  Text('$seconds', style: theme.textTheme.headlineMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class BreathingPage extends StatefulWidget {
  const BreathingPage({super.key});

  @override
  State<BreathingPage> createState() => _BreathingPageState();
}

class _BreathingPageState extends State<BreathingPage>
    with SingleTickerProviderStateMixin {
  late final _timer = AnimationController(
    vsync: this,
    duration: breathingPracticeDuration,
    animationBehavior: AnimationBehavior.preserve,
  )..addStatusListener((_) => setState(() {}));

  String _scene = '考前';
  BreathingPattern _pattern = BreathingPattern.square;
  String? _feeling;

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  void _selectScene(String value) {
    _timer.reset();
    setState(() {
      _scene = value;
      _pattern = value == '睡不着'
          ? BreathingPattern.slow
          : BreathingPattern.square;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finished = _timer.isCompleted;
    final active = _timer.isAnimating || _timer.value > 0;
    return WellbeingPage(
      title: '呼吸练习',
      children: [
        const WellbeingIntro('给自己三分钟', '跟着圆的起落慢慢呼吸，也可以随时停下来。'),
        if (!active)
          StudentFilters(
            options: const ['考前', '发言前', '睡不着'],
            selected: _scene,
            onSelect: _selectScene,
          ),
        if (finished)
          StudentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('三分钟到了', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                const Text('现在感觉怎么样？也可以就停在这里。'),
                const SizedBox(height: 8),
                StudentFilters(
                  options: const ['松了一点', '差不多', '还有点紧'],
                  selected: _feeling ?? '',
                  onSelect: (value) => setState(() => _feeling = value),
                ),
                if (_feeling != null) ...[
                  const SizedBox(height: 8),
                  const Text('谢谢你照顾了自己一会儿。'),
                ],
              ],
            ),
          )
        else
          StudentCard(
            child: AnimatedBuilder(
              animation: _timer,
              builder: (context, _) {
                final elapsed = Duration(
                  milliseconds:
                      (breathingPracticeDuration.inMilliseconds * _timer.value)
                          .floor(),
                );
                final remaining =
                    (breathingPracticeDuration - elapsed).inMilliseconds;
                final seconds = (remaining / 1000).ceil();
                final clock =
                    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
                return Column(
                  children: [
                    Text(_pattern.label, style: theme.textTheme.titleMedium),
                    BreathingCue(
                      pattern: _pattern,
                      elapsed: elapsed,
                      active: active,
                    ),
                    Text(clock, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: _timer.value),
                  ],
                );
              },
            ),
          ),
        if (finished)
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          )
        else ...[
          FilledButton(
            onPressed: () {
              if (_timer.isAnimating) {
                _timer.stop();
              } else {
                _timer.forward();
              }
              setState(() {});
            },
            child: Text(_timer.isAnimating ? '暂停' : (active ? '继续' : '开始练习')),
          ),
          if (active)
            TextButton(
              onPressed: () {
                _timer.reset();
                Navigator.pop(context);
              },
              child: const Text('结束练习'),
            ),
        ],
      ],
    );
  }
}
