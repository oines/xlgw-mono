import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/api.dart';
import '../shared/design.dart';
import 'student_surface.dart';
import 'wellbeing.dart' show getSoundFavorites;
import 'wellbeing/common.dart';

const _moods = {
  'calm': ('平静', Icons.sentiment_satisfied_alt_outlined, Color(0xff7e9c86)),
  'happy': ('开心', Icons.wb_sunny_outlined, Color(0xffbc8a4f)),
  'tired': ('疲惫', Icons.cloud_outlined, Color(0xff7798ae)),
  'sad': ('难过', Icons.water_drop_outlined, Color(0xff9684a6)),
  'anxious': ('焦虑', Icons.air_rounded, Color(0xffa48061)),
};

DateTime _shiftDay(DateTime now, int days) =>
    DateTime(now.year, now.month, now.day + days);

class StudentProfilePage extends StatefulWidget {
  const StudentProfilePage(
    this.api,
    this.user, {
    super.key,
    required this.active,
    required this.settings,
    required this.onJournal,
    required this.onAudio,
    required this.onDaily,
  });

  final HarborApi api;
  final Data user;
  final bool active;
  final Widget Function() settings;
  final Future<void> Function(String?) onJournal;
  final Future<void> Function() onAudio;
  final VoidCallback onDaily;

  @override
  State<StudentProfilePage> createState() => _StudentProfilePageState();
}

class _StudentProfilePageState extends State<StudentProfilePage> {
  Future<(List<Data>, int)>? _overview;

  @override
  void initState() {
    super.initState();
    if (widget.active) _overview = _load();
  }

  @override
  void didUpdateWidget(covariant StudentProfilePage previous) {
    super.didUpdateWidget(previous);
    if (widget.active &&
        (!previous.active ||
            previous.api != widget.api ||
            previous.user['id'] != widget.user['id'])) {
      _overview = _load();
    }
  }

