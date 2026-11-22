import '../companion/image.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../companion/editor.dart';
import '../companion/viewport.dart';
import '../shared/api.dart';
import '../shared/design.dart';
import 'care.dart';
import 'ai_history.dart';

class AiPage extends StatefulWidget {
  const AiPage(this.api, this.user, {super.key, this.active = true});
  final HarborApi api;
  final Data user;
  final bool active;
  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final compose = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  Data config = presetConfig('clear');
  Data conversation = {}, run = {};
  List<Data> history = [];
  StreamSubscription<Data>? stream;
  Timer? reconnect, motionTimer, draftTimer;
  String streaming = '',
      pendingText = '',
      pendingId = '',
      action = 'idle',
      nextCursor = '';
  bool loading = true,
      sending = false,
      stopping = false,
      loadingEarlier = false,
      showGesture = true;
  Object? issue;
  bool showAvatar = false, awayFromLatest = false;
  final feedback = <String, bool>{};
  SharedPreferences? preferences;
  int generation = 0, failures = 0;
  String get id => text(conversation, 'id');
  String get runId => text(run, 'id');
  bool get activeRun => ['waiting', 'streaming'].contains(run['status']);
  bool get terminalFailure =>
      ['failed', 'canceled', 'stopped', 'cancelled'].contains(run['status']);
  String get draftKey => 'ai.draft.${text(widget.user, 'id')}.$id';
  String get latestKey => 'ai.last.${text(widget.user, 'id')}';

  @override
  void initState() {
    super.initState();
    compose.addListener(onDraft);
    scroll.addListener(() {
      final value = scroll.hasClients && scroll.position.extentAfter > 160;
      if (mounted && awayFromLatest != value)
        setState(() => awayFromLatest = value);
    });
    initialize();
  }

