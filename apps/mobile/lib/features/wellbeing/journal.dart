import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../shared/api.dart';
import '../../shared/design.dart';
import '../student_surface.dart';
import 'common.dart';

const _moods = {
  'calm': ('平静', Icons.sentiment_satisfied_outlined, Color(0xff446954)),
  'happy': ('开心', Icons.wb_sunny_outlined, Color(0xff956713)),
  'tired': ('疲惫', Icons.cloud_outlined, Color(0xff426479)),
  'sad': ('难过', Icons.grain_rounded, Color(0xff795676)),
  'anxious': ('焦虑', Icons.air_rounded, Color(0xff8a563a)),
};

class JournalPage extends StatefulWidget {
  const JournalPage(this.api, {super.key, this.initialMood});

  final HarborApi api;
  final String? initialMood;

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  final _note = TextEditingController();
  List<Data> _entries = [];
  String? _mood;
  Object? _error;
  bool _loading = true;
  bool _saving = false;

  String get _today => wellbeingDay(DateTime.now());

  @override
  void initState() {
    super.initState();
    _mood = _moods.containsKey(widget.initialMood) ? widget.initialMood : null;
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.api.list('/wellbeing/journal?limit=100');
      if (!mounted) return;
      final today = entries.where((entry) => text(entry, 'day') == _today);
      if (today.isNotEmpty) {
        _mood ??= text(today.first, 'mood');
        _note.text = text(today.first, 'note');
      }
      setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final mood = _mood;
    if (mood == null) return;
    final day = _today;
    setState(() => _saving = true);
    try {
      final entry = await widget.api.put('/wellbeing/journal/$day', {
        'mood': mood,
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _entries = [entry, ..._entries.where((row) => text(row, 'day') != day)];
      });
      flash(context, '今天的情绪卡已经收好');
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(Data entry) async {
    final day = text(entry, 'day');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这张情绪卡？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.api.delete('/wellbeing/journal/$day');
      if (!mounted) return;
      setState(() {
        _entries.removeWhere((row) => text(row, 'day') == day);
        if (day == _today) {
          _mood = null;
          _note.clear();
        }
      });
      flash(context, '情绪卡已删除');
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _entries.where((entry) => text(entry, 'day') == _today);
    return WellbeingPage(
      title: '情绪日记',
      children: [
        const WellbeingIntro('今天是什么心情？', '选一个词就好。这些记录只有你能看到。'),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_error case final error?)
          LoadError(error, _load)
        else ...[
          StudentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final entry in _moods.entries)
                      ChoiceChip(
                        avatar: Icon(entry.value.$2),
                        label: Text(entry.value.$1),
                        selected: _mood == entry.key,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _mood = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _note,
                  enabled: !_saving,
                  maxLength: 500,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: '想写一句为什么吗？（可跳过）'),
                ),
                FilledButton(
                  onPressed: _mood == null || _saving ? null : _save,
                  child: Text(
                    _saving
                        ? '正在保存…'
                        : (current.isEmpty ? '生成今天的情绪卡' : '更新今天的情绪卡'),
                  ),
                ),
              ],
            ),
          ),
          if (_entries.isNotEmpty) ...[
            _MoodWeather(entries: _entries),
            Text('我的情绪卡', style: theme.textTheme.titleMedium),
            for (final entry in _entries)
              _JournalCard(
                entry: entry,
                remove: _saving ? null : () => _delete(entry),
              ),
          ],
        ],
      ],
    );
  }
}

class _JournalCard extends StatelessWidget {
  const _JournalCard({required this.entry, required this.remove});

  final Data entry;
  final VoidCallback? remove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mood = _moods[text(entry, 'mood')] ?? _moods['calm']!;
    final day = DateTime.tryParse(text(entry, 'day'));
    final note = text(entry, 'note');
    return StudentCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: mood.$3.withValues(alpha: 0.15),
            child: Icon(mood.$2, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mood.$1, style: theme.textTheme.titleMedium),
                if (day != null)
                  Text(
                    DateFormat('M月d日').format(day),
                    style: theme.textTheme.labelMedium,
                  ),
                if (note.isNotEmpty) Text(note),
              ],
            ),
          ),
          IconButton(
            onPressed: remove,
            tooltip: '删除情绪卡',
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}

class _MoodWeather extends StatelessWidget {
  const _MoodWeather({required this.entries});

  final List<Data> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day - 29);
    final byDay = {
      for (final row in entries) text(row, 'day'): text(row, 'mood'),
    };
    final ready = byDay.keys.any(
      (day) => day.compareTo(wellbeingDay(start)) <= 0,
    );
    if (!ready) {
      return Text(
        '第一张卡留下 30 天后，可以在这里回看情绪天气。',
        style: theme.textTheme.labelMedium,
      );
    }
    return StudentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('近 30 天情绪天气', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var offset = 0; offset < 30; offset++)
                _WeatherDay(
                  day: DateTime(start.year, start.month, start.day + offset),
                  byDay: byDay,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WeatherDay extends StatelessWidget {
  const _WeatherDay({required this.day, required this.byDay});

  final DateTime day;
  final Map<String, String> byDay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mood = _moods[byDay[wellbeingDay(day)]];
    return Tooltip(
      message: ' ${day.month}月${day.day}日 ${mood?.$1 ?? '未记录'} ',
      child: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: (mood?.$3 ?? colors.onSurfaceVariant).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(mood?.$2 ?? Icons.remove_rounded, size: 14),
      ),
    );
  }
}
