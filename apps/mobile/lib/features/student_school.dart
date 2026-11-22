import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/api.dart';
import '../shared/design.dart';
import 'resources.dart';
import 'student_surface.dart';

typedef _Course = ({
  String id,
  String title,
  String category,
  String description,
  IconData icon,
  List<(String, String)> lessons,
});

const _courses = <_Course>[
  (
    id: 'emotion-settling',
    title: '7 天情绪安顿计划',
    category: '情绪认知',
    description: '每天一个小练习，慢慢回到当下',
    icon: Icons.spa_outlined,
    lessons: [
      ('看见今天的情绪', '给此刻最强烈的感受起一个名字。找不到合适的词时，也可以只描述身体的感觉。'),
      ('留意脚下', '把脚放在地面上。感受鞋底和地面的接触，再把注意力移到身体坐着的地方。'),
      ('停一小会儿', '稍微放松肩膀。按平时的节奏呼吸，安静地感受两三次呼气。'),
      ('找一个支点', '环顾四周，找到一样让你觉得熟悉或安稳的东西。留意它的颜色、形状和质地。'),
      ('说清自己的需要', '想一想，此刻最想得到的是休息、陪伴还是一点独处的时间。给这个需要留一点空间。'),
      ('给今天留下一句', '记下一件今天值得记得的小事，再想想今天有哪些事情可以留到明天。'),
      ('挑一个想留下的练习', '回顾前几天的练习，选一个自己愿意再试的。需要时也可以回到这一页。'),
    ],
  ),
  (
    id: 'anxiety',
    title: '和焦虑做朋友',
    category: '情绪认知',
    description: '辨认担心，找到眼下做得了的小事',
    icon: Icons.psychology_alt_outlined,
    lessons: [
      ('辨认担心', '想起刚刚让你不安的事，试着用一句话描述自己的担心。'),
      ('把眼前的事列出来', '区分已经发生的事和还在担心的事。看看眼前有什么具体的事情可以处理。'),
      ('选择一个下一步', '从能做到的事情里挑一件很小的事，比如喝水、写一句笔记，或找信任的人聊聊。'),
    ],
  ),
  (
    id: 'sleep-scan',
    title: '睡前身体扫描',
    category: '睡眠修复',
    description: '把注意力从忙碌的一天带回身体',
    icon: Icons.bedtime_outlined,
    lessons: [
      ('找一个舒适的姿势', '可以坐着或躺下。把手机亮度调低，保持呼吸自在。'),
      ('从脚到肩慢慢感受', '依次留意脚趾、小腿、背部和肩膀。只观察这些地方此刻的感觉。'),
      ('给自己留一点安静', '把注意力放回全身。如果思绪跑开，可以慢慢回到当下的呼吸。'),
    ],
  ),
  (
    id: 'emotion-words',
    title: '把情绪说出来',
    category: '冥想放松',
    description: '用容易开口的方式描述此刻感受',
    icon: Icons.forum_outlined,
    lessons: [
      ('先说发生了什么', '选一件让你印象深刻的事。试着先说经过，再说自己当时的感觉。'),
      ('用一两句话表达', '试试「当……发生时，我感到……，我希望……」。也可以先写给自己。'),
    ],
  ),
  (
    id: 'exam-week',
    title: '考试周的第一步',
    category: '情绪认知',
    description: '面对考试和复习压力，先把范围缩到今天',
    icon: Icons.assignment_outlined,
    lessons: [
      ('把待办写小', '写下最担心的一门课，在后面只加一个十分钟内可以做到的动作，例如做两道题。'),
      ('给自己一个停点', '定下今天切实能做到的复习结束时间。把明天想继续的题目写在纸上，到点先收好书。'),
    ],
  ),
  (
    id: 'after-a-setback',
    title: '一次没做好以后',
    category: '情绪认知',
    description: '把一次挫折和对自己的评价放在两栏',
    icon: Icons.replay_rounded,
    lessons: [
      ('写下具体经过', '在左栏写可核实的经过，例如作业少交了一项。在右栏写脑海里的评价，再圈出两栏之间的区别。'),
      ('留下一次调整', '选一个下一次能调整的细节，例如提交前对照清单。把它写成一句提醒。'),
    ],
  ),
  (
    id: 'friendship',
    title: '朋友之间没说清的事',
    category: '情绪认知',
    description: '给同学和朋友之间的误会留一个问句',
    icon: Icons.people_outline_rounded,
    lessons: [
      ('拆开事实和猜测', '写下对方实际说过的话，再写你当时怎么理解。用不同的记号标出这两部分。'),
      ('改成一句澄清', '试着写「我当时理解为……，你是这个意思吗？」。可以先记下来，等双方方便时再说。'),
    ],
  ),
  (
    id: 'family-conversation',
    title: '和家人聊一个具体请求',
    category: '情绪认知',
    description: '把家庭沟通里的期待说成可以讨论的请求',
    icon: Icons.home_outlined,
    lessons: [
      ('只选一个情境', '选这周一次家里发生的具体事情，写下你希望下次怎么做，例如「晚饭后给我二十分钟整理作业」。'),
      ('找合适的开口时间', '想两个双方都可能有空的时间，从「我想说一件小事，你现在方便听吗？」开始。'),
    ],
  ),
  (
    id: 'say-no-kindly',
    title: '有礼貌地说不',
    category: '情绪认知',
    description: '面对邀约和额外任务，练习表达关系边界',
    icon: Icons.pan_tool_outlined,
    lessons: [
      ('先核对自己的余量', '想起一件你还没回复的邀约，写下你手上的任务和愿意投入的时间。'),
      ('把边界说具体', '练习一句「谢谢你想到我，我今天没法参加」，或给出你确实有空的其他时间。'),
    ],
  ),
  (
    id: 'time-overload',
    title: '事情太多时怎么排',
    category: '情绪认知',
    description: '用一张纸安排时间，把今天的任务分层',
    icon: Icons.schedule_rounded,
    lessons: [
      ('做一张三栏清单', '写下近期的待办，分到「今天要做」「可以改期」「需要问别人」三栏。'),
      ('先做一件短任务', '从今天栏选一件最明确的事，圈出开始时间。剩下的待办留到下一次整理。'),
    ],
  ),
  (
    id: 'new-environment',
    title: '在新环境里认一个角落',
    category: '冥想放松',
    description: '刚开学、换班或入住宿舍时做一次小探索',
    icon: Icons.explore_outlined,
    lessons: [
      ('走一条熟悉路线', '找一条三五分钟能走完的路线，记住一个容易辨认的标志。'),
      ('留一个可回去的地点', '选一个你愿意再来的地方，记下路线和合适的时间，例如课间经过的长椅。'),
    ],
  ),
  (
    id: 'when-alone',
    title: '一个人也想被陪一会儿',
    category: '情绪认知',
    description: '感到孤单时，分辨想要哪种陪伴',
    icon: Icons.diversity_3_outlined,
    lessons: [
      ('写出想要的陪伴', '在纸上写下你更想被听一听、一起做件事，还是先安静待会儿。'),
      ('准备一个小邀请', '如果想联系别人，试着写一句具体的话，例如「下午有空一起走一圈吗？」。'),
    ],
  ),
  (
    id: 'before-replying',
    title: '生气时先留十秒',
    category: '冥想放松',
    description: '在冲突和回消息之间放进一个短暂停顿',
    icon: Icons.pause_circle_outline_rounded,
    lessons: [
      ('把手离开键盘', '数十秒，放松咬紧的下巴。已经写好的回话，可以先留在草稿里。'),
      ('留一句现在能说的话', '读一遍草稿，改成说明现状的一句，例如「我现在有点生气，晚一点再聊这件事」。'),
    ],
  ),
  (
    id: 'catching-comparison',
    title: '刷到别人时，回到自己的节奏',
    category: '情绪认知',
    description: '察觉社交媒体上的比较，记一件自己的进展',
    icon: Icons.phone_android_rounded,
    lessons: [
      ('辨认开始比较的时刻', '停在让你产生比较的一条内容，写下「我看到的是……，我正在担心的是……」。'),
      ('写一条自己的事实', '把屏幕放下，记一件今天由你完成的事情，哪怕只是回了一条消息或按时吃饭。'),
    ],
  ),
  (
    id: 'five-senses',
    title: '用五感看看此刻',
    category: '冥想放松',
    description: '课间做一次短观察，把注意力放回身边',
    icon: Icons.remove_red_eye_outlined,
    lessons: [
      ('先看，再听', '找出三种看见的颜色和两种听见的声音。在心里慢慢念出它们。'),
      ('留意一处接触', '留意手指碰到的材质，或鞋底下的地面。用一个词形容它。'),
    ],
  ),
  (
    id: 'sleep-parking-lot',
    title: '睡前把待办留到明天',
    category: '睡眠修复',
    description: '用简短的睡前笔记收好还在惦记的事',
    icon: Icons.edit_note_rounded,
    lessons: [
      ('写下三件还在想的事', '用短词写即可。给每件事标上能处理它的时间，例如明早九点。'),
      ('给纸条找一个位置', '把纸条放到醒来能看见的地方。现在选一件容易停下来的小事，比如关掉桌灯。'),
    ],
  ),
  (
    id: 'evening-screen',
    title: '睡前给屏幕一个停点',
    category: '睡眠修复',
    description: '安排离开屏幕的时间和随手能做的替代动作',
    icon: Icons.brightness_4_outlined,
    lessons: [
      ('选今晚的一个节点', '决定在一个可记住的节点停下，比如刷完当前内容，或闹钟响时。'),
      ('把替代动作放到手边', '提前放好一本纸质读物或一杯水。到了停点，先把手机放到准备的位置。'),
    ],
  ),
  (
    id: 'small-recovery',
    title: '给精力留一个小空档',
    category: '冥想放松',
    description: '在日程中留出三分钟，选一件可以短暂停下的事',
    icon: Icons.energy_savings_leaf_outlined,
    lessons: [
      ('找一个自然的间隔', '在两个活动之间留出三分钟，例如下课到下一节开始前。'),
      ('用一件容易开始的小事', '在这段时间喝水、靠一会椅背，或站到窗边。到点再决定接下来做什么。'),
    ],
  ),
];

