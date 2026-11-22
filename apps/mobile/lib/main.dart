import 'companion/image.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/ai_chat.dart';
import 'features/care.dart';
import 'features/community.dart';
import 'features/messages.dart';
import 'features/profile.dart';
import 'features/student_home.dart';
import 'features/student_profile.dart';
import 'features/student_school.dart';
import 'features/wellbeing.dart';
import 'mock/offline_api.dart';
import 'shared/api.dart';
import 'shared/design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  await initializeWellbeingAudio();
  runApp(HarborApp());
}

class HarborApp extends StatefulWidget {
  HarborApp({super.key, HarborApi? api})
    : api = api ?? (harborOffline ? OfflineHarborApi() : HarborApi());
  final HarborApi api;
  @override
  State<HarborApp> createState() => _HarborState();
}

class _HarborState extends State<HarborApp> with WidgetsBindingObserver {
  final navigation = GlobalKey<NavigatorState>();
  Data? user;
  Data school = {};
  bool restoring = true;
  Object? restoreError;
  String? space;
  SharedPreferences? preferences;
  Timer? timer;
  HarborApi get api => widget.api;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.onUnauthorized = expire;
    restore();
    timer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => refreshIdentity(),
    );
  }

  Future<void> restore() async {
    setState(() {
      restoring = true;
      restoreError = null;
    });
    try {
      preferences = await SharedPreferences.getInstance();
      await api.restore();
      final config = await api.request('/school');
      if (!mounted) return;
      school = config;
      if (api.token != null) {
        accept(await api.request('/me'));
      }
    } catch (e) {
      if (e is! ApiError || e.status != 401) {
        if (mounted) setState(() => restoreError = e);
      }
    } finally {
      if (mounted) setState(() => restoring = false);
    }
  }

  List<String> spaces(Data value) => (value['roles'] as List? ?? [])
      .map((e) => e.toString())
      .where((e) => e != 'admin')
      .toList();
  void accept(Data value) {
    if (!mounted) return;
    final choices = spaces(value);
    final desired = preferences?.getString('harbor.space.${text(value, 'id')}');
    setState(() {
      user = value;
      if (!choices.contains(space)) {
        space = choices.contains(desired)
            ? desired
            : choices.length == 1
            ? choices.first
            : null;
      }
    });
    final offline = api;
    if (offline is OfflineHarborApi && space != null)
      offline.changeSpace(space!);
  }

  void changeSpace(String space) {
    if (user == null || !spaces(user!).contains(space)) return;
    final offline = api;
    if (offline is OfflineHarborApi) offline.changeSpace(space);
    preferences?.setString('harbor.space.${text(user!, 'id')}', space);
    setState(() => this.space = space);
  }

  void expire() {
    final uid = user == null ? '' : text(user!, 'id');
    api.remember(null).catchError((_) {});
    if (uid.isNotEmpty) {
      unawaited(clearPrivateDrafts(uid).catchError((_) {}));
    }
    if (!mounted) return;
    navigation.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      user = null;
      space = null;
    });
  }

  Future<void> clearPrivateDrafts(String uid) async {
    final stored = await HarborApi.storage.readAll();
    for (final key in stored.keys) {
      if (key == 'harbor.post.draft.$uid' ||
          key.startsWith('harbor.message.draft.v1.$uid.') ||
          key.startsWith('ai.draft.$uid.')) {
        await HarborApi.storage.delete(key: key);
      }
    }
  }

  Future<void> signOut() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {
      /* Local session can always be cleared. */
    }
    expire();
  }

  Future<void> refreshIdentity() async {
    if (user == null || api.token == null) return;
    try {
      accept(await api.request('/me'));
    } catch (_) {
      /* Retry on foreground or next API use. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final error = restoreError;
    if (!restoring && error is ApiError && error.status == 0) {
      restore();
    } else {
      refreshIdentity();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = user;
    final lightTheme = harborTheme(Brightness.light);
    final theme = switch (current?['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      title: '心灵港湾',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigation,
      theme: space == 'student' ? studentTheme(lightTheme) : lightTheme,
      darkTheme: harborTheme(Brightness.dark),
      themeMode: theme,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : restoreError != null
          ? Scaffold(body: Center(child: LoadError(restoreError!, restore)))
          : current == null
          ? SignIn(api, school, onLogin: accept)
          : space == null
          ? SpaceChoice(
              current,
              choices: spaces(current),
              onSpace: changeSpace,
              logout: signOut,
            )
          : HarborShell(
              api,
              current,
              space: space!,
              onSpace: changeSpace,
              onUser: accept,
              onLogout: signOut,
            ),
    );
  }
}

class SignIn extends StatefulWidget {
  const SignIn(this.api, this.school, {super.key, required this.onLogin});
  final HarborApi api;
  final Data school;
  final ValueChanged<Data> onLogin;
  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final form = GlobalKey<FormState>();
  final account = TextEditingController(),
      password = TextEditingController(),
      nickname = TextEditingController(),
      inviteCode = TextEditingController();
  bool register = false, working = false, showPassword = false;
  Object? error;
  Future<void> enterOffline() async {
    final result = await widget.api.post('/auth/offline');
    await widget.api.remember(text(result, 'token'));
    if (mounted) widget.onLogin(data(result['user']));
  }

  Future<void> submit() async {
    if (working || !form.currentState!.validate()) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      final result = await widget.api
          .post(register ? '/auth/register' : '/auth/login', {
            'account': account.text.trim(),
            'password': password.text,
            if (register) 'nickname': nickname.text.trim(),
            if (register && widget.school['registration_mode'] == 'invite')
              'invite_code': inviteCode.text.trim(),
          });
      await widget.api.remember(text(result, 'token'));
      if (mounted) widget.onLogin(data(result['user']));
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  void dispose() {
    account.dispose();
    password.dispose();
    nickname.dispose();
    inviteCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final school = text(widget.school, 'name', '心灵港湾');
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: HarborList(
              padding: const EdgeInsets.fromLTRB(24, 30, 24, 28),
              children: [
                Container(
                  height: 172,
                  decoration: BoxDecoration(
                    color: t.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: FractionallySizedBox(
                          widthFactor: .58,
                          heightFactor: 1,
                          child: CompanionImage(
                            'poster-soft.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: .48,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 18),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.spa_outlined,
                                  color: t.colorScheme.primary,
                                  size: 29,
                                ),
                                const SizedBox(height: 10),
                                Text('心灵港湾', style: t.textTheme.titleLarge),
                                const SizedBox(height: 5),
                                Text(
                                  '从一句话开始，留一点时间给自己。',
                                  style: t.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  harborOffline ? '离线体验' : (register ? '加入心灵港湾' : '欢迎回来'),
                  style: t.textTheme.headlineMedium,
                ),
                const SizedBox(height: 5),
                Text(
                  harborOffline
                      ? '在本机体验陪伴、社区和校内支持。聊天、预约与消息均为模拟。'
                      : (school == '心灵港湾' ? '校园心理支持与日常陪伴' : school),
                  style: t.textTheme.bodyLarge?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 22),
                if (harborOffline)
                  FilledButton(
                    onPressed: enterOffline,
                    child: const Text('进入离线体验'),
                  ),
                if (!harborOffline)
                  AutofillGroup(
                    child: Form(
                      key: form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (register) ...[
                            TextFormField(
                              controller: nickname,
                              maxLength: 32,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: '昵称',
                              ),
                              validator: (v) =>
                                  (v ?? '').trim().isEmpty ? '请输入昵称' : null,
                            ),
                            const SizedBox(height: 10),
                            if (widget.school['registration_mode'] ==
                                'invite') ...[
                              TextFormField(
                                controller: inviteCode,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: '入校邀请码',
                                ),
                                validator: (v) => (v ?? '').trim().isEmpty
                                    ? '请输入学校提供的邀请码'
                                    : null,
                              ),
                              const SizedBox(height: 12),
                            ],
                          ],
                          TextFormField(
                            controller: account,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                              labelText: '账号',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (v) =>
                                (v ?? '').trim().isEmpty ? '请输入账号' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: password,
                            obscureText: !showPassword,
                            autofillHints: [
                              register
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password,
                            ],
                            decoration: InputDecoration(
                              labelText: '密码',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                tooltip: showPassword ? '隐藏密码' : '显示密码',
                                onPressed: () => setState(
                                  () => showPassword = !showPassword,
                                ),
                                icon: Icon(
                                  showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                            validator: (v) => (v ?? '').isEmpty
                                ? '请输入密码'
                                : register && v!.length < 8
                                ? '密码至少为 8 位'
                                : null,
                            onFieldSubmitted: (_) => submit(),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                error.toString(),
                                style: TextStyle(color: t.colorScheme.error),
                              ),
                            ),
                          const SizedBox(height: 18),
                          FilledButton(
                            onPressed: working ? null : submit,
                            child: working
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(register ? '注册并进入' : '登录'),
                          ),
                          if (widget.school['registered_open'] == true)
                            TextButton(
                              onPressed: working
                                  ? null
                                  : () => setState(() {
                                      register = !register;
                                      error = null;
                                    }),
                              child: Text(register ? '已有账号，去登录' : '首次使用，注册账号'),
                            ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('学校支持'),
                                content: Text(
                                  [
                                            text(widget.school, 'contact'),
                                            text(
                                              widget.school,
                                              'service_hours',
                                            ),
                                            text(widget.school, 'location'),
                                          ]
                                          .where((x) => x.isNotEmpty)
                                          .join('\n')
                                          .isEmpty
                                      ? '如需工作账号或重置密码，请联系学校负责心灵港湾的运营人员。'
                                      : [
                                          text(widget.school, 'contact'),
                                          text(widget.school, 'service_hours'),
                                          text(widget.school, 'location'),
                                        ].where((x) => x.isNotEmpty).join('\n'),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('关闭'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Text('联系学校'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SpaceChoice extends StatelessWidget {
  const SpaceChoice(
    this.user, {
    super.key,
    required this.choices,
    required this.onSpace,
    required this.logout,
  });
  final Data user;
  final List<String> choices;
  final ValueChanged<String> onSpace;
  final VoidCallback logout;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(harborOffline ? '心灵港湾 · 离线体验' : '心灵港湾'),
      actions: [TextButton(onPressed: logout, child: const Text('退出'))],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: HarborList(
          children: [
            Text(
              '你好，${text(user, 'nickname')}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              choices.isEmpty ? '当前账号可以使用网页运营工作台。' : '选择本次要使用的空间。之后也可以在「我的」切换。',
            ),
            const SizedBox(height: 20),
            for (final choice in choices)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Surface(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(
                      choice == 'student'
                          ? Icons.self_improvement_rounded
                          : Icons.support_agent_outlined,
                    ),
                    title: Text(
                      choice == 'student' ? '学生空间' : roleName(choice),
                    ),
                    subtitle: Text(
                      choice == 'student' ? '陪伴、社区和校内支持' : '预约、接待和服务跟进',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onSpace(choice),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class HarborShell extends StatefulWidget {
  const HarborShell(
    this.api,
    this.user, {
    super.key,
    required this.space,
    required this.onSpace,
    required this.onUser,
    required this.onLogout,
  });
  final HarborApi api;
  final Data user;
  final String space;
  final ValueChanged<String> onSpace;
  final ValueChanged<Data> onUser;
  final VoidCallback onLogout;
  @override
  State<HarborShell> createState() => _ShellState();
}

class _ShellState extends State<HarborShell> {
  int active = 0, unread = 0;
  Timer? polling;
  bool get work => widget.space != 'student';
  String get accountId => text(widget.user, 'id');
  @override
  void initState() {
    super.initState();
    pollUnread();
    polling = Timer.periodic(const Duration(seconds: 15), (_) => pollUnread());
  }

  @override
  void didUpdateWidget(covariant HarborShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space != widget.space) {
      active = 0;
      unread = 0;
      pollUnread();
    }
  }

  @override
  void dispose() {
    polling?.cancel();
    super.dispose();
  }

  Future<void> pollUnread() async {
    final scope = work ? '?scope=work' : '';
    final space = widget.space;
    try {
      final result = await Future.wait([
        widget.api.list('/conversations$scope'),
        widget.api.list('/notifications$scope'),
      ]);
      final count =
          result.first.fold<int>(
            0,
            (n, v) => n + (v['unread'] as num? ?? 0).toInt(),
          ) +
          result.last.where((v) => v['read'] == false).length;
      if (mounted && space == widget.space && unread != count)
        setState(() => unread = count);
    } catch (_) {
      /* The message page can surface its own error. */
    }
  }

  void notification(Data notice) {
    final id = text(notice, 'target_id');
    final page = switch (notice['target_type']) {
      'appointment' => AppointmentDetail(widget.api, id, work: work),
      'followup' => FollowupDetail(widget.api, id, work: work),
      'help' => HelpDetail(widget.api, id, work: work),
      'post' => PostDetail(widget.api, id, widget.user),
      'feedback' => FeedbackPage(widget.api),
      'chat_request' => MessagesPage(
        widget.api,
        widget.user,
        work: work,
        showRequests: true,
        onNotice: notification,
      ),
      'transfer' => WorkPage(widget.api, widget.user),
      _ => null,
    };
    if (page != null) {
      open(context, page).then((_) => pollUnread());
    }
    if (notice['target_type'] == 'service') {
      widget.api
          .request('/services/$id')
          .then((s) {
            if (mounted)
              open(
                context,
                ChatPage(
                  widget.api,
                  text(s, 'conversation_id'),
                  user: widget.user,
                ),
              );
          })
          .catchError((Object e) {
            if (mounted) flash(context, e);
          });
    }
  }

  Future<void> showJournal([String? mood]) async {
    await open(context, JournalPage(widget.api, initialMood: mood));
  }

  void showAudio() => open(context, SoundLibraryPage(accountId: accountId));

  Future<void> showFavorites() async {
    await open(
      context,
      SoundLibraryPage(accountId: accountId, favoritesOnly: true),
    );
  }

  void showBreathing() => open(context, const BreathingPage());

  void showDaily() => open(context, DailyCardPage(accountId: accountId));

  void showPet() => open(context, PetPage(widget.api, accountId));

  void showShortcut(HarborShortcut shortcut) {
    switch (shortcut) {
      case HarborShortcut.journal:
        showJournal();
      case HarborShortcut.audio:
        showAudio();
      case HarborShortcut.questions:
        open(context, const CheckInQuestionsPage());
      case HarborShortcut.daily:
        showDaily();
      case HarborShortcut.plaza:
        open(
          context,
          CommunityPage(widget.api, widget.user, resonanceOnly: true),
        );
      case HarborShortcut.sleep:
        open(context, SleepPage(widget.api));
      case HarborShortcut.pet:
        showPet();
      case HarborShortcut.breathing:
        showBreathing();
    }
  }

  Widget profileSettings() => ProfilePage(
    widget.api,
    widget.user,
    work: work,
    space: widget.space,
    onSpace: widget.onSpace,
    onUser: widget.onUser,
    onLogout: widget.onLogout,
  );

  @override
  Widget build(BuildContext context) {
    final pages = work
        ? [
            WorkPage(widget.api, {...widget.user, 'space': widget.space}),
            AppointmentsPage(widget.api, work: true),
          ]
        : [
            AiPage(
              widget.api,
              widget.user,
              active: active == 0,
              onPet: showPet,
              shortcuts: StudentShortcuts(
                accountId: accountId,
                onSelect: showShortcut,
              ),
            ),
            StudentSchoolPage(
              widget.api,
              accountId: accountId,
              heroAsset: 'assets/student/school-cover.jpg',
              onAudio: showAudio,
              onBreathing: showBreathing,
            ),
            CommunityPage(widget.api, widget.user),
          ];
    final messageIcon = Badge.count(
      count: unread,
      isLabelVisible: unread > 0,
      child: const Icon(Icons.chat_bubble_outline_rounded),
    );
    return Scaffold(
      body: IndexedStack(
        key: ValueKey(widget.space),
        index: active,
        children: [
          ...pages,
          if (work) ...[
            MessagesPage(
              widget.api,
              widget.user,
              work: true,
              active: active == 2,
              onNotice: notification,
            ),
            profileSettings(),
          ] else ...[
            StudentMessagesPage(
              widget.api,
              widget.user,
              active: active == 3,
              onNotice: notification,
              onAi: () => setState(() => active = 0),
            ),
            StudentProfilePage(
              widget.api,
              widget.user,
              active: active == 4,
              settings: profileSettings,
              onJournal: showJournal,
              onAudio: showFavorites,
              onDaily: showDaily,
            ),
          ],
        ],
      ),
      bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
          ? null
          : NavigationBar(
              selectedIndex: active,
              onDestinationSelected: (i) {
                setState(() => active = i);
                pollUnread();
              },
              destinations: [
                if (work) ...const [
                  NavigationDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard_rounded),
                    label: '工作台',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.calendar_today_outlined),
                    selectedIcon: Icon(Icons.event_available_rounded),
                    label: '预约',
                  ),
                ] else ...const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: '首页',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.school_outlined),
                    selectedIcon: Icon(Icons.school_rounded),
                    label: '学堂',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.people_outline_rounded),
                    selectedIcon: Icon(Icons.people_rounded),
                    label: '社区',
                  ),
                ],
                NavigationDestination(icon: messageIcon, label: '消息'),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: '我的',
                ),
              ],
            ),
    );
  }
}
