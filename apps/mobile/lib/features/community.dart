import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../shared/api.dart';
import '../shared/design.dart';

const _moods = ['平静', '开心', '低落', '焦虑', '疲惫', '孤单', '生气', '期待', '迷茫'];
const _sorts = {'latest': '最新', 'hot': '热门', 'resonance': '最多共鸣'};

class CommunityPage extends StatefulWidget {
  const CommunityPage(this.api, this.user, {super.key});
  final HarborApi api;
  final Data user;
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  String _sort = 'latest';
  late Future<List<Data>> _posts = _load();

  Future<List<Data>> _load() => widget.api.list('/posts?sort=$_sort');
  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _posts = next;
    });
    try {
      await next;
    } catch (_) {
      // The feed renders the request error in place.
    }
  }

  Future<void> _create() async {
    final post = await open<Data>(
      context,
      _PostEditor(widget.api, widget.user),
    );
    if (!mounted || post == null) return;
    _refresh();
    await open(context, PostDetail(widget.api, text(post, 'id'), widget.user));
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('共鸣社区'),
      actions: [
        IconButton(
          tooltip: '我的社区主页',
          icon: const Icon(Icons.account_circle_outlined),
          onPressed: () async {
            await open(
              context,
              _AuthorPage(widget.api, text(widget.user, 'id'), widget.user),
            );
            if (mounted) _refresh();
          },
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Row(
          children: [
            for (final entry in _sorts.entries)
              Expanded(
                child: _FilterTab(
                  title: entry.value,
                  selected: entry.key == _sort,
                  select: () {
                    if (entry.key == _sort) return;
                    setState(() {
                      _sort = entry.key;
                      _posts = _load();
                    });
                  },
                ),
              ),
          ],
        ),
      ),
    ),
    body: FutureBuilder<List<Data>>(
      future: _posts,
      builder: (_, snapshot) {
        if (snapshot.hasError && !snapshot.hasData) {
          return Center(child: LoadError(snapshot.error!, _refresh));
        }
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final items = snapshot.data!;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 90),
            children: [
              if (items.isEmpty)
                const Empty(
                  '社区还没有帖子',
                  body: '分享一个最近的感受，开启一次交流。',
                  icon: Icons.forum_outlined,
                ),
              for (final post in items) ...[
                _PostItem(
                  key: ValueKey(text(post, 'id')),
                  api: widget.api,
                  user: widget.user,
                  post: post,
                  onChange: _refresh,
                ),
                const Divider(),
              ],
            ],
          ),
        );
      },
    ),
    floatingActionButton: FloatingActionButton(
      tooltip: '发布帖子',
      onPressed: _create,
      child: const Icon(Icons.edit_outlined),
    ),
  );
}

class _FilterTab extends StatelessWidget {
  const _FilterTab({
    required this.title,
    required this.selected,
    required this.select,
  });
  final String title;
  final bool selected;
  final VoidCallback select;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: select,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            title,
            style: TextStyle(
              color: selected ? colors.primary : colors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PostItem extends StatefulWidget {
  const _PostItem({
    super.key,
    required this.api,
    required this.user,
    required this.post,
    required this.onChange,
    this.full = false,
  });
  final HarborApi api;
  final Data user, post;
  final Future<void> Function() onChange;
  final bool full;

  @override
  State<_PostItem> createState() => _PostItemState();
}

class _PostItemState extends State<_PostItem> {
  late Data _post = widget.post;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant _PostItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post != widget.post) _post = widget.post;
  }

  String get _id => text(_post, 'id');
  String get _author => text(_post, 'author_id');
  bool get _own => _author == text(widget.user, 'id');

  Future<void> _openPost() async {
    if (widget.full) return;
    await open(context, PostDetail(widget.api, _id, widget.user));
    if (mounted) await widget.onChange();
  }

  Future<void> _openAuthor() async {
    await open(context, _AuthorPage(widget.api, _author, widget.user));
    if (mounted) await widget.onChange();
  }