  Future<(List<Data>, int)> _load() async {
    final (journal, favorites) = await (
      widget.api.list('/wellbeing/journal?limit=30'),
      getSoundFavorites(text(widget.user, 'id')),
    ).wait;
    return (journal, favorites.length);
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _overview = next;
    });
    try {
      await next;
    } catch (_) {
      // The overview shows a retry action.
    }
  }

  Future<void> _openJournal([String? mood]) async {
    await widget.onJournal(mood);
    if (mounted) await _refresh();
  }

  Future<void> _openPrivacy() async {
    await open(context, _WellbeingPrivacyPage(widget.api));
    if (mounted) await _refresh();
  }

  Future<void> _openAudio() async {
    await widget.onAudio();
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final nickname = text(widget.user, 'nickname', '同学');
    final school = text(widget.user, 'school');
    final links = <(IconData, String, VoidCallback)>[
      (Icons.menu_book_outlined, '我的情绪日记', _openJournal),
      (Icons.headphones_rounded, '收藏的音频', _openAudio),
      (Icons.notifications_none_rounded, '每日陪伴卡', widget.onDaily),
      (Icons.lock_outline_rounded, '隐私与安全', _openPrivacy),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: HarborList(
          refresh: _refresh,
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            Row(
              children: [
                PersonIcon(
                  nickname,
                  url: text(widget.user, 'avatar_url'),
                  radius: 29,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall,
                      ),
                      Text(
                        school.isEmpty ? '学生空间' : school,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '设置',
                  onPressed: () => open(context, widget.settings()),
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FutureBuilder<(List<Data>, int)>(
              key: ValueKey(text(widget.user, 'id')),
              future: _overview,
              builder: (context, snapshot) {
                if (snapshot.hasError && !snapshot.hasData) {
                  return StudentCard(
                    child: LoadError(snapshot.error!, _refresh),
                  );
                }
                return _WeeklyOverview(
                  journal: snapshot.data?.$1,
                  favoritesCount: snapshot.data?.$2,
                  onJournal: _openJournal,
                );
              },
            ),
            const SizedBox(height: 14),
            StudentCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '今天的心情是？',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: _openJournal,
                        child: const Text('去记录'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LayoutBuilder(
                    builder: (context, constraints) => Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: 8,
                      children: [
                        for (final mood in _moods.entries)
                          SizedBox(
                            width:
                                constraints.maxWidth /
                                (constraints.maxWidth < 260 ? 3 : 5),
                            child: _MoodButton(
                              mood.value,
                              onTap: () => _openJournal(mood.key),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('我的空间', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            StudentCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final (index, (icon, label, onTap))
                      in links.indexed) ...[
                    if (index > 0) const Divider(indent: 14, endIndent: 14),
                    ListTile(
                      leading: Icon(icon, color: colors.primary, size: 20),
                      title: Text(label, style: theme.textTheme.bodyMedium),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        color: colors.onSurfaceVariant,
                        size: 20,
                      ),
                      onTap: onTap,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeeklyOverview extends StatelessWidget {
  const _WeeklyOverview({
    required this.journal,
    required this.favoritesCount,
    required this.onJournal,
  });

  final List<Data>? journal;
  final int? favoritesCount;
  final VoidCallback onJournal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final now = DateTime.now();
    final first = _shiftDay(now, 1 - now.weekday);
    final last30 = wellbeingDay(_shiftDay(now, -29));
    final byDay = {
      for (final item in journal ?? const <Data>[])
        text(item, 'day'): text(item, 'mood'),
    };
    final thisWeek = List.generate(
      7,
      (index) => wellbeingDay(_shiftDay(first, index)),
    );
    final logged = thisWeek.where(byDay.containsKey).length;
    final recent = byDay.keys
        .where(
          (date) =>
              date.compareTo(last30) >= 0 &&
              date.compareTo(wellbeingDay(now)) <= 0,
        )
        .length;
    var consecutive = 0;
    final startOffset = byDay.containsKey(wellbeingDay(now)) ? 0 : -1;
    while (consecutive < 30 &&
        byDay.containsKey(
          wellbeingDay(_shiftDay(now, startOffset - consecutive)),
        )) {
      consecutive++;
    }
    final stats = [
      (journal == null ? '—' : '$recent', '近 30 天记录'),
      (
        journal == null
            ? '—'
            : consecutive == 30
            ? '30+'
            : '$consecutive',
        '连续记录',
      ),
      (favoritesCount == null ? '—' : '$favoritesCount', '收藏音频'),
    ];
    return Column(
      children: [
        StudentCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (value, label) in stats)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        value,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        StudentCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('本周情绪', style: theme.textTheme.titleMedium),
                  ),
                  TextButton(onPressed: onJournal, child: const Text('查看记录')),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (final (index, day) in thisWeek.indexed)
                    Expanded(
                      child: _MoodDay(
                        weekday: '一二三四五六日'[index],
                        mood: byDay[day],
                        today: day == wellbeingDay(now),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                journal == null
                    ? '正在读取记录…'
                    : logged == 0
                    ? '本周还没有记录'
                    : '本周已记录 $logged 天',
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MoodDay extends StatelessWidget {
  const _MoodDay({
    required this.weekday,
    required this.mood,
    required this.today,
  });

  final String weekday;
  final String? mood;
  final bool today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final choice = _moods[mood];
    return Tooltip(
      message: '周$weekday：${choice?.$1 ?? '未记录'}',
      child: Column(
        children: [
          SizedBox(
            height: 50,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: 16,
                height: choice == null ? 12 : 46,
                decoration: BoxDecoration(
                  color: choice?.$3 ?? colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            weekday,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: today ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MoodButton extends StatelessWidget {
  const _MoodButton(this.mood, {required this.onTap});

  final (String, IconData, Color) mood;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, icon, shade) = mood;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: shade.withValues(alpha: .17),
              foregroundColor: theme.colorScheme.onSurface,
              child: Icon(icon, size: 18),
            ),
            const SizedBox(height: 3),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _WellbeingPrivacyPage extends StatefulWidget {
  const _WellbeingPrivacyPage(this.api);

  final HarborApi api;

  @override
  State<_WellbeingPrivacyPage> createState() => _WellbeingPrivacyPageState();
}

class _WellbeingPrivacyPageState extends State<_WellbeingPrivacyPage> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final records = await widget.api.request('/wellbeing/export');
      if (!mounted) return;
      final json = const JsonEncoder.withIndent('  ').convert(records);
      await open(context, _WellbeingExportPage(json));
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await confirmAction(
      context,
      '清除情绪与睡眠记录',
      '此操作会永久删除当前账号的全部情绪日记和睡眠记录。',
      confirm: '永久清除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.delete('/wellbeing/data');
      if (mounted) flash(context, '情绪日记和睡眠记录已清除');
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WellbeingPage(
      title: '隐私与安全',
      children: [
        const WellbeingIntro('你的情绪与睡眠记录', '在这里查看、导出和清除当前账号保存的记录。'),
        StudentCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('记录范围', style: theme.textTheme.titleMedium),
              const SizedBox(height: 5),
              const Text('情绪日记保存日期、心情标签和你选择填写的正文。睡眠记录保存日期和入睡时间。'),
              const SizedBox(height: 8),
              Text(
                '应用将这些记录保存在当前账号下。记录不会自动发布到社区、交给 AI 或分享给校内支持人员。',
                style: theme.textTheme.bodyMedium,
              ),
              if (!harborOffline) ...[
                const SizedBox(height: 8),
                const Text(
                  '新建的个人 AI 对话在创建 7 天后到期。之前的对话可以在会话历史中删除。已分享的副本按服务授权保留。',
                ),
              ],
            ],
          ),
        ),
        StudentCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('导出记录'),
                subtitle: const Text('预览 JSON，按需复制到剪贴板'),
                onTap: _busy ? null : _export,
              ),
              const Divider(indent: 14, endIndent: 14),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  '清除记录',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                subtitle: const Text('清除当前账号的全部情绪日记和睡眠记录'),
                onTap: _busy ? null : _delete,
              ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}

class _WellbeingExportPage extends StatelessWidget {
  const _WellbeingExportPage(this.json);

  final String json;

  @override
  Widget build(BuildContext context) => WellbeingPage(
    title: '导出记录',
    children: [
      const Text('JSON 内含你的情绪日记和睡眠记录。请妥善保管复制后的内容。'),
      FilledButton.tonalIcon(
        onPressed: () async {
          try {
            await Clipboard.setData(ClipboardData(text: json));
            if (context.mounted) flash(context, '已复制 JSON');
          } catch (error) {
            if (context.mounted) flash(context, '暂时无法复制，请重试');
          }
        },
        icon: const Icon(Icons.copy_rounded),
        label: const Text('复制 JSON'),
      ),
      StudentCard(child: SelectableText(json)),
    ],
  );
}
