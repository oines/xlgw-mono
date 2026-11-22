import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../shared/design.dart';
import '../student_surface.dart';
import 'audio.dart';
import 'breathing.dart';
import 'common.dart';

const _dailyReminder = MethodChannel('harbor/wellbeing/daily');

const _semesterCards = [
  (
    [Color(0xfff3e5cc), Color(0xff87a991), Color(0xff557b6b)],
    ['新的节奏，可以慢慢找到。', '先把手边的一小步走完。', '走熟一条路，就给自己一点时间。'],
  ),
  (
    [Color(0xfff3dfcc), Color(0xffb58d79), Color(0xff786d67)],
    ['忙碌里也可以有一小段空白。', '在两件事之间，喝一口水。', '先照顾眼前的这一小会儿。'],
  ),
  (
    [Color(0xffe3edf2), Color(0xff87a3ad), Color(0xff526f81)],
    ['今天可以把脚步放慢一点。', '打开窗，感受一会儿空气。', '给一件喜欢的小事一点时间。'],
  ),
  (
    [Color(0xfff0e6d2), Color(0xffb8bd97), Color(0xff72866c)],
    ['带着今天的样子，慢慢来。', '也可以留一点时间给自己。', '有些小事，今天做到一点就够了。'],
  ),
];

class DailyCardPage extends StatefulWidget {
  const DailyCardPage({super.key, this.accountId});

  final String? accountId;

  @override
  State<DailyCardPage> createState() => _DailyCardPageState();
}

class _DailyCardPageState extends State<DailyCardPage> {
  bool _enabled = false;
  bool _working = false;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    if (_supported) _readReminder();
  }

  Future<void> _readReminder() async {
    try {
      final enabled = await _dailyReminder.invokeMethod<bool>('isEnabled');
      if (mounted) setState(() => _enabled = enabled ?? false);
    } on PlatformException {
      // The card remains available if the system does not answer.
    } on MissingPluginException {
      // A Flutter-only preview cannot schedule native reminders.
    }
  }

  Future<void> _toggle(bool requested) async {
    setState(() => _working = true);
    try {
      final enabled = await _dailyReminder.invokeMethod<bool>(
        'setEnabled',
        requested,
      );
      if (!mounted) return;
      setState(() => _enabled = enabled ?? false);
      if (requested && !_enabled) {
        flash(context, '提醒没有开启，可以在系统设置中查看通知权限');
      }
    } on PlatformException {
      if (mounted) flash(context, '暂时无法设置提醒，请稍后再试');
    } on MissingPluginException {
      if (mounted) flash(context, '请在手机 App 中设置提醒');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final (colors, messages) =
        _semesterCards[switch (today.month) {
          2 || 3 || 9 => 0,
          1 || 6 || 12 => 1,
          7 || 8 => 2,
          _ => 3,
        }];
    return WellbeingPage(
      title: '每日推送',
      children: [
        StudentCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                label: '晨光里的远山',
                image: true,
                child: AspectRatio(
                  aspectRatio: 1.9,
                  child: CustomPaint(painter: _MorningLandscape(colors)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat('M月d日').format(today),
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      messages[(today.day - 1) % messages.length],
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        StudentCard(
          padding: EdgeInsets.zero,
          child: SwitchListTile(
            title: const Text('每日晨间提醒'),
            subtitle: Text(_supported ? '每天早上 7:30，可随时关闭' : '在手机 App 里开启提醒'),
            value: _enabled,
            onChanged: _supported && !_working ? _toggle : null,
          ),
        ),
        StudentCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.air_rounded),
                title: const Text('做一次呼吸练习'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(context, const BreathingPage()),
              ),
              if (widget.accountId case final accountId?) ...[
                const Divider(indent: 54),
                ListTile(
                  leading: const Icon(Icons.headphones_outlined),
                  title: const Text('听一会儿声音'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      open(context, SoundLibraryPage(accountId: accountId)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MorningLandscape extends CustomPainter {
  const _MorningLandscape(this.colors);

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final bounds = Offset.zero & size;
    final sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors[0], const Color(0xfffff7df)],
      ).createShader(bounds);
    canvas.drawRect(bounds, sky);
    canvas.drawCircle(
      Offset(width * 0.74, height * 0.33),
      height * 0.13,
      Paint()..color = const Color(0xfffff9e4),
    );
    final distant = Path()
      ..moveTo(0, height * 0.46)
      ..cubicTo(
        width * 0.22,
        height * 0.19,
        width * 0.45,
        height * 0.78,
        width,
        height * 0.48,
      )
      ..lineTo(width, height)
      ..lineTo(0, height)
      ..close();
    canvas.drawPath(distant, Paint()..color = colors[1]);
    final near = Path()
      ..moveTo(0, height * 0.78)
      ..cubicTo(
        width * 0.35,
        height * 0.96,
        width * 0.55,
        height * 0.44,
        width,
        height * 0.67,
      )
      ..lineTo(width, height)
      ..lineTo(0, height)
      ..close();
    canvas.drawPath(near, Paint()..color = colors[2]);
  }

  @override
  bool shouldRepaint(_MorningLandscape oldDelegate) =>
      oldDelegate.colors != colors;
}
