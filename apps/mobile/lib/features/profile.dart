import '../companion/image.dart';
import 'package:flutter/material.dart';

import '../companion/editor.dart';
import '../shared/api.dart';
import '../shared/design.dart';
import 'care.dart';
import 'resources.dart';
import 'community.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage(
    this.api,
    this.user, {
    super.key,
    required this.work,
    required this.space,
    required this.onSpace,
    required this.onUser,
    required this.onLogout,
  });
  final HarborApi api;
  final Data user;
  final bool work;
  final String space;
  final ValueChanged<String> onSpace;
  final ValueChanged<Data> onUser;
  final VoidCallback onLogout;
  @override
  State<ProfilePage> createState() => _ProfileState();
}

class _ProfileState extends State<ProfilePage> {
  Data quota = {}, avatar = {};
  Object? quotaError;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (widget.work) return;
    try {
      final results = await Future.wait([
        widget.api.request('/ai/quota'),
        widget.api.request('/avatars/me'),
      ]);
      if (mounted)
        setState(() {
          quota = results.first;
          avatar = data(results.last['config']);
          quotaError = null;
        });
    } catch (e) {
      if (mounted) setState(() => quotaError = e);
    }
  }

  Future<void> update(Data body) async {
    try {
      final user = await widget.api.patch('/me', body);
      if (mounted) {
        widget.onUser(user);
        flash(context, '已保存');
      }
    } catch (e) {
      if (mounted) flash(context, e);
    }
  }

  Future<void> preference(
    String title,
    String key,
    List<(String, String)> values,
  ) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            for (final item in values)
              ListTile(
                title: Text(item.$2),
                trailing: widget.user[key] == item.$1
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, item.$1),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (selected != null && mounted) await update({key: selected});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context), user = widget.user;
    final name = text(user, 'nickname');
    final roles = (user['roles'] as List? ?? [])
        .map((e) => e.toString())
        .where((e) => e != 'admin')
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: HarborList(
        refresh: load,
        children: [
          Surface(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                PersonIcon(name, url: text(user, 'avatar_url'), radius: 32),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: t.textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      Text(
                        widget.work
                            ? '${text(user, 'school')} · ${roleName(widget.space)}'
                            : text(user, 'school'),
                        style: t.textTheme.bodyMedium?.copyWith(
                          color: t.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '编辑个人资料',
                  onPressed: () async {
                    final changed = await open<Data>(
                      context,
                      AccountProfile(widget.api, widget.user),
                    );
                    if (mounted && changed != null) widget.onUser(changed);
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
          ),
          if (roles.length > 1) ...[
            const SizedBox(height: 12),
            bordered(
              ListTile(
                leading: const Icon(Icons.swap_horiz_rounded),
                title: const Text('切换使用空间'),
                subtitle: Text(roleName(widget.space)),
                trailing: const Icon(Icons.expand_more),
                onTap: () {
                  showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    builder: (ctx) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final r in roles)
                            ListTile(
                              title: Text(
                                r == 'student' ? '学生空间' : roleName(r),
                              ),
                              selected: r == widget.space,
                              onTap: () {
                                Navigator.pop(ctx);
                                widget.onSpace(r);
                              },
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 22),
          if (widget.work) ...[
            section('接待与安排', [
              row(
                '接待资料',
                Icons.badge_outlined,
                () => open(context, StaffProfile(widget.api)),
              ),
              row(
                '排班',
                Icons.calendar_today_outlined,
                () => open(context, SlotEditor(widget.api)),
              ),
              row(
                '服务回访',
                Icons.fact_check_outlined,
                () => open(context, FollowupsPage(widget.api, work: true)),
              ),
              if (widget.space == 'teacher')
                row(
                  '人工联系请求',
                  Icons.support_agent_rounded,
                  () => open(context, HelpPage(widget.api, work: true)),
                ),
            ]),
          ] else ...[
            section('校内支持', [
              row(
                '我的预约',
                Icons.calendar_today_outlined,
                () => open(context, AppointmentsPage(widget.api)),
              ),
              row(
                '服务回访',
                Icons.fact_check_outlined,
                () => open(context, FollowupsPage(widget.api)),
              ),
              row(
                '人工联系',
                Icons.support_agent_rounded,
                () => open(context, HelpPage(widget.api)),
              ),
              row(
                '已分享的 AI 内容',
                Icons.ios_share_rounded,
                () => open(context, SharedNotes(widget.api)),
              ),
            ]),
            const SizedBox(height: 20),
            section('内容与偏好', [
              row(
                '伙伴形象',
                Icons.face_retouching_natural,
                () async {
                  await open(
                    context,
                    AvatarEditor(
                      widget.api,
                      motion: text(user, 'motion', 'standard'),
                    ),
                  );
                  if (mounted) await load();
                },
                extra: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: CompanionImage(
                    'poster-${text(avatar, 'preset', 'clear')}.png',
                    width: 34,
                    height: 34,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              row(
                '今日 AI 次数',
                Icons.bolt_outlined,
                load,
                extra: Text(
                  quotaError != null
                      ? '点击重试'
                      : quota['enabled'] == false
                      ? '已暂停'
                      : quota.isEmpty
                      ? '…'
                      : '剩余 ${quota['remaining']} / ${quota['daily_limit']}',
                ),
              ),
              row(
                '我的帖子与评论',
                Icons.forum_outlined,
                () => open(context, MyCommunity(widget.api, user)),
              ),
              row(
                '屏蔽列表',
                Icons.person_off_outlined,
                () => open(context, BlockedPeople(widget.api)),
              ),
              row(
                '学校资源与活动',
                Icons.collections_bookmark_outlined,
                () => open(context, ResourcesPage(widget.api)),
              ),
            ]),
          ],
          const SizedBox(height: 20),
          section('账号与帮助', [
            row(
              '外观',
              Icons.dark_mode_outlined,
              () => preference('外观', 'theme', const [
                ('system', '跟随系统'),
                ('light', '浅色'),
                ('dark', '深色'),
              ]),
              extra: Text(
                const {
                      'system': '跟随系统',
                      'dark': '深色',
                      'light': '浅色',
                    }[user['theme']] ??
                    '跟随系统',
              ),
            ),
            row(
              '伙伴动作',
              Icons.motion_photos_on_outlined,
              () => preference('伙伴动作', 'motion', const [
                ('standard', '标准'),
                ('subtle', '轻微'),
                ('still', '静止'),
              ]),
              extra: Text(
                const {
                      'standard': '标准',
                      'subtle': '轻微',
                      'still': '静止',
                    }[user['motion']] ??
                    '标准',
              ),
            ),
            if (!harborOffline)
              row(
                '修改密码',
                Icons.lock_outline,
                () => open(context, PasswordPage(widget.api)),
              ),
            row(
              '应用反馈',
              Icons.mail_outline,
              () => open(context, FeedbackPage(widget.api)),
            ),
            row('退出登录', Icons.logout_rounded, () async {
              final yes = await confirmAction(
                context,
                '退出登录？',
                harborOffline ? '聊天、形象和预约保存在这台设备。' : '聊天、形象和预约仍保存在账号中。',
                confirm: '退出',
              );
              if (yes && mounted) widget.onLogout();
            }),
          ]),
          const SizedBox(height: 20),
          Center(
            child: Text(
              harborOffline ? '心灵港湾 · 离线体验' : '心灵港湾 1.0',
              style: t.textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget bordered(Widget child) =>
      Surface(padding: EdgeInsets.zero, child: child);
  Widget section(String title, List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(3, 0, 0, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      bordered(
        Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(indent: 52),
              rows[i],
            ],
          ],
        ),
      ),
    ],
  );
  Widget row(String title, IconData icon, VoidCallback tap, {Widget? extra}) =>
      ListTile(
        minTileHeight: 55,
        leading: Icon(icon, size: 21),
        title: Text(title),
        onTap: tap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (extra != null) ...[extra, const SizedBox(width: 7)],
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      );
}

class AccountProfile extends StatefulWidget {
  const AccountProfile(this.api, this.user, {super.key});
  final HarborApi api;
  final Data user;
  @override
  State<AccountProfile> createState() => _AccountProfileState();
}

class _AccountProfileState extends State<AccountProfile> {
  late final nickname = TextEditingController(
    text: text(widget.user, 'nickname'),
  );
  late final avatar = TextEditingController(
    text: text(widget.user, 'avatar_url'),
  );
  bool busy = false;
  @override
  void dispose() {
    nickname.dispose();
    avatar.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (nickname.text.trim().isEmpty) {
      flash(context, '请填写昵称');
      return;
    }
    setState(() => busy = true);
    try {
      final u = await widget.api.patch('/me', {
        'nickname': nickname.text.trim(),
        'avatar_url': avatar.text.trim(),
      });
      if (mounted) Navigator.pop(context, u);
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('个人资料')),
    body: HarborList(
      children: [
        TextField(
          controller: nickname,
          maxLength: 32,
          decoration: const InputDecoration(labelText: '昵称'),
        ),
        if (!harborOffline) ...[
          const SizedBox(height: 12),
          TextField(
            controller: avatar,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '头像图片链接（选填）'),
          ),
        ],
        const SizedBox(height: 20),
        Text('学校 · ${text(widget.user, 'school')}'),
        const SizedBox(height: 8),
        Text('账号 · ${text(widget.user, 'account')}'),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '正在保存…' : '保存资料'),
        ),
      ],
    ),
  );
}

class PasswordPage extends StatefulWidget {
  const PasswordPage(this.api, {super.key});
  final HarborApi api;
  @override
  State<PasswordPage> createState() => _PasswordState();
}

class _PasswordState extends State<PasswordPage> {
  final before = TextEditingController(),
      after = TextEditingController(),
      repeat = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    before.dispose();
    after.dispose();
    repeat.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (after.text.length < 8 || before.text.isEmpty) {
      flash(context, '请填写当前密码，设置至少 8 位的新密码');
      return;
    }
    if (after.text != repeat.text) {
      flash(context, '两次新密码不同');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.api.post('/me/password', {
        'old_password': before.text,
        'new_password': after.text,
      });
      if (mounted) {
        flash(context, '密码已更新');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('修改密码')),
    body: HarborList(
      children: [
        for (final e in [
          (before, '当前密码'),
          (after, '新密码'),
          (repeat, '再次输入新密码'),
        ]) ...[
          TextField(
            controller: e.$1,
            obscureText: true,
            decoration: InputDecoration(labelText: e.$2),
          ),
          const SizedBox(height: 14),
        ],
        FilledButton(onPressed: busy ? null : save, child: const Text('保存新密码')),
      ],
    ),
  );
}

class StaffProfile extends StatefulWidget {
  const StaffProfile(this.api, {super.key});
  final HarborApi api;
  @override
  State<StaffProfile> createState() => _StaffProfileState();
}

class _StaffProfileState extends State<StaffProfile> {
  final bio = TextEditingController(), location = TextEditingController();
  Set<String> modes = {};
  Data? saved;
  Object? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final v = await widget.api.request('/staff/me');
      if (mounted)
        setState(() {
          saved = v;
          bio.text = text(v, 'bio');
          location.text = text(v, 'location');
          modes = (v['modes'] as List? ?? []).cast<String>().toSet();
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> save() async {
    if (modes.isEmpty) {
      flash(context, '请保留至少一种服务方式');
      return;
    }
    setState(() => busy = true);
    try {
      final result = await widget.api.patch('/staff/me', {
        'bio': bio.text,
        'modes': modes.toList(),
        'location': location.text,
      });
      if (mounted) {
        setState(() => saved = result);
        flash(context, '接待资料已更新');
      }
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    bio.dispose();
    location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('接待资料')),
    body: saved == null
        ? Center(
            child: error == null
                ? const CircularProgressIndicator()
                : LoadError(error!, load),
          )
        : HarborList(
            children: [
              Text(
                roleName(saved!['role']),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (text(saved!, 'supervisor_name').isNotEmpty)
                Text('指导老师 · ${text(saved!, 'supervisor_name')}'),
              const SizedBox(height: 14),
              TextField(
                controller: bio,
                minLines: 3,
                maxLines: 6,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: '接待介绍'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in ['online', 'onsite'])
                    FilterChip(
                      label: Text(modeName(m)),
                      selected: modes.contains(m),
                      onSelected: (v) =>
                          setState(() => v ? modes.add(m) : modes.remove(m)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: location,
                maxLength: 120,
                decoration: const InputDecoration(labelText: '接待地点'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : save,
                child: const Text('保存接待资料'),
              ),
            ],
          ),
  );
}

class FeedbackPage extends StatefulWidget {
  const FeedbackPage(this.api, {super.key});
  final HarborApi api;
  @override
  State<FeedbackPage> createState() => _FeedbackState();
}

class _FeedbackState extends State<FeedbackPage> {
  final body = TextEditingController(), contact = TextEditingController();
  String category = '产品建议';
  List<Data>? list;
  Object? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final v = await widget.api.list('/feedback');
      if (mounted)
        setState(() {
          list = v;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> send() async {
    if (body.text.trim().isEmpty) {
      flash(context, '请填写反馈内容');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.api.post('/feedback', {
        'category': category,
        'body': body.text,
        'contact': contact.text,
      });
      if (mounted) {
        body.clear();
        contact.clear();
        flash(context, '反馈已发送');
        await load();
      }
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    body.dispose();
    contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('应用反馈')),
    body: HarborList(
      refresh: load,
      children: [
        Text('告诉我们你遇到的问题', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final option in ['产品建议', '功能问题', '服务体验'])
              ChoiceChip(
                label: Text(option),
                selected: category == option,
                onSelected: (_) => setState(() => category = option),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: body,
          minLines: 3,
          maxLines: 6,
          maxLength: 1500,
          decoration: const InputDecoration(labelText: '反馈内容'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: contact,
          maxLength: 100,
          decoration: const InputDecoration(labelText: '联系方式（选填）'),
        ),
        FilledButton(onPressed: busy ? null : send, child: const Text('发送反馈')),
        const SizedBox(height: 24),
        Text('已提交', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (error != null) LoadError(error!, load),
        if (list == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (list?.isEmpty == true) const Empty('还没有已提交的反馈'),
        for (final item in list ?? <Data>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${text(item, 'category')} · ${stateName(item['status'])}',
                  ),
                  const SizedBox(height: 6),
                  Text(text(item, 'body')),
                  if (text(item, 'reply').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('回复 · ${text(item, 'reply')}'),
                  ],
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class SharedNotes extends StatefulWidget {
  const SharedNotes(this.api, {super.key});
  final HarborApi api;
  @override
  State<SharedNotes> createState() => _SharesState();
}

class _SharesState extends State<SharedNotes> {
  List<Data>? list;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final v = await widget.api.list('/me/shares');
      if (mounted)
        setState(() {
          list = v;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> revoke(Data item) async {
    if (!await confirmAction(
      context,
      '撤回这份分享？',
      '负责人员将无法通过会话查看这份内容。',
      confirm: '撤回',
    ))
      return;
    try {
      await widget.api.delete('/shares/${text(item, 'id')}');
      if (mounted) await load();
    } catch (e) {
      if (mounted) flash(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('已分享的 AI 内容')),
    body: HarborList(
      refresh: load,
      children: [
        if (error != null) LoadError(error!, load),
        if (list == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (list?.isEmpty == true)
          const Empty('还没有对工作人员分享过聊天内容', body: '你可以在聊天里选择要分享的消息。'),
        for (final item in list ?? <Data>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${text(item, 'staff_name')} · ${item['active'] == true ? '可查看' : '已失效'}',
                  ),
                  const SizedBox(height: 6),
                  Text(stamp(item['created_at'], date: true)),
                  const SizedBox(height: 10),
                  SelectableText(text(item, 'body')),
                  if (item['active'] == true)
                    TextButton(
                      onPressed: () => revoke(item),
                      child: const Text('撤回分享'),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class BlockedPeople extends StatefulWidget {
  const BlockedPeople(this.api, {super.key});
  final HarborApi api;
  @override
  State<BlockedPeople> createState() => _BlocksState();
}

class _BlocksState extends State<BlockedPeople> {
  List<Data>? list;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final v = await widget.api.list('/blocks');
      if (mounted)
        setState(() {
          list = v;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> remove(Data item) async {
    try {
      await widget.api.delete('/blocks/${text(item, 'id')}');
      if (mounted) await load();
    } catch (e) {
      if (mounted) flash(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('屏蔽列表')),
    body: HarborList(
      refresh: load,
      children: [
        if (error != null) LoadError(error!, load),
        if (list == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (list?.isEmpty == true)
          const Empty('屏蔽列表为空', icon: Icons.person_outline),
        for (final item in list ?? <Data>[])
          ListTile(
            leading: PersonIcon(text(item, 'nickname')),
            title: Text(text(item, 'nickname')),
            trailing: TextButton(
              onPressed: () => remove(item),
              child: const Text('取消屏蔽'),
            ),
          ),
      ],
    ),
  );
}

class MyCommunity extends StatefulWidget {
  const MyCommunity(this.api, this.user, {super.key});
  final HarborApi api;
  final Data user;
  @override
  State<MyCommunity> createState() => _MyCommunityState();
}

class _MyCommunityState extends State<MyCommunity> {
  List<Data>? posts, comments;
  Object? error;
  bool showComments = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final v = await Future.wait([
        widget.api.list('/posts?author_id=${text(widget.user, 'id')}'),
        widget.api.list('/comments?scope=mine'),
      ]);
      if (mounted)
        setState(() {
          posts = v.first;
          comments = v.last;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = showComments ? comments : posts;
    return Scaffold(
      appBar: AppBar(title: const Text('我的帖子与评论')),
      body: HarborList(
        refresh: load,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('我的帖子')),
              ButtonSegment(value: true, label: Text('我的评论')),
            ],
            selected: {showComments},
            onSelectionChanged: (v) => setState(() => showComments = v.single),
          ),
          const SizedBox(height: 18),
          if (error != null) LoadError(error!, load),
          if (list == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (list?.isEmpty == true) Empty(showComments ? '你还没有评论' : '你还没有发帖'),
          for (final item in list ?? <Data>[]) ...[
            ListTile(
              title: Text(
                text(item, 'body'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(stamp(item['created_at'], date: true)),
              onTap: () => open(
                context,
                PostDetail(
                  widget.api,
                  text(item, showComments ? 'post_id' : 'id'),
                  widget.user,
                ),
              ),
            ),
            const Divider(),
          ],
        ],
      ),
    );
  }
}