  Future<void> _react() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.api.put('/posts/$_id/resonance', {
        'active': _post['resonated'] != true,
      });
      if (mounted) setState(() => _post = updated);
    } catch (err) {
      if (mounted) flash(context, err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(String action) async {
    switch (action) {
      case 'edit':
        final updated = await open<Data>(
          context,
          _PostEditor(widget.api, widget.user, editing: _post),
        );
        if (!mounted || updated == null) return;
        setState(() => _post = updated);
        await widget.onChange();
      case 'delete':
        if (!await confirmAction(
          context,
          '删除帖子',
          '删除后其他同学将无法看到这篇帖子。',
          confirm: '删除',
        ))
          return;
        try {
          await widget.api.delete('/posts/$_id');
          if (!mounted) return;
          if (widget.full) {
            Navigator.pop(context);
          } else {
            await widget.onChange();
          }
        } catch (err) {
          if (mounted) flash(context, err);
        }
      case 'report':
        await reportContent(context, widget.api, 'post', _id);
      case 'block':
        if (await _manageBlock(
              context,
              widget.api,
              _author,
              text(_post, 'author_name'),
              false,
            ) &&
            mounted) {
          if (widget.full) {
            Navigator.pop(context);
          } else {
            await widget.onChange();
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = _post['resonated'] == true;
    final tags =
        (_post['tags'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final name = text(_post, 'author_name', '同学');

    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: _openAuthor,
                    child: Row(
                      children: [
                        PersonIcon(
                          name,
                          url: text(_post, 'author_avatar'),
                          radius: 18,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                              Text(
                                [
                                  stamp(_post['created_at'], date: true),
                                  if (_post['edited'] == true) '已编辑',
                                ].join(' · '),
                                style: theme.textTheme.labelMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '帖子操作',
                  onSelected: _act,
                  itemBuilder: (_) => _own
                      ? const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ]
                      : const [
                          PopupMenuItem(value: 'report', child: Text('举报')),
                          PopupMenuItem(value: 'block', child: Text('屏蔽作者')),
                        ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.full ? null : _openPost,
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  text(_post, 'body'),
                  maxLines: widget.full ? null : 6,
                  overflow: widget.full
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: tags.map((tag) => _MoodLabel(tag)).toList(),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : _react,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    foregroundColor: active
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  icon: Icon(
                    active ? Icons.favorite : Icons.favorite_border,
                    size: 20,
                  ),
                  label: Text('共鸣 ${text(_post, 'resonances', '0')}'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: widget.full ? null : _openPost,
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 20),
                  label: Text('评论 ${text(_post, 'comments', '0')}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MoodLabel extends StatelessWidget {
  const _MoodLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
        child: Text(label, style: theme.textTheme.labelMedium),
      ),
    );
  }
}

class _PostEditor extends StatefulWidget {
  const _PostEditor(this.api, this.user, {this.editing});
  final HarborApi api;
  final Data user;
  final Data? editing;

  @override
  State<_PostEditor> createState() => _PostEditorState();
}

class _PostEditorState extends State<_PostEditor> {
  late final TextEditingController _body;
  late final String? _sessionToken;
  final Set<String> _tags = {};
  bool _sending = false;
  bool _ready = false;
  Timer? _debounce;
  Future<void> _draftWrites = Future.value();
  String get _draftKey => 'harbor.post.draft.${text(widget.user, 'id')}';
  bool get _new => widget.editing == null;

  @override
  void initState() {
    super.initState();
    _sessionToken = widget.api.token;
    _body = TextEditingController(text: text(widget.editing ?? {}, 'body'));
    _tags.addAll(
      (widget.editing?['tags'] as List?)?.whereType<String>() ?? const [],
    );
    _readDraft();
    _body.addListener(_changed);
  }

  Future<void> _readDraft() async {
    if (_new) {
      try {
        final raw = await HarborApi.storage.read(key: _draftKey);
        if (!mounted) return;
        if (raw != null) {
          final draft = data(jsonDecode(raw));
          _body.text = text(draft, 'body');
          _tags.addAll(
            (draft['tags'] as List?)?.whereType<String>() ?? const [],
          );
        }
      } catch (_) {
        // Draft storage is optional on devices that block local storage.
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  void _changed() {
    if (!_ready) return;
    setState(() {});
    if (!_new) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _saveDraft);
  }

  void _saveDraft() {
    if (!_ready || !_new) return;
    final draft = jsonEncode({'body': _body.text, 'tags': _tags.toList()});
    final key = _draftKey;
    final api = widget.api;
    _draftWrites = _draftWrites
        .then((_) async {
          if (api.token == _sessionToken) {
            await HarborApi.storage.write(key: key, value: draft);
          }
        })
        .catchError((Object _) {});
  }

  Future<void> _submit() async {
    if (_sending || _body.text.trim().isEmpty || _tags.isEmpty) return;
    setState(() => _sending = true);
    final payload = <String, dynamic>{
      'body': _body.text.trim(),
      'tags': _tags.toList(),
    };
    try {
      final result = _new
          ? await widget.api.post('/posts', payload)
          : await widget.api.patch(
              '/posts/${text(widget.editing!, 'id')}',
              payload,
            );
      if (_new) {
        _debounce?.cancel();
        _ready = false;
        await _draftWrites;
        try {
          await HarborApi.storage.delete(key: _draftKey);
        } catch (_) {
          // The server result still applies if local storage has failed.
        }
      }
      if (mounted) Navigator.pop(context, result);
    } catch (err) {
      if (mounted) flash(context, err);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _saveDraft();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_new ? '写帖子' : '编辑帖子'),
      actions: [
        TextButton(
          onPressed:
              !_ready || _sending || _body.text.trim().isEmpty || _tags.isEmpty
              ? null
              : _submit,
          child: Text(
            _sending
                ? '提交中…'
                : _new
                ? '发布'
                : '保存',
          ),
        ),
      ],
    ),
    body: !_ready
        ? const Center(child: CircularProgressIndicator())
        : HarborList(
            children: [
              TextField(
                controller: _body,
                enabled: !_sending,
                minLines: 8,
                maxLines: 16,
                maxLength: 2000,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: const InputDecoration(hintText: '把此刻的感受写下来'),
              ),
              const SizedBox(height: 16),
              Text('选择情绪标签', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('选择 1–3 项', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mood in _moods)
                    FilterChip(
                      label: Text(mood),
                      selected: _tags.contains(mood),
                      onSelected: _sending
                          ? null
                          : (selected) {
                              if (selected && _tags.length >= 3) {
                                flash(context, '最多选择三项情绪');
                                return;
                              }
                              if (selected) {
                                _tags.add(mood);
                              } else {
                                _tags.remove(mood);
                              }
                              _changed();
                            },
                    ),
                ],
              ),
              if (_new && _body.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    '草稿会保留在这台设备',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
            ],
          ),
  );
}

class PostDetail extends StatefulWidget {
  const PostDetail(this.api, this.id, this.user, {super.key});
  final HarborApi api;
  final String id;
  final Data user;
  @override
  State<PostDetail> createState() => _PostDetailState();
}

class _PostDetailState extends State<PostDetail> {
  final _comment = TextEditingController();
  final _focus = FocusNode();
  late Future<(Data, List<Data>)> _state = _load();
  Data? _reply;
  bool _sending = false;
  final _expanded = <String>{};
  String get _path => '/posts/${widget.id}';

  Future<(Data, List<Data>)> _load() async {
    final list = await Future.wait([
      widget.api.request(_path),
      widget.api.request('$_path/comments'),
    ]);
    return (list[0], objects(list[1]['items']));
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _state = next;
    });
    try {
      await next;
    } catch (_) {
      /* Rendering handles request errors. */
    }
  }

  Future<void> _send() async {
    final content = _comment.text.trim();
    if (_sending || content.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.api.post('$_path/comments', {
        'body': content,
        if (_reply != null) 'parent_id': text(_reply!, 'id'),
      });
      if (!mounted) return;
      _comment.clear();
      setState(() => _reply = null);
      await _refresh();
    } catch (err) {
      if (mounted) {
        flash(context, err is ApiError ? err.message : '评论暂时发不出去，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _commentAction(String action, Data comment) async {
    switch (action) {
      case 'reply':
        setState(() => _reply = comment);
        _focus.requestFocus();
      case 'report':
        await reportContent(
          context,
          widget.api,
          'comment',
          text(comment, 'id'),
        );
      case 'delete':
        if (!await confirmAction(
          context,
          '删除评论',
          '删除后其他同学无法看到这条评论。',
          confirm: '删除',
        ))
          return;
        try {
          await widget.api.delete('/comments/${text(comment, 'id')}');
          if (mounted) _refresh();
        } catch (err) {
          if (mounted) flash(context, err);
        }
    }
  }

  Widget _renderComment(Data comment, {bool nested = false}) {
    final theme = Theme.of(context);
    final name = text(comment, 'author_name', '同学');
    final own = text(comment, 'author_id') == text(widget.user, 'id');
    return Padding(
      padding: EdgeInsets.fromLTRB(nested ? 36 : 20, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => open(
              context,
              _AuthorPage(widget.api, text(comment, 'author_id'), widget.user),
            ),
            child: PersonIcon(
              name,
              url: text(comment, 'author_avatar'),
              radius: 14,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => open(
                    context,
                    _AuthorPage(
                      widget.api,
                      text(comment, 'author_id'),
                      widget.user,
                    ),
                  ),
                  child: Text(name, style: theme.textTheme.titleSmall),
                ),
                Text(
                  stamp(comment['created_at'], date: true),
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                Text(text(comment, 'body'), style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '评论操作',
            onSelected: (action) => _commentAction(action, comment),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'reply', child: Text('回复')),
              if (own) const PopupMenuItem(value: 'delete', child: Text('删除')),
              if (!own) const PopupMenuItem(value: 'report', child: Text('举报')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _comment.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('帖子')),
    body: FutureBuilder<(Data, List<Data>)>(
      future: _state,
      builder: (_, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error!;
          if (error is ApiError && error.status == 404) {
            return Center(
              child: Empty(
                '内容已不可用',
                action: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回社区'),
                ),
              ),
            );
          }
          return Center(child: LoadError(error, _refresh));
        }
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final (post, comments) = snapshot.data!;
        final roots = comments
            .where((c) => text(c, 'parent_id').isEmpty)
            .toList();
        final rootIDs = roots.map((c) => text(c, 'id')).toSet();
        final unattached = comments
            .where(
              (c) =>
                  text(c, 'parent_id').isNotEmpty &&
                  !rootIDs.contains(text(c, 'parent_id')),
            )
            .toList();
        final replies = <String, List<Data>>{};
        for (final comment in comments) {
          final parent = text(comment, 'parent_id');
          if (parent.isNotEmpty)
            replies.putIfAbsent(parent, () => []).add(comment);
        }
        return Column(
          children: [
            Expanded(
              child: HarborList(
                refresh: _refresh,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  _PostItem(
                    api: widget.api,
                    post: post,
                    user: widget.user,
                    full: true,
                    onChange: _refresh,
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text(
                      '评论 · ${comments.length}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (comments.isEmpty)
                    const Empty(
                      '还没有评论',
                      body: '可以留下一个简单的回应。',
                      icon: Icons.chat_bubble_outline,
                    ),
                  for (final comment in roots) ...[
                    _renderComment(comment),
                    ..._thread(
                      text(comment, 'id'),
                      replies[text(comment, 'id')] ?? const [],
                    ),
                    const Divider(),
                  ],
                  for (final comment in unattached) _renderComment(comment),
                ],
              ),
            ),
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    children: [
                      if (_reply != null)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '回复 ${text(_reply!, 'author_name', '同学')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: '取消回复',
                              onPressed: () => setState(() => _reply = null),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _comment,
                              focusNode: _focus,
                              enabled: !_sending,
                              maxLength: 500,
                              minLines: 1,
                              maxLines: 4,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                hintText: '写下你的回应',
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _sending || _comment.text.trim().isEmpty
                                ? null
                                : _send,
                            child: Text(_sending ? '发送中' : '发送'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  List<Widget> _thread(String id, List<Data> replies) {
    final expanded = _expanded.contains(id);
    final visible = expanded ? replies : replies.take(2);
    return [
      for (final reply in visible) _renderComment(reply, nested: true),
      if (replies.length > 2)
        Padding(
          padding: const EdgeInsets.only(left: 44),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                if (expanded) {
                  _expanded.remove(id);
                } else {
                  _expanded.add(id);
                }
              }),
              child: Text(expanded ? '收起回复' : '查看全部 ${replies.length} 条回复'),
            ),
          ),
        ),
    ];
  }
}

class _AuthorPage extends StatefulWidget {
  const _AuthorPage(this.api, this.id, this.user);
  final HarborApi api;
  final String id;
  final Data user;
  @override
  State<_AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<_AuthorPage> {
  bool _comments = false;
  bool _pending = false;
  late Future<(Data, List<Data>)> _state = _load();

  bool get _mine => widget.id == text(widget.user, 'id');

  Future<(Data, List<Data>)> _load() async {
    final person = await widget.api.request('/people/${widget.id}');
    final listPath = _comments
        ? '/comments?scope=mine'
        : '/posts?author_id=${widget.id}';
    final items = person['blocked'] == true
        ? <Data>[]
        : await widget.api.list(listPath);
    return (person, items);
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _state = next;
    });
    try {
      await next;
    } catch (_) {
      /* The page keeps the error visible. */
    }
  }

  Future<void> _invite() async {
    if (_pending) return;
    final note = await askText(
      context,
      '申请私下交流',
      '想和对方说些什么？',
      confirm: '发送申请',
      maxLength: 100,
      required: false,
    );
    if (!mounted || note == null) return;
    setState(() => _pending = true);
    try {
      await widget.api.post('/chat-requests', {
        'recipient_id': widget.id,
        'note': note,
      });
      if (mounted) flash(context, '申请已发送，对方接受后可以在消息里交流。');
    } catch (err) {
      if (mounted) flash(context, err);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_mine ? '我的社区主页' : '社区主页')),
    body: FutureBuilder<(Data, List<Data>)>(
      future: _state,
      builder: (_, snap) {
        if (snap.hasError)
          return Center(child: LoadError(snap.error!, _refresh));
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final (person, items) = snap.data!;
        final name = text(person, 'nickname', '同学');
        final blocked = person['blocked'] == true;
        return HarborList(
          padding: const EdgeInsets.only(bottom: 24),
          refresh: _refresh,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                children: [
                  PersonIcon(name, url: text(person, 'avatar_url'), radius: 32),
                  const SizedBox(height: 10),
                  Text(name, style: Theme.of(context).textTheme.headlineSmall),
                  if (!_mine) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (!blocked)
                          FilledButton.tonal(
                            onPressed: _pending ? null : _invite,
                            child: const Text('申请交流'),
                          ),
                        OutlinedButton(
                          onPressed: () async {
                            if (await _manageBlock(
                                  context,
                                  widget.api,
                                  widget.id,
                                  name,
                                  blocked,
                                ) &&
                                mounted)
                              _refresh();
                          },
                          child: Text(blocked ? '解除屏蔽' : '屏蔽'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (_mine)
              Row(
                children: [
                  Expanded(
                    child: _FilterTab(
                      title: '发布的帖子',
                      selected: !_comments,
                      select: () {
                        if (_comments) {
                          _comments = false;
                          _refresh();
                        }
                      },
                    ),
                  ),
                  Expanded(
                    child: _FilterTab(
                      title: '留下的评论',
                      selected: _comments,
                      select: () {
                        if (!_comments) {
                          _comments = true;
                          _refresh();
                        }
                      },
                    ),
                  ),
                ],
              ),
            if (items.isEmpty)
              Empty(
                blocked
                    ? '已屏蔽这位同学'
                    : _comments
                    ? '还没有评论'
                    : '还没有公开帖子',
              ),
            for (final value in items)
              if (_comments)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  title: Text(
                    text(value, 'body'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(stamp(value['created_at'], date: true)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(
                    context,
                    PostDetail(widget.api, text(value, 'post_id'), widget.user),
                  ),
                )
              else ...[
                _PostItem(
                  key: ValueKey(text(value, 'id')),
                  api: widget.api,
                  user: widget.user,
                  post: value,
                  onChange: _refresh,
                ),
                const Divider(),
              ],
          ],
        );
      },
    ),
  );
}

Future<bool> _manageBlock(
  BuildContext context,
  HarborApi api,
  String author,
  String name,
  bool blocked,
) async {
  if (!await confirmAction(
    context,
    blocked ? '解除屏蔽' : '屏蔽这位同学',
    blocked
        ? '解除后，你们可以按照社区规则重新交流。'
        : '屏蔽后不会看到 ${name.isEmpty ? '对方' : name} 的社区内容，对方也不能继续发起交流。',
    confirm: blocked ? '解除屏蔽' : '屏蔽',
  ))
    return false;
  try {
    if (blocked) {
      await api.delete('/blocks/$author');
    } else {
      await api.post('/blocks/$author');
    }
    if (context.mounted) flash(context, blocked ? '已解除屏蔽' : '已屏蔽');
    return true;
  } catch (err) {
    if (context.mounted) flash(context, err);
    return false;
  }
}

Future<void> reportContent(
  BuildContext context,
  HarborApi api,
  String type,
  String id,
) async {
  final payload = await showDialog<Data>(
    context: context,
    builder: (_) => const _ReportDialog(),
  );
  if (payload == null) return;
  try {
    await api.post('/reports', {
      'target_type': type,
      'target_id': id,
      ...payload,
    });
    if (context.mounted) flash(context, '举报已提交，请在通知里查看结果。');
  } catch (err) {
    if (context.mounted) flash(context, err);
  }
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog();
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  static const reasons = ['人身攻击或骚扰', '不当或危险内容', '泄露个人信息', '广告或垃圾信息', '其他'];
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('举报内容'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final reason in reasons)
              ChoiceChip(
                label: Text(reason),
                selected: _reason == reason,
                onSelected: (_) => setState(() => _reason = reason),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: '补充说明（选填）'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _reason == null
            ? null
            : () => Navigator.pop(context, {
                'reason': _reason,
                'note': _note.text.trim(),
              }),
        child: const Text('提交举报'),
      ),
    ],
  );
}