  Future<void> initialize() async {
    try {
      preferences = await SharedPreferences.getInstance();
      final response = await Future.wait([
        widget.api.list('/ai/conversations'),
        widget.api.request('/avatars/me'),
      ]);
      if (!mounted) return;
      final list = response.first as List<Data>;
      config = data((response.last as Data)['config']);
      final latest = preferences?.getString(latestKey);
      Data selected = {};
      for (final candidate in list) {
        if (candidate['id'] == latest) {
          selected = candidate;
          break;
        }
      }
      if (selected.isEmpty && list.isNotEmpty) selected = list.first;
      await select(selected, restoreDraft: true);
      if (!mounted) return;
      if (showGesture) {
        final key = 'ai.greeting.${text(widget.user, 'id')}';
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - (preferences?.getInt(key) ?? 0) >= 600000 && !activeRun) {
          preferences?.setInt(key, now);
          gesture('greeting');
        }
      }
    } catch (e) {
      if (mounted)
        setState(() {
          issue = e;
          loading = false;
        });
    }
  }

  void onDraft() {
    if (!mounted) return;
    draftTimer?.cancel();
    final key = draftKey, value = compose.text;
    draftTimer = Timer(const Duration(milliseconds: 180), () {
      if (widget.api.token != null)
        unawaited(
          HarborApi.storage.write(key: key, value: value).catchError((_) {}),
        );
    });
    setState(() {});
  }

  Future<void> select(Data value, {bool restoreDraft = true}) async {
    generation++;
    final epoch = generation;
    await stream?.cancel();
    stream = null;
    reconnect?.cancel();
    if (!mounted || epoch != generation) return;
    if (draftTimer?.isActive == true) {
      draftTimer?.cancel();
      if (widget.api.token != null)
        await HarborApi.storage.write(key: draftKey, value: compose.text);
    }
    if (!mounted || epoch != generation) return;
    setState(() {
      conversation = value;
      showAvatar = false;
      awayFromLatest = false;
      feedback.clear();
      history = [];
      run = {};
      streaming = '';
      pendingId = '';
      pendingText = '';
      issue = null;
      nextCursor = '';
      loading = value.isNotEmpty;
      failures = 0;
    });
    if (restoreDraft) {
      final saved = await HarborApi.storage.read(key: draftKey);
      if (!mounted || epoch != generation) return;
      compose.text = saved ?? '';
    }
    if (id.isEmpty) {
      preferences?.remove(latestKey);
      return;
    }
    preferences?.setString(latestKey, id);
    await reload(epoch, subscribe: true);
  }

  Future<void> reload(int epoch, {bool subscribe = false}) async {
    final selected = id;
    if (selected.isEmpty) return;
    try {
      final response = await widget.api.request(
        '/ai/conversations/$selected/messages',
      );
      if (!mounted || epoch != generation) return;
      final latest = data(response['run']);
      setState(() {
        history = objects(response['items']);
        run = latest.isEmpty ? run : latest;
        nextCursor = text(response, 'next_before');
        streaming = '';
        loading = false;
        issue = null;
        if (history.any(
          (m) => m['input_id'] == pendingId && pendingId.isNotEmpty,
        )) {
          pendingId = '';
          pendingText = '';
        }
      });
      if (subscribe && activeRun) listen(epoch);
      moveToLatest(force: true);
    } catch (e) {
      if (mounted && epoch == generation)
        setState(() {
          loading = false;
          issue = e;
        });
    }
  }

  Future<void> earlier() async {
    if (nextCursor.isEmpty || loadingEarlier) return;
    final epoch = generation;
    setState(() => loadingEarlier = true);
    final oldMax = scroll.hasClients ? scroll.position.maxScrollExtent : 0.0;
    final oldScroll = scroll.hasClients ? scroll.offset : 0.0;
    try {
      final response = await widget.api.request(
        '/ai/conversations/$id/messages?before=${Uri.encodeQueryComponent(nextCursor)}',
      );
      if (!mounted || epoch != generation) return;
      setState(() {
        history = [...objects(response['items']), ...history];
        nextCursor = text(response, 'next_before');
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && epoch == generation && scroll.hasClients)
          scroll.jumpTo(
            (oldScroll + scroll.position.maxScrollExtent - oldMax).clamp(
              0.0,
              scroll.position.maxScrollExtent,
            ),
          );
      });
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted) setState(() => loadingEarlier = false);
    }
  }

  void moveToLatest({bool force = false}) {
    final follow =
        force || !scroll.hasClients || scroll.position.extentAfter < 140;
    if (!follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients)
        scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  void listen(int epoch) {
    if (!mounted || epoch != generation || !activeRun || runId.isEmpty) return;
    reconnect?.cancel();
    final current = runId;
    stream?.cancel();
    stream = widget.api
        .events(current)
        .listen(
          (e) {
            if (!mounted || epoch != generation || runId != current) return;
            final status = data(e['run']);
            if (status.isEmpty) return;
            setState(() {
              failures = 0;
              run = status;
              if (e['reset'] == true || e['event'] == 'snapshot')
                streaming = '';
              if (e['event'] == 'snapshot' || e['event'] == 'delta')
                streaming += text(e, 'text');
            });
            if (activeRun) {
              moveToLatest();
              return;
            }
            if (status['status'] == 'completed') gesture('reply');
            reload(epoch);
          },
          onError: (Object e) {
            if (mounted && epoch == generation && activeRun)
              recover(epoch, current);
          },
          onDone: () {
            if (mounted && epoch == generation && activeRun)
              recover(epoch, current);
          },
          cancelOnError: true,
        );
  }

  void recover(int epoch, String current) {
    if (reconnect?.isActive == true) return;
    failures++;
    reconnect = Timer(Duration(seconds: failures.clamp(1, 5)), () async {
      if (!mounted || epoch != generation || runId != current) return;
      try {
        final status = await widget.api.request('/ai/runs/$current');
        if (!mounted || epoch != generation) return;
        setState(() => run = status);
        if (activeRun) {
          listen(epoch);
        } else {
          await reload(epoch);
        }
      } catch (e) {
        if (mounted && epoch == generation) {
          setState(() => issue = e);
          recover(epoch, current);
        }
      }
    });
  }

  void gesture(String value) {
    if (!mounted) return;
    motionTimer?.cancel();
    setState(() => action = value);
    motionTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => action = 'idle');
    });
  }

  bool consentHandled = false;
  Future<bool> ensureConsent() async {
    if (consentHandled) return true;
    final status = await widget.api.request('/me/ai-consent');
    if (status['agreed'] == true) {
      consentHandled = true;
      return true;
    }
    if (!mounted) return false;
    final agrees = await confirmAction(
      context,
      '使用 AI 伙伴',
      harborOffline
          ? '离线体验使用预设回复。你输入的内容仅保存在这台设备，分享和求助也只在本机模拟。'
          : '你发送的消息和必要的对话上下文会交给模型服务处理，聊天记录保存在你的账号下。工作人员只能查看你确认分享给他们的内容。AI 可以陪你梳理心情，也可以带你找到校内支持。',
      confirm: '同意并继续',
    );
    if (!agrees || !mounted) return false;
    await widget.api.post('/me/ai-consent', {'agreed': true});
    consentHandled = true;
    return true;
  }

  Future<void> send({bool repeat = false}) async {
    if (sending || activeRun) return;
    final body = repeat ? pendingText : compose.text.trim();
    if (body.isEmpty) return;
    if (!repeat) {
      pendingId = newID();
      pendingText = body;
    }
    setState(() {
      issue = null;
      sending = true;
    });
    if (body.characters.length > 4000) {
      setState(() {
        issue = const ApiError(400, 'message_too_long', '一次可发送 4,000 字');
        sending = false;
      });
      return;
    }
    final epoch = generation;
    try {
      if (!await ensureConsent() || !mounted || epoch != generation) return;
      if (id.isEmpty) {
        final created = await widget.api.post('/ai/conversations');
        if (!mounted || epoch != generation) return;
        setState(() => conversation = created);
        preferences?.setString(latestKey, id);
      }
      final result = await widget.api.post('/ai/conversations/$id/inputs', {
        'id': pendingId,
        'text': body,
      });
      if (!mounted || epoch != generation) return;
      setState(() {
        run = result;
        streaming = '';
      });
      if (compose.text.trim() == body) compose.clear();
      focus.unfocus();
      if (activeRun)
        listen(epoch);
      else
        await reload(epoch);
      moveToLatest(force: true);
    } catch (e) {
      if (mounted && epoch == generation) setState(() => issue = e);
    } finally {
      if (mounted && epoch == generation) setState(() => sending = false);
    }
  }

  Future<void> stop() async {
    if (!activeRun || stopping) return;
    setState(() => stopping = true);
    try {
      await widget.api.post('/ai/runs/$runId/cancel');
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted) setState(() => stopping = false);
    }
  }

  Future<void> retry() async {
    if (sending || activeRun) return;
    if (pendingId.isNotEmpty && pendingText.isNotEmpty) {
      await send(repeat: true);
      return;
    }
    final input = text(run, 'input_id');
    if (input.isEmpty) return;
    final epoch = generation;
    setState(() {
      sending = true;
      issue = null;
    });
    try {
      if (!await ensureConsent() || !mounted || epoch != generation) return;
      final result = await widget.api.post('/ai/inputs/$input/retry', {
        'id': newID(),
      });
      if (!mounted || epoch != generation) return;
      setState(() {
        run = result;
        streaming = '';
      });
      if (activeRun)
        listen(epoch);
      else
        await reload(epoch);
    } catch (e) {
      if (mounted) flash(context, e);
    } finally {
      if (mounted && epoch == generation) setState(() => sending = false);
    }
  }

  Future<void> openHistory() async {
    final chosen = await open<Data>(
      context,
      AiHistory(widget.api, current: id),
    );
    if (!mounted || chosen == null) return;
    if (chosen['deleted'] == id || chosen['new'] == true) {
      gesture('farewell');
      await select({});
    } else if (chosen['id'] != null) {
      await select(chosen);
    }
  }

  Future<void> editAvatar() async {
    final saved = await open<Data>(
      context,
      AvatarEditor(widget.api, motion: text(widget.user, 'motion', 'standard')),
    );
    if (mounted && saved != null) {
      setState(() => config = saved);
      flash(context, '伙伴形象已保存');
    }
  }

  Future<void> share(Data message) async {
    final services = await widget.api.list('/services');
    if (!mounted) return;
    final available = services
        .where(
          (s) =>
              s['status'] != 'closed' &&
              (DateTime.tryParse(
                    text(s, 'completed_at'),
                  )?.add(const Duration(days: 7)).isAfter(DateTime.now()) ??
                  true),
        )
        .toList();
    if (available.isEmpty) {
      flash(context, '预约确认或人工求助被接手后，可以分享给负责的老师或朋辈');
      return;
    }
    final service = await showModalBottomSheet<Data>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: HarborList(
          children: [
            Text('分享给负责人员', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            const Text('对方仅能查看你确认分享的内容。'),
            for (final value in available)
              ListTile(
                title: Text(text(value, 'staff_name')),
                subtitle: Text(stateName(value['status'])),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (!mounted || service == null) return;
    final selected = <String>{text(message, 'id')};
    final body = text(message, 'text');
    final mode = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('分享给 ${text(service, 'staff_name')}'),
        content: SizedBox(
          width: 460,
          child: StatefulBuilder(
            builder: (context, update) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('选择内容，最多 20 条。你可以原文分享，也可以先整理成摘要。'),
                    const SizedBox(height: 8),
                    for (final row in history.where(
                      (m) =>
                          text(m, 'id').isNotEmpty &&
                          !text(m, 'id').startsWith('pending-'),
                    ))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: selected.contains(row['id']),
                        title: Text(
                          text(row, 'text'),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(row['role'] == 'user' ? '我' : 'AI 伙伴'),
                        onChanged: (value) {
                          update(() {
                            final key = text(row, 'id');
                            if (value == true && selected.length < 20)
                              selected.add(key);
                            if (value == false && selected.length > 1)
                              selected.remove(key);
                          });
                        },
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'summary'),
            child: const Text('生成可编辑摘要'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, 'messages'),
            child: const Text('分享所选消息'),
          ),
        ],
      ),
    );
    if (!mounted || mode == null) return;
    final selectedIds = selected.toList();
    Data payload = {
      'conversation_id': id,
      'message_ids': selectedIds,
      'expected_staff_id': text(service, 'staff_id'),
    };
    if (mode == 'summary') {
      var initial = history
          .where((m) => selected.contains(m['id']))
          .map((m) => text(m, 'text'))
          .join('\n\n');
      if (initial.isEmpty) initial = body;
      try {
        final draft = await widget.api.request(
          '/ai/conversations/$id/share-summary',
          method: 'POST',
          body: {'message_ids': selectedIds},
          timeout: const Duration(seconds: 48),
        );
        initial = text(draft, 'summary', initial);
      } catch (e) {
        if (mounted) flash(context, '暂时无法生成摘要，你可以直接编辑内容。');
      }
      if (!mounted) return;
      final summary = await askText(
        context,
        '编辑分享摘要',
        '发送给负责人员的内容',
        initial: initial.characters.take(6000).toString(),
        maxLength: 6000,
        confirm: '确认分享',
      );
      if (summary == null) return;
      payload = {
        'conversation_id': id,
        'summary': summary,
        'expected_staff_id': text(service, 'staff_id'),
      };
    }
    await widget.api.post('/services/${text(service, 'id')}/shares', payload);
    if (mounted) flash(context, '已分享。你可以在「我的」撤回。');
  }

  void handleAction(Data act) async {
    final kind = act['kind'], url = text(act, 'url');
    if (url.startsWith('https://') || url.startsWith('http://')) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return;
    }
    if (!mounted) return;
    if (kind == 'help') {
      open(context, HelpPage(widget.api));
      return;
    }
    if (kind == 'appointment' && text(act, 'id').isNotEmpty) {
      open(context, AppointmentDetail(widget.api, text(act, 'id')));
      return;
    }
    if (kind == 'staff' && text(act, 'id').isNotEmpty) {
      open(context, StaffDetail(widget.api, text(act, 'id')));
      return;
    }
    if (kind == 'slot' && text(act, 'staff_id').isNotEmpty) {
      open(
        context,
        StaffDetail(widget.api, text(act, 'staff_id'), slotId: text(act, 'id')),
      );
      return;
    }
    open(context, SupportPage(widget.api));
  }

  @override
  void dispose() {
    stream?.cancel();
    reconnect?.cancel();
    motionTimer?.cancel();
    draftTimer?.cancel();
    if (widget.api.token != null)
      unawaited(
        HarborApi.storage
            .write(key: draftKey, value: compose.text)
            .catchError((_) {}),
      );
    compose.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tight = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showPending =
        pendingText.isNotEmpty &&
        !history.any((v) => v['input_id'] == pendingId) &&
        issue == null;
    final isBlank = history.isEmpty && !showPending && !activeRun && !loading;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leadingWidth: 52,
        leading: IconButton(
          onPressed: openHistory,
          tooltip: '会话历史',
          icon: const Icon(Icons.history_rounded),
        ),
        title: isBlank
            ? const Text('心灵港湾')
            : InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => showAvatar = !showAvatar),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipOval(
                        child: CompanionImage(
                          'poster-${text(config, 'preset', 'clear')}.png',
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Flexible(
                        child: Text(
                          'AI 伙伴',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => open(context, SupportPage(widget.api)),
            child: const Text('找人聊聊'),
          ),
          if (id.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: '聊天操作',
              onSelected: (_) {
                gesture('farewell');
                select({});
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'end', child: Text('结束本次聊天')),
              ],
            )
          else
            const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              children: [
                if (!tight && (isBlank || showAvatar))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Stack(
                      children: [
                        GestureDetector(
                          onTap: activeRun ? null : () => gesture('reply'),
                          child: SizedBox(
                            height: isBlank ? 242 : 136,
                            width: double.infinity,
                            child: CompanionView(
                              config: config,
                              state: run['risk'] == true
                                  ? 'help'
                                  : activeRun
                                  ? 'thinking'
                                  : action != 'idle'
                                  ? action
                                  : compose.text.isNotEmpty
                                  ? 'listening'
                                  : 'idle',
                              paused: !widget.active,
                              motion: text(widget.user, 'motion', 'standard'),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 13,
                          left: 13,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: t.colorScheme.surface.withAlpha(223),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              child: Text(
                                'AI 伙伴',
                                style: t.textTheme.labelMedium,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 10,
                          bottom: 9,
                          child: TextButton.icon(
                            onPressed: editAvatar,
                            style: TextButton.styleFrom(
                              backgroundColor: t.colorScheme.surface.withAlpha(
                                230,
                              ),
                            ),
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: const Text('形象'),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          children: [
                            if (nextCursor.isNotEmpty)
                              Center(
                                child: TextButton(
                                  onPressed: loadingEarlier ? null : earlier,
                                  child: Text(
                                    loadingEarlier ? '加载中…' : '查看更早的消息',
                                  ),
                                ),
                              ),
                            if (isBlank) ...[
                              Text(
                                '想从哪里说起？',
                                style: t.textTheme.headlineMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '想说心情、课业或相处里的小事，都可以从一句话开始。',
                                style: t.textTheme.bodyLarge?.copyWith(
                                  color: t.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 18),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final sample in [
                                    '最近有点累',
                                    '想聊聊人际关系',
                                    '有件事让我很开心',
                                  ])
                                    ActionChip(
                                      label: Text(sample),
                                      onPressed: () {
                                        compose.text = sample;
                                        focus.requestFocus();
                                      },
                                    ),
                                ],
                              ),
                            ],
                            for (final message in history)
                              messageBubble(
                                message,
                                shareable:
                                    text(message, 'id').isNotEmpty &&
                                    !text(message, 'id').startsWith('pending-'),
                              ),
                            if (showPending)
                              messageBubble({
                                'role': 'user',
                                'text': pendingText,
                              }),
                            if (activeRun)
                              messageBubble({
                                'role': 'assistant',
                                'text': streaming.isEmpty
                                    ? '在听，也在想怎么回应你…'
                                    : streaming,
                              }),
                            if (terminalFailure)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Surface(
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          text(
                                            run,
                                            'error',
                                            run['status'] == 'failed'
                                                ? '这次回复没有完成。'
                                                : '已停止本次回复。',
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: sending ? null : retry,
                                        child: const Text('重试'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (run['risk'] == true)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Surface(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '你可以找一位真人一起面对',
                                        style: t.textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        '如果你目前不安全，请立即联系身边可信的人或当地紧急服务。',
                                      ),
                                      const SizedBox(height: 12),
                                      FilledButton.tonal(
                                        onPressed: () =>
                                            open(context, HelpPage(widget.api)),
                                        child: const Text('希望有人联系我'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            for (final act in objects(run['actions']))
                              if (act['kind'] != 'help' || run['risk'] != true)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: ListTile(
                                    tileColor: t.colorScheme.surface,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    onTap: () => handleAction(act),
                                    title: Text(text(act, 'title')),
                                    subtitle: text(act, 'description').isEmpty
                                        ? null
                                        : Text(text(act, 'description')),
                                    trailing: const Icon(
                                      Icons.chevron_right_rounded,
                                    ),
                                  ),
                                ),
                            if (issue != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: LoadError(issue!, () {
                                  if (pendingText.isNotEmpty) {
                                    retry();
                                  } else if (id.isEmpty) {
                                    initialize();
                                  } else {
                                    reload(generation, subscribe: true);
                                  }
                                }),
                              ),
                          ],
                        ),
                ),
                if (awayFromLatest)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: OutlinedButton.icon(
                      onPressed: () => moveToLatest(force: true),
                      icon: const Icon(Icons.arrow_downward_rounded, size: 17),
                      label: const Text('回到最新'),
                    ),
                  ),
                Material(
                  color: t.colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    child: Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: compose,
                                focusNode: focus,
                                minLines: 1,
                                maxLines: 4,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.newline,
                                decoration: const InputDecoration(
                                  hintText: '说说此刻的心情…',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              tooltip: activeRun ? '停止回复' : '发送',
                              constraints: const BoxConstraints.tightFor(
                                width: 48,
                                height: 48,
                              ),
                              onPressed: activeRun
                                  ? (stopping ? null : stop)
                                  : (sending || compose.text.trim().isEmpty
                                        ? null
                                        : send),
                              icon: sending || stopping
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      activeRun
                                          ? Icons.stop_rounded
                                          : Icons.arrow_upward_rounded,
                                    ),
                            ),
                          ],
                        ),
                        if (!tight)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              harborOffline
                                  ? '离线体验 · AI 伙伴使用本地模拟回复'
                                  : 'AI 伙伴提供日常陪伴，需要时也可以联系校内支持。',
                              textAlign: TextAlign.center,
                              style: t.textTheme.labelMedium,
                            ),
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

  Future<void> rate(Data message, bool helpful) async {
    var note = '';
    if (!helpful) {
      final entered = await askText(
        context,
        '这条回复可以怎样改进？',
        '意见（选填）',
        required: false,
        confirm: '提交',
      );
      if (entered == null) return;
      note = entered;
    }
    try {
      final mid = Uri.encodeComponent(text(message, 'id'));
      await widget.api.put('/ai/conversations/$id/messages/$mid/feedback', {
        'helpful': helpful,
        'note': note,
      });
      if (mounted) {
        setState(() => feedback[text(message, 'id')] = helpful);
        flash(context, '已提交反馈');
      }
    } catch (e) {
      if (mounted) flash(context, e);
    }
  }

  Widget messageBubble(Data message, {bool shareable = false}) {
    final t = Theme.of(context), user = message['role'] == 'user';
    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: user ? t.colorScheme.primaryContainer : t.colorScheme.surface,
        border: !user ? Border.all(color: t.colorScheme.outlineVariant) : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(17),
          topRight: const Radius.circular(17),
          bottomLeft: Radius.circular(user ? 17 : 5),
          bottomRight: Radius.circular(user ? 5 : 17),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        child: SelectableText(
          text(message, 'text'),
          style: t.textTheme.bodyLarge,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: .89,
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: user
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              bubble,
              if (shareable)
                Wrap(
                  children: [
                    if (!user) ...[
                      IconButton(
                        tooltip: '复制',
                        icon: const Icon(Icons.content_copy_outlined, size: 16),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: text(message, 'text')),
                          );
                          if (mounted) flash(context, '已复制');
                        },
                      ),
                      IconButton(
                        tooltip: '有帮助',
                        icon: Icon(
                          feedback[message['id']] == true
                              ? Icons.thumb_up
                              : Icons.thumb_up_outlined,
                          size: 17,
                        ),
                        onPressed: () => rate(message, true),
                      ),
                      IconButton(
                        tooltip: '需要改进',
                        icon: Icon(
                          feedback[message['id']] == false
                              ? Icons.thumb_down
                              : Icons.thumb_down_outlined,
                          size: 17,
                        ),
                        onPressed: () => rate(message, false),
                      ),
                    ],
                    IconButton(
                      tooltip: '分享消息',
                      icon: const Icon(Icons.ios_share_outlined, size: 17),
                      onPressed: () async {
                        try {
                          await share(message);
                        } catch (e) {
                          if (mounted) flash(context, e);
                        }
                      },
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