class StudentSchoolPage extends StatefulWidget {
  const StudentSchoolPage(
    this.api, {
    super.key,
    this.accountId = '',
    this.heroAsset,
    this.onAudio,
    this.onBreathing,
  });

  final HarborApi api;
  final String accountId;
  final String? heroAsset;
  final VoidCallback? onAudio, onBreathing;

  @override
  State<StudentSchoolPage> createState() => _StudentSchoolPageState();
}

class _StudentSchoolPageState extends State<StudentSchoolPage> {
  late final _storage = SharedPreferences.getInstance();
  String _category = '全部';
  String _query = '';
  bool _searching = false;
  bool _showAll = false;
  Map<String, int> _progress = {};
  late Future<void> _progressLoaded;
  late Future<List<Data>> _resources = widget.api.list('/resources');

  String _progressKey(String id) => 'harbor.course.${widget.accountId}.$id';

  @override
  void initState() {
    super.initState();
    _progressLoaded = _readProgress();
  }

  Future<void> _readProgress() async {
    try {
      final storage = await _storage;
      if (mounted) {
        setState(() {
          _progress = {
            for (final course in _courses)
              course.id: (storage.getInt(_progressKey(course.id)) ?? 0).clamp(
                0,
                course.lessons.length,
              ),
          };
        });
      }
    } catch (_) {
      // App resources and lessons remain available when storage is unavailable.
    }
  }

