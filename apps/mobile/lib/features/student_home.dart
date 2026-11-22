import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/api.dart';
import '../shared/design.dart';

enum HarborShortcut {
  journal('情绪日记', Icons.menu_book_outlined),
  audio('轻松听', Icons.headphones_outlined),
  questions('测一测', Icons.assignment_outlined),
  daily('每日推送', Icons.notifications_none_rounded),
  plaza('情绪广场', Icons.public_rounded),
  sleep('助眠模式', Icons.nightlight_outlined),
  pet('宠物模式', Icons.pets_outlined),
  breathing('呼吸练习', Icons.air_rounded);

  const HarborShortcut(this.label, this.icon);
  final String label;
  final IconData icon;
}

class StudentShortcuts extends StatefulWidget {
  const StudentShortcuts({
    super.key,
    required this.accountId,
    required this.onSelect,
  });

  final String accountId;
  final ValueChanged<HarborShortcut> onSelect;

  @override
  State<StudentShortcuts> createState() => _StudentShortcutsState();
}

class _StudentShortcutsState extends State<StudentShortcuts> {
  List<HarborShortcut> pinned = [];
  String get preferenceKey => 'harbor.shortcuts.${widget.accountId}';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final names = preferences.getStringList(preferenceKey) ?? [];
    if (!mounted) return;
    setState(() {
      pinned = [
        for (final name in names)
          ...HarborShortcut.values.where((entry) => entry.name == name),
      ].take(3).toList();
    });
  }

  Future<void> customize() async {
    final choice = List<HarborShortcut>.of(pinned);
    final selected = await showModalBottomSheet<List<HarborShortcut>>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              Text('常用快捷入口', style: Theme.of(context).textTheme.titleLarge),
              const Text('按希望的顺序选择，最多三个。'),
              for (final entry in HarborShortcut.values)
                CheckboxListTile(
                  title: Text(entry.label),
                  secondary: Icon(entry.icon),
                  value: choice.contains(entry),
                  onChanged: choice.contains(entry) || choice.length < 3
                      ? (value) => update(() {
                          if (value == true) {
                            choice.add(entry);
                          } else {
                            choice.remove(entry);
                          }
                        })
                      : null,
                ),
              FilledButton(
                onPressed: () => Navigator.pop(context, choice),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      preferenceKey,
      selected.map((entry) => entry.name).toList(),
    );
    if (mounted) setState(() => pinned = selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final entries = [
      ...pinned,
      ...HarborShortcut.values.where((e) => !pinned.contains(e)),
    ];
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text('快捷疗愈', style: theme.textTheme.titleMedium)),
            TextButton(onPressed: customize, child: const Text('调整常用入口')),
          ],
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: entries.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 10,
            crossAxisSpacing: 8,
            mainAxisExtent: 78,
          ),
          itemBuilder: (context, index) {
            final entry = entries[index];
            return Material(
              color: colors.surface,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => widget.onSelect(entry),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: studentTint(context, entry.index),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: Icon(
                          entry.icon,
                          size: 19,
                          color: colors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class PetPage extends StatefulWidget {
  const PetPage(this.api, this.accountId, {super.key});
  final HarborApi api;
  final String accountId;

  @override
  State<PetPage> createState() => _PetPageState();
}

class _PetPageState extends State<PetPage> {
  bool adopted = false;
  bool ready = false;
  String? mood;
  String? reaction;
  String get preferenceKey => 'harbor.pet.${widget.accountId}';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      adopted = preferences.getBool(preferenceKey) == true;
      ready = true;
    });
    try {
      final entries = await widget.api.list('/wellbeing/journal?limit=1');
      if (mounted && entries.isNotEmpty) {
        setState(() => mood = text(entries.first, 'mood'));
      }
    } on ApiError {
      // The pet can stay with the user without a journal entry.
    }
  }

  Future<void> adopt() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(preferenceKey, true);
    if (mounted) setState(() => adopted = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle =
        reaction ??
        switch (mood) {
          'sad' || 'tired' || 'anxious' => '它把脚步放轻，安静地坐在你旁边。',
          'happy' => '它看到你，轻轻晃了晃尾巴。',
          _ => '它在这里陪你待一会儿。',
        };
    return Scaffold(
      appBar: AppBar(title: const Text('宠物模式')),
      body: SafeArea(
        child: HarborList(
          children: [
            Card(
              elevation: 0,
              clipBehavior: Clip.antiAlias,
              color: studentTint(context, 2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: AspectRatio(
                aspectRatio: 1.1,
                child: Image.asset(
                  'assets/student/calm-cat.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(
                    child: Icon(
                      Icons.pets_outlined,
                      size: 72,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '小眠',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              adopted ? subtitle : '领一只小猫，在想安静的时候来看看它。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            if (ready && !adopted)
              FilledButton(onPressed: adopt, child: const Text('领养小眠'))
            else if (adopted)
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  for (final (label, icon, response) in const [
                    ('喂食', Icons.restaurant_outlined, '小眠吃了几口，又坐回你身边。'),
                    ('抚摸', Icons.favorite_border_rounded, '小眠蹭了蹭你的手。'),
                    ('睡觉', Icons.bedtime_outlined, '小眠蜷起尾巴，慢慢睡着了。'),
                  ])
                    OutlinedButton.icon(
                      onPressed: () => setState(() => reaction = response),
                      icon: Icon(icon, size: 18),
                      label: Text(label),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
