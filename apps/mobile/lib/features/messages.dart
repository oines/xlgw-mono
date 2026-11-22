import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/api.dart';
import '../shared/design.dart';
import 'community.dart' show reportContent;
import 'student_surface.dart';

String _scope(bool work) => work ? '?scope=work' : '';
bool _interaction(Data item) =>
    const {'chat_request', 'comment', 'resonance'}.contains(item['kind']);

class StudentMessagesPage extends StatelessWidget {
  const StudentMessagesPage(
    this.api,
    this.user, {
    super.key,
    required this.active,
    required this.onNotice,
    required this.onAi,
  });

  final HarborApi api;
  final Data user;
  final bool active;
  final ValueChanged<Data> onNotice;
  final VoidCallback onAi;

  @override
  Widget build(BuildContext context) =>
      MessagesPage(api, user, active: active, onNotice: onNotice, onAi: onAi);
}

class MessagesPage extends StatefulWidget {
  const MessagesPage(
    this.api,
    this.user, {
    super.key,
    this.work = false,
    this.active = true,
    this.onNotice,
    this.showRequests = false,
    this.onAi,
  });

  final HarborApi api;
  final Data user;
  final bool work;
  final bool active;
  final void Function(Data notice)? onNotice;
  final bool showRequests;
  final VoidCallback? onAi;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  Future<(List<Data>, List<Data>, List<Data>)>? _items;
  bool _requestViewOpened = false;
  bool _markingStudentInbox = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (widget.active) _items = _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (widget.active && ModalRoute.of(context)?.isCurrent == true) {
        _refresh();
      }
    });
  }

  @override
  void didUpdateWidget(covariant MessagesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.showRequests && !widget.work && !_requestViewOpened) {
      _requestViewOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openRequests();
      });
    }
  }

  Future<(List<Data>, List<Data>, List<Data>)> _load() async {
    final lists = await Future.wait([
      widget.api.list('/conversations${_scope(widget.work)}'),
      widget.api.list('/notifications${_scope(widget.work)}'),
      if (!widget.work) widget.api.list('/chat-requests'),
    ]);
    return (lists[0], lists[1], widget.work ? <Data>[] : lists[2]);
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _items = next;
    });
    try {
      await next;
    } catch (_) {
      // FutureBuilder shows the error and retry entry.
    }
  }

  Future<void> _openRequests() async {
    await open(context, _RequestsPage(widget.api, widget.user));
    if (mounted) _refresh();
  }

  Future<void> _openNotices({bool? interactions}) async {
    await open(
      context,
      NoticesPage(
        widget.api,
        widget.user,
        work: widget.work,
        onOpen: _openNotice,
        title: interactions == true ? '互动消息' : null,
        filter: interactions == null
            ? null
            : (item) => _interaction(item) == interactions,
        onRequests: interactions == true ? _openRequests : null,
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _markStudentRead(
    List<Data> notices,
    List<Data> conversations,
  ) async {
    if (_markingStudentInbox) return;
    setState(() => _markingStudentInbox = true);
    try {
      await Future.wait([
        if (notices.any((item) => item['read'] != true))
          widget.api.post('/notifications/read-all', {'scope': 'student'}),
        for (final item in conversations.where(
          (item) => _unreadMessages(item) > 0,
        ))
          widget.api.post('/conversations/${text(item, 'id')}/read'),
      ]);
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) {
        setState(() => _markingStudentInbox = false);
        await _refresh();
      }
    }
  }

  Future<void> _openConversation(Data conversation) async {
    await open(
      context,
      ChatPage(widget.api, text(conversation, 'id'), user: widget.user),
    );
    if (mounted) await _refresh();
  }

  int _unreadMessages(Data item) => (item['unread'] as num? ?? 0).toInt();

  Widget _studentConversation(Data conversation, {VoidCallback? onTap}) =>
      StudentCard(
        padding: EdgeInsets.zero,
        child: _InboxRow(
          avatar: PersonIcon(
            text(conversation, 'name'),
            url: text(conversation, 'avatar_url'),
            radius: 21,
          ),
          title: text(conversation, 'name'),
          subtitle: text(conversation, 'last_message', '打开会话'),
          time: stamp(conversation['updated_at']),
          count: _unreadMessages(conversation),
          onTap: onTap ?? () => _openConversation(conversation),
          compact: true,
        ),
      );

  Future<void> _showPrivateMessages(List<Data> conversations) async {
    final selected = await showModalBottomSheet<Data>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .55,
          child: HarborList(
            children: [
              const StudentTabHeader('私信'),
              const SizedBox(height: 12),
              if (conversations.isEmpty)
                const Empty('暂时没有私信', icon: Icons.person_outline_rounded),
              for (final conversation in conversations) ...[
                _studentConversation(
                  conversation,
                  onTap: () => Navigator.pop(sheet, conversation),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _openConversation(selected);
  }

  void _openNotice(Data notice) {
    if (notice['target_type'] == 'conversation') {
      open(
        context,
        ChatPage(widget.api, text(notice, 'target_id'), user: widget.user),
      );
      return;
    }
    if (notice['target_type'] != 'report') {
      final navigate = widget.onNotice;
      if (navigate != null) {
        navigate(notice);
        return;
      }
      if (notice['target_type'] == 'chat_request' && !widget.work) {
        _openRequests();
        return;
      }
    }
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(text(notice, 'title')),
        content: Text(text(notice, 'body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<(List<Data>, List<Data>, List<Data>)>(
        future: _items,
        builder: (context, snapshot) {
          final (conversations, notices, requests) =
              snapshot.data ?? (<Data>[], <Data>[], <Data>[]);
          if (widget.onAi != null) {
            return _studentInbox(snapshot, conversations, notices);
          }
          final unread = notices.where((item) => item['read'] != true).length;
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.work ? '工作消息' : '消息'),
              actions: [
                IconButton(
                  tooltip: unread == 0 ? '系统通知' : '系统通知，$unread 条未读',
                  icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text(unread > 99 ? '99+' : '$unread'),
                    child: const Icon(Icons.notifications_none_rounded),
                  ),
                  onPressed: _openNotices,
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: snapshot.hasError
                ? Center(child: LoadError(snapshot.error!, _refresh))
                : !snapshot.hasData
                ? const Center(child: CircularProgressIndicator())
                : _inbox(conversations, requests),
          );
        },
      );

  Widget _studentInbox(
    AsyncSnapshot<(List<Data>, List<Data>, List<Data>)> snapshot,
    List<Data> conversations,
    List<Data> notices,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final unreadNotices = notices.where((item) => item['read'] != true);
    final unreadInteractions = unreadNotices.where(_interaction).length;
    final unreadSystem = unreadNotices.length - unreadInteractions;
    final unreadMessages = conversations.fold<int>(
      0,
      (sum, item) => sum + _unreadMessages(item),
    );
    final unread = unreadNotices.length + unreadMessages;
    final categories = [
      (
        '系统通知',
        Icons.campaign_outlined,
        colors.primaryContainer,
        unreadSystem,
        () => _openNotices(interactions: false),
      ),
      (
        '互动消息',
        Icons.favorite_border_rounded,
        dark ? colors.secondaryContainer : const Color(0xfffbf2e3),
        unreadInteractions,
        () => _openNotices(interactions: true),
      ),
      (
        '私信',
        Icons.person_outline_rounded,
        dark ? colors.tertiaryContainer : const Color(0xffe9f0f5),
        unreadMessages,
        () => _showPrivateMessages(conversations),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: HarborList(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          refresh: _refresh,
          children: [
            StudentTabHeader(
              '消息',
              subtitle: unread > 0 ? '$unread 条未读 · 慢慢回也没关系' : '在这里查看你的消息',
              action: FilledButton.tonal(
                onPressed: unread == 0 || _markingStudentInbox
                    ? null
                    : () => _markStudentRead(notices, conversations),
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 42),
                ),
                child: const Text('全部已读'),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final (index, (label, icon, tint, count, openCategory))
                    in categories.indexed) ...[
                  if (index > 0) const SizedBox(width: 9),
                  Expanded(
                    child: StudentCard(
                      onTap: openCategory,
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _StudentMessageIcon(icon, tint),
                          const SizedBox(height: 6),
                          Text(
                            label,
                            style: theme.textTheme.labelLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '$count 条未读',
                            style: theme.textTheme.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 18),
            Text('最近对话', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (snapshot.hasError && !snapshot.hasData)
              LoadError(snapshot.error!, _refresh)
            else if (!snapshot.hasData)
              const Center(child: CircularProgressIndicator())
            else if (conversations.isEmpty)
              const StudentCard(
                child: Empty('暂时没有会话', icon: Icons.chat_bubble_outline_rounded),
              )
            else
              for (final item in conversations) ...[
                _studentConversation(item),
                const SizedBox(height: 8),
              ],
            const SizedBox(height: 10),
            StudentCard(
              color: colors.primaryContainer,
              onTap: widget.onAi,
              child: Row(
                children: [
                  _StudentMessageIcon(
                    Icons.auto_awesome_outlined,
                    colors.surface,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('想找人说说话？', style: theme.textTheme.titleMedium),
                        Text(
                          '小港一直在线，随时可以开始',
                          style: theme.textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: colors.primary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inbox(List<Data> conversations, List<Data> requests) {
    final requestsToReview = requests
        .where(
          (item) =>
              item['recipient_id'] == widget.user['id'] &&
              _requestStatus(item) == 'pending',
        )
        .length;
    return HarborList(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
      refresh: _refresh,
      children: [
        if (!widget.work) ...[
          _InboxRow(
            avatar: const _InboxIcon(Icons.person_add_alt_outlined),
            title: '交流申请',
            subtitle: requestsToReview > 0 ? '有待你处理的申请' : '查看收到与发出的申请',
            count: requestsToReview,
            onTap: _openRequests,
          ),
          const Divider(indent: 80),
        ],
        if (conversations.isEmpty)
          Empty(
            '还没有会话',
            body: widget.work
                ? '与你负责的学生建立服务后，会话将出现在这里。'
                : '人工服务和同学之间的私聊会话都在这里。',
            icon: Icons.chat_bubble_outline_rounded,
          ),
        for (final item in conversations) ...[
          _InboxRow(
            avatar: PersonIcon(
              text(item, 'name'),
              url: text(item, 'avatar_url'),
              radius: 24,
            ),
            title: text(item, 'name'),
            tag: item['kind'] == 'care' ? _serviceTag(item) : '同学交流',
            subtitle: text(item, 'last_message').isNotEmpty
                ? text(item, 'last_message')
                : '打开会话',
            time: stamp(item['updated_at'], date: true),
            count: (item['unread'] as num?)?.toInt() ?? 0,
            onTap: () async {
              await open(
                context,
                ChatPage(widget.api, text(item, 'id'), user: widget.user),
              );
              if (mounted) _refresh();
            },
          ),
          const Divider(indent: 80),
        ],
      ],
    );
  }
}

String _serviceTag(Data conversation) {
  final role = roleName(conversation['staff_role']);
  return role.isEmpty ? '人工服务' : role;
}

class _InboxIcon extends StatelessWidget {
  const _InboxIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: colors.primary),
    );
  }
}

class _StudentMessageIcon extends StatelessWidget {
  const _StudentMessageIcon(this.icon, this.tint);

  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) => Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      color: tint,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
  );
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tag = '',
    this.time = '',
    this.count = 0,
    this.compact = false,
  });

  final Widget avatar;
  final String title, subtitle, tag, time;
  final VoidCallback onTap;
  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      minTileHeight: compact ? 68 : 80,
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 20,
        vertical: 5,
      ),
      leading: avatar,
      title: Text(
        tag.isEmpty ? title : '$title · $tag',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: time.isEmpty && count == 0
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (time.isNotEmpty)
                  Text(time, style: theme.textTheme.labelMedium),
                if (count > 0) ...[
                  const SizedBox(height: 5),
                  Badge(
                    backgroundColor: compact ? theme.colorScheme.primary : null,
                    textColor: compact ? theme.colorScheme.onPrimary : null,
                    label: Text(count > 99 ? '99+' : '$count'),
                  ),
                ],
              ],
            ),
      onTap: onTap,
    );
  }
}

String _requestStatus(Data item) {
  final status = text(item, 'status');
  if (status != 'pending') return status;
  final created = DateTime.tryParse(text(item, 'created_at'));
  return created != null &&
          DateTime.now().difference(created) >= const Duration(days: 7)
      ? 'expired'
      : status;
}

class _RequestsPage extends StatefulWidget {
  const _RequestsPage(this.api, this.user);
  final HarborApi api;
  final Data user;

  @override
  State<_RequestsPage> createState() => _RequestsPageState();
}

class _RequestsPageState extends State<_RequestsPage> {
  late Future<List<Data>> _items = widget.api.list('/chat-requests');
  final _working = <String>{};

  Future<void> _refresh() async {
    final next = widget.api.list('/chat-requests');
    setState(() {
      _items = next;
    });
    try {
      await next;
    } catch (_) {
      // FutureBuilder shows the error and retry entry.
    }
  }

  Future<void> _answer(Data request, bool accept) async {
    final id = text(request, 'id');
    if (_working.contains(id)) return;
    setState(() => _working.add(id));
    try {
      final result = await widget.api.post(
        '/chat-requests/$id/${accept ? 'accept' : 'reject'}',
      );
      if (!mounted) return;
      flash(context, accept ? '已接受交流申请' : '已婉拒交流申请');
      _refresh();
      final conversation = text(result, 'conversation_id');
      if (accept && conversation.isNotEmpty) {
        await open(
          context,
          ChatPage(widget.api, conversation, user: widget.user),
        );
      }
    } catch (error) {
      if (mounted) {
        flash(context, error);
        _refresh();
      }
    } finally {
      if (mounted) setState(() => _working.remove(id));
    }
  }

  Widget _card(Data request) {
    final incoming = request['recipient_id'] == widget.user['id'];
    final name = text(request, incoming ? 'sender_name' : 'recipient_name');
    final status = _requestStatus(request);
    final note = text(request, 'note');
    final conversation = text(request, 'conversation_id');
    final busy = _working.contains(text(request, 'id'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PersonIcon(name, radius: 19),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    incoming ? '$name 想和你聊聊' : '你向 $name 发出了申请',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!(incoming && status == 'pending'))
                  Text(
                    stateName(status),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
              ],
            ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(note),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                stamp(request['created_at'], date: true),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            if (incoming && status == 'pending')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 10,
                  children: [
                    OutlinedButton(
                      onPressed: busy ? null : () => _answer(request, false),
                      child: const Text('婉拒'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => _answer(request, true),
                      child: const Text('接受'),
                    ),
                  ],
                ),
              )
            else if (status == 'accepted' && conversation.isNotEmpty)
              TextButton(
                onPressed: () => open(
                  context,
                  ChatPage(widget.api, conversation, user: widget.user),
                ),
                child: const Text('打开会话'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('交流申请')),
    body: FutureBuilder<List<Data>>(
      future: _items,
      builder: (_, snapshot) {
        if (snapshot.hasError && !snapshot.hasData) {
          return Center(child: LoadError(snapshot.error!, _refresh));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final incoming = snapshot.data!.where(
          (item) =>
              item['recipient_id'] == widget.user['id'] &&
              _requestStatus(item) == 'pending',
        );
        final prior = snapshot.data!.where(
          (item) =>
              item['recipient_id'] != widget.user['id'] ||
              _requestStatus(item) != 'pending',
        );
        return HarborList(
          refresh: _refresh,
          children: [
            if (snapshot.data!.isEmpty)
              const Empty(
                '暂无交流申请',
                body: '你可以在同学的社区主页发起邀请。',
                icon: Icons.person_add_alt_outlined,
              ),
            if (incoming.isNotEmpty) ...[
              const _SectionLabel('等待回应'),
              for (final item in incoming) _card(item),
            ],
            if (prior.isNotEmpty) ...[
              const _SectionLabel('申请记录'),
              for (final item in prior) _card(item),
            ],
          ],
        );
      },
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class NoticesPage extends StatefulWidget {
  const NoticesPage(
    this.api,
    this.user, {
    super.key,
    this.work = false,
    required this.onOpen,
    this.title,
    this.filter,
    this.onRequests,
  });

  final HarborApi api;
  final Data user;
  final bool work;
  final void Function(Data notice) onOpen;
  final String? title;
  final bool Function(Data)? filter;
  final VoidCallback? onRequests;

  @override
  State<NoticesPage> createState() => _NoticesPageState();
}

class _NoticesPageState extends State<NoticesPage> {
  late Future<List<Data>> _items = _load();
  final _read = <String>{};
  bool _marking = false;

  Future<List<Data>> _load() async {
    final notices = await widget.api.list(
      '/notifications${_scope(widget.work)}',
    );
    return widget.filter == null
        ? notices
        : notices.where(widget.filter!).toList();
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _items = next;
    });
    try {
      await next;
    } catch (_) {
      // FutureBuilder shows the error and retry entry.
    }
  }

  Future<void> _readOne(Data notice) async {
    final id = text(notice, 'id');
    if (_marking) return;
    setState(() => _marking = true);
    try {
      if (notice['read'] != true && !_read.contains(id)) {
        await widget.api.post('/notifications/$id/read');
        if (!mounted) return;
        setState(() => _read.add(id));
      }
      widget.onOpen(notice);
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  Future<void> _readAll(List<Data> items) async {
    setState(() => _marking = true);
    try {
      if (widget.filter == null) {
        await widget.api.post('/notifications/read-all', {
          'scope': widget.work ? 'work' : 'student',
        });
      } else {
        await Future.wait([
          for (final item in items)
            if (item['read'] != true && !_read.contains(text(item, 'id')))
              widget.api.post('/notifications/${text(item, 'id')}/read'),
        ]);
      }
      if (!mounted) return;
      setState(() => _read.addAll(items.map((item) => text(item, 'id'))));
      await _refresh();
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  IconData _icon(Data notice) => switch (notice['target_type']) {
    'appointment' => Icons.event_available_outlined,
    'chat_request' => Icons.person_add_alt_outlined,
    'conversation' => Icons.chat_bubble_outline,
    'report' => Icons.flag_outlined,
    _ => Icons.notifications_none_rounded,
  };

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Data>>(
    future: _items,
    builder: (context, snapshot) {
      final items = snapshot.data ?? const <Data>[];
      bool read(Data item) =>
          item['read'] == true || _read.contains(text(item, 'id'));
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title ?? (widget.work ? '工作通知' : '系统通知')),
          actions: [
            if (items.any((item) => !read(item)))
              TextButton(
                onPressed: _marking ? null : () => _readAll(items),
                child: const Text('全部已读'),
              ),
          ],
        ),
        body: snapshot.hasError && !snapshot.hasData
            ? Center(child: LoadError(snapshot.error!, _refresh))
            : !snapshot.hasData
            ? const Center(child: CircularProgressIndicator())
            : HarborList(
                padding: const EdgeInsets.only(bottom: 28),
                refresh: _refresh,
                children: [
                  if (widget.onRequests case final action?)
                    _InboxRow(
                      avatar: const _InboxIcon(Icons.person_add_alt_outlined),
                      title: '交流申请',
                      subtitle: '查看收到与发出的申请',
                      onTap: action,
                    ),
                  if (items.isEmpty)
                    const Empty(
                      '暂时没有通知',
                      icon: Icons.notifications_none_rounded,
                    ),
                  for (final item in items) ...[
                    _InboxRow(
                      avatar: _InboxIcon(_icon(item)),
                      title: text(item, 'title'),
                      subtitle: text(item, 'body'),
                      time: stamp(item['created_at'], date: true),
                      count: read(item) ? 0 : 1,
                      onTap: () => _readOne(item),
                    ),
                    const Divider(indent: 80),
                  ],
                ],
              ),
      );
    },
  );
}

class ChatPage extends StatefulWidget {
  const ChatPage(this.api, this.id, {super.key, this.user});

  final HarborApi api;
  final String id;
  final Data? user;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _QueuedMessage {
  _QueuedMessage(this.id, this.body, this.created, {this.error});
  final String id, body, created;
  bool sending = false;
  String? error;

  Data toJson() => {'id': id, 'body': body, 'created_at': created};
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  static const _pageSize = 50;
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  final _queued = <String, _QueuedMessage>{};
  final _messages = <String, Data>{};
  final _sentDuringRefresh = <String>{};
  Future<void> _writes = Future.value();
  late final String? _sessionToken;
  Timer? _poll;
  Data? _conversation, _appointment;
  Object? _error;
  late Data _user = widget.user ?? {};
  bool _loading = false;
  bool _loadingAppointment = false;
  bool _loadingPast = false;
  bool _hasPast = true;
  bool _storageReady = false;
  bool _accessible = false;
  bool _appActive = true;
  String? _before;

  bool get _isPeer => _conversation?['kind'] == 'peer';
  bool get _readOnly => _conversation?['read_only'] == true;
  String get _path => '/conversations/${widget.id}';
  String get _storageKey =>
      'harbor.message.draft.v1.${text(_user, 'id')}.${widget.id}';

  @override
  void initState() {
    super.initState();
    _sessionToken = widget.api.token;
    WidgetsBinding.instance.addObserver(this);
    _draft.addListener(_persistDraft);
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_appActive && ModalRoute.of(context)?.isCurrent == true) {
        _refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive && ModalRoute.of(context)?.isCurrent == true) {
      _refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _restoreDraft() async {
    if (_storageReady) return;
    try {
      final value = await HarborApi.storage.read(key: _storageKey);
      if (!mounted || value == null) return;
      final saved = data(jsonDecode(value));
      if (_draft.text.isEmpty) _draft.text = text(saved, 'draft');
      for (final item in objects(saved['queued'])) {
        final id = text(item, 'id');
        _queued[id] = _QueuedMessage(
          id,
          text(item, 'body'),
          text(item, 'created_at'),
          error: '发送未确认，点击重试。',
        );
      }
    } catch (_) {
      // The conversation remains available without local draft storage.
    } finally {
      _storageReady = true;
    }
  }

  void _persistDraft() {
    if (!_storageReady || text(_user, 'id').isEmpty) return;
    final api = widget.api;
    final key = _storageKey;
    final value = _draft.text.isEmpty && _queued.isEmpty
        ? null
        : jsonEncode({
            'draft': _draft.text,
            'queued': _queued.values.map((item) => item.toJson()).toList(),
          });
    _writes = _writes.then((_) async {
      if (api.token != _sessionToken) return;
      try {
        if (value == null) {
          await HarborApi.storage.delete(key: key);
        } else {
          await HarborApi.storage.write(key: key, value: value);
        }
      } catch (_) {
        // The visible draft and retry entries remain usable during this visit.
      }
    });
  }

  void _merge(List<Data> rows, {bool latest = false}) {
    if (latest) {
      // Replace the portion covered by the server response so moderation removals
      // disappear upon refresh. Earlier pages already in view stay available.
      final floor = rows.length == _pageSize
          ? text(rows.first, 'created_at')
          : null;
      final lowerBound = floor == null ? null : _parse(floor);
      _messages.removeWhere(
        (id, item) =>
            !_sentDuringRefresh.contains(id) &&
            (lowerBound == null || _time(item).compareTo(lowerBound) >= 0),
      );
    }
    var confirmed = false;
    for (final item in rows) {
      final id = text(item, 'id');
      _messages[id] = item;
      confirmed = _queued.remove(id) != null || confirmed;
    }
    if (confirmed) _persistDraft();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    _sentDuringRefresh.clear();
    try {
      if (_user.isEmpty) _user = await widget.api.request('/me');
      final results = await Future.wait([
        widget.api.request(_path),
        widget.api.request('$_path/messages?limit=$_pageSize'),
      ]);
      if (!mounted) return;
      await _restoreDraft();
      if (!mounted) return;
      final details = results.first;
      final latest = objects(results.last['items']);
      setState(() {
        if (_conversation?['appointment_id'] != details['appointment_id']) {
          _appointment = null;
        }
        _conversation = details;
        _accessible = true;
        _error = null;
        _merge(latest, latest: true);
        if (_before == null || latest.length < _pageSize) {
          _hasPast = latest.length == _pageSize;
          _before = latest.isEmpty ? null : text(latest.first, 'created_at');
        }
      });
      if (_appointment == null && text(details, 'appointment_id').isNotEmpty) {
        _loadAppointment();
      }
      if (_appActive &&
          ModalRoute.of(context)?.isCurrent == true &&
          ((details['unread'] as num?)?.toInt() ?? 0) > 0) {
        try {
          await widget.api.post('$_path/read');
        } catch (_) {
          // A later refresh retries the server's unread update.
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        if (error is ApiError && {401, 403, 404}.contains(error.status)) {
          _accessible = false;
          _conversation = null;
          _appointment = null;
          _messages.clear();
          _before = null;
        }
      });
    } finally {
      _loading = false;
    }
  }

  Future<void> _past() async {
    final before = _before;
    if (_loadingPast || !_hasPast || before == null) return;
    setState(() => _loadingPast = true);
    try {
      final cursor = Uri.encodeQueryComponent(before);
      final rows = await widget.api.list(
        '$_path/messages?limit=$_pageSize&before=$cursor',
      );
      if (!mounted || !_accessible) return;
      setState(() {
        _merge(rows);
        _hasPast = rows.length == _pageSize;
        if (rows.isNotEmpty) _before = text(rows.first, 'created_at');
      });
    } catch (error) {
      if (mounted) flash(context, error);
    } finally {
      if (mounted) setState(() => _loadingPast = false);
    }
  }

  void _send() {
    final body = _draft.text.trim();
    if (body.isEmpty || _readOnly || !_accessible) return;
    final item = _QueuedMessage(
      newID(),
      body,
      DateTime.now().toUtc().toIso8601String(),
    );
    setState(() => _queued[item.id] = item);
    _draft.clear();
    _scrollToBottom();
    _deliver(item);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _deliver(_QueuedMessage item) async {
    if (!_accessible || _readOnly || item.sending) return;
    setState(() {
      item.sending = true;
      item.error = null;
    });
    _persistDraft();
    try {
      final stored = await widget.api.post('$_path/messages', {
        'id': item.id,
        'body': item.body,
      });
      if (!mounted || !_accessible) return;
      setState(() {
        if (_loading) _sentDuringRefresh.add(item.id);
        _merge([stored]);
      });
    } catch (error) {
      if (!mounted || !_queued.containsKey(item.id)) return;
      setState(() {
        item.sending = false;
        item.error = error.toString();
      });
      if (error is ApiError && {401, 403, 404, 409}.contains(error.status)) {
        _refresh();
      }
    }
  }

  Future<void> _peerAction(String action) async {
    final block = action == 'block';
    final name = text(_conversation ?? {}, 'name');
    final target = text(_conversation ?? {}, 'participant_id');
    final agreed = await confirmAction(
      context,
      block ? '屏蔽 $name？' : '结束这次交流？',
      block ? '屏蔽后，双方无法继续发送消息。你可以在屏蔽名单取消屏蔽。' : '这段会话会保留为只读。以后想继续交流，可以重新发起申请。',
      confirm: block ? '屏蔽' : '结束交流',
    );
    if (!agreed || !mounted) return;
    try {
      await widget.api.post(block ? '/blocks/$target' : '$_path/close');
      if (!mounted) return;
      setState(() => _conversation = {...?_conversation, 'read_only': true});
      flash(context, block ? '已屏蔽该同学' : '已结束交流');
      _refresh();
    } catch (error) {
      if (mounted) flash(context, error);
    }
  }

  Future<void> _showAppointment() async {
    final id = text(_conversation ?? {}, 'appointment_id');
    try {
      _appointment ??= await widget.api.request('/appointments/$id');
      if (!mounted || !_accessible || _appointment == null) return;
      final appointment = _appointment!;
      showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('预约信息', style: Theme.of(sheet).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(
                  '${stamp(appointment['start_at'], date: true)} · ${modeName(appointment['mode'])}',
                ),
                Text(
                  '${text(appointment, 'staff_name')} · ${stateName(appointment['status'])}',
                ),
                if (text(appointment, 'location').isNotEmpty)
                  Text(text(appointment, 'location')),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) flash(context, error);
    }
  }

  Future<void> _loadAppointment() async {
    final id = text(_conversation ?? {}, 'appointment_id');
    if (_loadingAppointment || id.isEmpty) return;
    _loadingAppointment = true;
    try {
      final appointment = await widget.api.request('/appointments/$id');
      if (mounted && _accessible && _conversation?['appointment_id'] == id) {
        setState(() => _appointment = appointment);
      }
    } catch (_) {
      // An explicit tap on the appointment can surface the server error.
    } finally {
      _loadingAppointment = false;
    }
  }

  Future<void> _bubbleActions(Data message, bool received) async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制消息'),
              onTap: () => Navigator.pop(sheet, 'copy'),
            ),
            if (received && _isPeer)
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('举报消息'),
                onTap: () => Navigator.pop(sheet, 'report'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !_accessible) return;
    if (selection == 'copy') {
      await Clipboard.setData(ClipboardData(text: text(message, 'body')));
      if (mounted) flash(context, '已复制');
    } else if (selection == 'report') {
      await reportContent(context, widget.api, 'message', text(message, 'id'));
    }
  }

  Widget _bubble(Data message) {
    final id = text(message, 'id');
    final queued = _queued[id];
    final mine = queued != null || message['sender_id'] == _user['id'];
    final theme = Theme.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .78,
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Semantics(
              label:
                  '${mine ? '我' : text(message, 'sender_name')} ${stamp(message['created_at'])}',
              child: GestureDetector(
                onLongPress: queued == null
                    ? () => _bubbleActions(message, !mine)
                    : null,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: mine
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surface,
                    border: mine
                        ? null
                        : Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 9,
                    ),
                    child: Text(
                      text(message, 'body'),
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                    ),
                  ),
                ),
              ),
            ),
            if (queued != null)
              queued.sending
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('发送中', style: theme.textTheme.labelMedium),
                    )
                  : TextButton.icon(
                      onPressed: _readOnly ? null : () => _deliver(queued),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: Text(
                        _readOnly ? '未发送 · 会话已结束' : queued.error ?? '未发送，点此重试',
                      ),
                    ),
          ],
        ),
      ),
    );
  }

  Widget _timeline() {
    final all =
        [
          ..._messages.values,
          for (final item in _queued.values) item.toJson(),
        ]..sort((a, b) {
          final byTime = _time(b).compareTo(_time(a));
          return byTime == 0 ? text(b, 'id').compareTo(text(a, 'id')) : byTime;
        });
    if (all.isEmpty) {
      return const Center(
        child: Empty(
          '还没有消息',
          body: '发送一条消息，开始交流。',
          icon: Icons.chat_bubble_outline,
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
      itemCount: all.length + (_hasPast ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == all.length) {
          return Center(
            child: TextButton(
              onPressed: _loadingPast ? null : _past,
              child: Text(_loadingPast ? '正在加载…' : '查看更早的消息'),
            ),
          );
        }
        final item = all[index];
        final when = _time(item).toLocal();
        final earlier = index + 1 < all.length
            ? _time(all[index + 1]).toLocal()
            : null;
        final sameSender =
            earlier != null &&
            text(all[index + 1], 'sender_id') == text(item, 'sender_id');
        final separate =
            earlier == null ||
            !DateUtils.isSameDay(when, earlier) ||
            when.difference(earlier) >= const Duration(minutes: 10);
        return Padding(
          padding: EdgeInsets.only(bottom: index == 0 ? 0 : 8),
          child: Column(
            children: [
              if (separate)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    stamp(
                      item['created_at'],
                      date: !DateUtils.isSameDay(when, DateTime.now()),
                    ),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              if (!separate && !sameSender) const SizedBox(height: 12),
              _bubble(item),
            ],
          ),
        );
      },
    );
  }

  Widget _composer() {
    final colors = Theme.of(context).colorScheme;
    if (_readOnly) {
      final closed = _conversation?['closed'] == true;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            closed && _isPeer
                ? '交流已结束。想继续聊，可以在对方社区主页重新申请。'
                : '此会话暂不可继续发送，历史消息仍可查看。',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      );
    }
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 7, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _draft,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 5,
                maxLength: 2000,
                decoration: const InputDecoration(
                  hintText: '写条消息',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _draft,
              builder: (_, value, _) => IconButton.filled(
                tooltip: '发送',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: value.text.trim().isEmpty ? null : _send,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = _conversation;
    return Scaffold(
      appBar: AppBar(
        title: details == null
            ? const Text('会话')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text(details, 'name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _isPeer ? '同学交流' : _serviceTag(details),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
        actions: [
          if (_isPeer)
            PopupMenuButton<String>(
              tooltip: '会话操作',
              onSelected: _peerAction,
              itemBuilder: (_) => [
                if (!_readOnly)
                  const PopupMenuItem(value: 'close', child: Text('结束交流')),
                const PopupMenuItem(value: 'block', child: Text('屏蔽这位同学')),
              ],
            ),
        ],
      ),
      body: !_accessible
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : LoadError(_error!, _refresh),
            )
          : Column(
              children: [
                if (text(details ?? {}, 'appointment_id').isNotEmpty)
                  ListTile(
                    leading: const Icon(
                      Icons.event_available_outlined,
                      size: 21,
                    ),
                    title: Text(
                      _appointment == null
                          ? '预约信息'
                          : '${stamp(_appointment!['start_at'], date: true)} · ${modeName(_appointment!['mode'])}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    dense: true,
                    onTap: _showAppointment,
                  ),
                if (_error != null)
                  Material(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    child: ListTile(
                      dense: true,
                      title: const Text('连接暂时中断，正在尝试恢复'),
                      trailing: TextButton(
                        onPressed: _refresh,
                        child: const Text('刷新'),
                      ),
                    ),
                  ),
                Expanded(child: _timeline()),
                const Divider(),
                _composer(),
              ],
            ),
    );
  }
}

DateTime _parse(String raw) =>
    DateTime.tryParse(raw)?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
DateTime _time(Data row) => _parse(text(row, 'created_at'));
