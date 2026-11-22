import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/api.dart';
import '../../shared/design.dart';
import '../student_surface.dart';
import 'audio.dart';
import 'common.dart';

class SleepPage extends StatefulWidget {
  const SleepPage(this.api, {super.key});

  final HarborApi api;

  @override
  State<SleepPage> createState() => _SleepPageState();
}

class _SleepPageState extends State<SleepPage> {
  static const _bedtimeKey = 'harbor.wellbeing.bedtime';
  final _preferences = SharedPreferencesAsync();
  var _bedtime = const TimeOfDay(hour: 23, minute: 0);
  List<Data> _records = [];
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  String get _lastNight {
    final now = DateTime.now();
    return wellbeingDay(DateTime(now.year, now.month, now.day - 1));
  }

  TimeOfDay _clock(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

  int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

  @override
  void initState() {
    super.initState();
    _loadBedtime();
    _loadRecords();
  }

  Future<void> _loadBedtime() async {
    final value = await _preferences.getInt(_bedtimeKey);
    if (mounted && value != null) setState(() => _bedtime = _clock(value));
  }

  Future<void> _loadRecords() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api.list('/wellbeing/sleep?limit=7');
      if (mounted) setState(() => _records = items);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setBedtime() async {
    final time = await showTimePicker(context: context, initialTime: _bedtime);
    if (time == null || !mounted) return;
    await _preferences.setInt(_bedtimeKey, _minutes(time));
    if (mounted) setState(() => _bedtime = time);
  }

  Future<void> _record(int? previous) async {
    final time = await showTimePicker(
      context: context,
      initialTime: previous == null ? _bedtime : _clock(previous),
    );
    if (time == null || !mounted) return;
    final day = _lastNight;
    setState(() => _saving = true);
    try {
      final record = await widget.api.put('/wellbeing/sleep/$day', {
        'minutes_after_midnight': _minutes(time),
      });
      if (!mounted) return;
      setState(() {
        _records = [
          record,
          ..._records.where((row) => text(row, 'day') != day).take(6),
        ];
      });
      flash(context, '昨晚的入睡时间已保存');
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = _records.where((row) => text(row, 'day') == _lastNight);
    final lastTime = recent.firstOrNull?['minutes_after_midnight'] as int?;
    return WellbeingPage(
      title: '助眠模式',
      children: [
        const WellbeingIntro('睡前留十分钟', '让声音慢慢低下去，把手机放在一边。'),
        StudentCard(
          onTap: _setBedtime,
          child: Row(
            children: [
              const Icon(Icons.bedtime_outlined),
              const SizedBox(width: 10),
              const Expanded(child: Text('计划入睡时间')),
              Text(
                _bedtime.format(context),
                style: theme.textTheme.titleMedium,
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
        const SoundPlayback(
          sound: WellbeingSound.sleep,
          minutes: 10,
          breathing: true,
        ),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_error case final error?)
          LoadError(error, _loadRecords)
        else
          StudentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('昨晚几点睡的？', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _saving ? null : () => _record(lastTime),
                  child: Text(
                    _saving
                        ? '正在保存…'
                        : lastTime == null
                        ? '记录入睡时间'
                        : '已记 ${_clock(lastTime).format(context)} · 修改',
                  ),
                ),
                for (final row in _records.where(
                  (row) => text(row, 'day') != _lastNight,
                ))
                  if ((
                        row['minutes_after_midnight'],
                        DateTime.tryParse(text(row, 'day')),
                      )
                      case (final int minutes, final DateTime day))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(DateFormat('M月d日').format(day)),
                          Text(_clock(minutes).format(context)),
                        ],
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}