  Future<void> _refresh() async {
    final next = widget.api.list('/resources');
    setState(() {
      _resources = next;
    });
    try {
      await next;
    } catch (_) {
      // The resources section exposes its own retry state.
    }
  }

  Future<void> _openCourse(_Course course) async {
    await _progressLoaded;
    if (!mounted) return;
    final initial = _progress[course.id] ?? 0;
    await open(
      context,
      _CourseDetail(
        course,
        completed: initial,
        onComplete: (completed) async {
          final storage = await _storage;
          if (!await storage.setInt(_progressKey(course.id), completed)) {
            throw StateError('无法保存课程进度');
          }
          if (mounted) setState(() => _progress[course.id] = completed);
        },
      ),
    );
  }

  bool _matches(_Course course) =>
      (_category == '全部' || course.category == _category) &&
      (course.title.contains(_query) ||
          course.description.contains(_query) ||
          course.category.contains(_query));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final filtered = _category != '全部' || _query.isNotEmpty;
    final matching = _courses.skip(1).where(_matches);
    final visible = _showAll || filtered ? matching : matching.take(3);
    final featured = _courses.first;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: HarborList(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          refresh: _refresh,
          children: [
            StudentTabHeader(
              '心灵学堂',
              subtitle: '慢一点，也是在往前走',
              action: IconButton.filledTonal(
                tooltip: _searching ? '关闭搜索' : '搜索学堂',
                style: IconButton.styleFrom(
                  backgroundColor: colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _query = '';
                }),
                icon: Icon(_searching ? Icons.close : Icons.search_rounded),
              ),
            ),
            if (_searching) ...[
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                onChanged: (value) => setState(() => _query = value.trim()),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: '搜索课程与资源',
                ),
              ),
            ],
            const SizedBox(height: 10),
            StudentFilters(
              options: const ['全部', '情绪认知', '冥想放松', '睡眠修复'],
              selected: _category,
              onSelect: (category) => setState(() => _category = category),
            ),
            const SizedBox(height: 12),
            if (_matches(featured)) ...[
              _SchoolHero(
                asset: widget.heroAsset,
                course: featured,
                completed: _progress[featured.id] ?? 0,
                onTap: () => _openCourse(featured),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Expanded(
                  child: Text('系统课程', style: theme.textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _showAll = filtered || !_showAll;
                    _category = '全部';
                    _searching = false;
                    _query = '';
                  }),
                  child: Text(_showAll && !filtered ? '收起' : '查看全部'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (visible.isEmpty && !_matches(featured))
              const Empty('暂时没有相关课程', icon: Icons.school_outlined),
            for (final course in visible) ...[
              _CourseCard(
                course: course,
                completed: _progress[course.id] ?? 0,
                onTap: () => _openCourse(course),
              ),
              const SizedBox(height: 10),
            ],
            if (_query.isEmpty &&
                (_category == '全部' || _category == '睡眠修复')) ...[
              const SizedBox(height: 4),
              Text(
                widget.onAudio != null ? '睡前音频' : '睡前练习',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _PracticeCard(
                      title: widget.onAudio != null ? '雨落屋檐的声音' : '睡前安顿',
                      caption: widget.onAudio != null
                          ? '助眠 · 白噪声'
                          : '放松 · 睡前练习',
                      icon: widget.onAudio != null
                          ? Icons.headphones_rounded
                          : Icons.bedtime_outlined,
                      tint: colors.primaryContainer,
                      onTap: widget.onAudio ?? () => _openCourse(_courses[2]),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PracticeCard(
                      title: '呼吸引导',
                      caption: '跟随提示慢一点',
                      icon: Icons.air_rounded,
                      tint: theme.brightness == Brightness.dark
                          ? colors.tertiaryContainer
                          : const Color(0xffe9f0f5),
                      onTap: widget.onBreathing ?? () => _openCourse(featured),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Text('校内资源', style: theme.textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => open(context, ResourcesPage(widget.api)),
                  child: const Text('更多资源'),
                ),
              ],
            ),
            FutureBuilder<List<Data>>(
              future: _resources,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return LoadError(snapshot.error!, _refresh);
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final resources = snapshot.data!
                    .where(
                      (item) =>
                          text(item, 'title').contains(_query) ||
                          text(item, 'body').contains(_query),
                    )
                    .take(3);
                if (resources.isEmpty) {
                  return Text('暂时没有相关校内资源', style: theme.textTheme.labelMedium);
                }
                return Column(
                  children: [
                    for (final resource in resources)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: StudentCard(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            title: Text(text(resource, 'title')),
                            subtitle: Text(
                              text(resource, 'body'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                open(context, ResourceDetail(resource)),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SchoolHero extends StatelessWidget {
  const _SchoolHero({
    required this.asset,
    required this.course,
    required this.completed,
    required this.onTap,
  });

  final String? asset;
  final _Course course;
  final int completed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StudentCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xff374b40), Color(0xff976f53)],
                ),
              ),
              child: asset == null
                  ? null
                  : Image.asset(
                      asset!,
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xd9202a22), Color(0x33202a22)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x33ffffff),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    '本周精选',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  course.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  course.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xfffcf8ed),
                  ),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.white,
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Color(0xff2f4737),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '已完成 $completed/${course.lessons.length} 节',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({
    required this.course,
    required this.completed,
    required this.onTap,
  });

  final _Course course;
  final int completed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final percent = (100 * completed / course.lessons.length).round();
    return StudentCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(course.icon, color: colors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(course.title, style: theme.textTheme.titleMedium),
                Text(
                  '${course.lessons.length} 节 · 已学 $percent%',
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
          Icon(Icons.play_arrow_outlined, color: colors.primary),
        ],
      ),
    );
  }
}

class _PracticeCard extends StatelessWidget {
  const _PracticeCard({
    required this.title,
    required this.caption,
    required this.icon,
    required this.tint,
    required this.onTap,
  });

  final String title, caption;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StudentCard(
      color: tint,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 20),
          const SizedBox(height: 6),
          Text(title, style: theme.textTheme.titleMedium),
          Text(caption, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _CourseDetail extends StatefulWidget {
  const _CourseDetail(
    this.course, {
    required this.completed,
    required this.onComplete,
  });

  final _Course course;
  final int completed;
  final Future<void> Function(int) onComplete;

  @override
  State<_CourseDetail> createState() => _CourseDetailState();
}

class _CourseDetailState extends State<_CourseDetail> {
  late int _completed = widget.completed;
  bool _saving = false;

  Future<void> _markComplete() async {
    setState(() => _saving = true);
    try {
      await widget.onComplete(_completed + 1);
      if (mounted) setState(() => _completed += 1);
    } catch (_) {
      if (mounted) flash(context, '暂时无法保存进度，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final course = widget.course;
    return Scaffold(
      appBar: AppBar(title: Text(course.title)),
      body: HarborList(
        children: [
          Text(course.description, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _completed / course.lessons.length),
          const SizedBox(height: 6),
          Text(
            '已完成 $_completed/${course.lessons.length} 节',
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 12),
          for (final (i, (title, body)) in course.lessons.indexed) ...[
            StudentCard(
              key: ValueKey((i, i == _completed)),
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                initiallyExpanded: i == _completed,
                shape: const Border(),
                collapsedShape: const Border(),
                leading: Icon(
                  i < _completed
                      ? Icons.check_circle_outline_rounded
                      : Icons.play_circle_outline_rounded,
                ),
                title: Text(title),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(body, style: theme.textTheme.bodyLarge),
                  ),
                  if (i == _completed) ...[
                    const SizedBox(height: 10),
                    FilledButton.tonal(
                      onPressed: _saving ? null : _markComplete,
                      child: const Text('完成这一节'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
