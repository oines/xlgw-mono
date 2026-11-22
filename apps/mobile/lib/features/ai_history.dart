import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/design.dart';

class AiHistory extends StatefulWidget {
  const AiHistory(this.api, {super.key, required this.current});
  final HarborApi api;
  final String current;
  @override
  State<AiHistory> createState() => _AiHistoryState();
}

class _AiHistoryState extends State<AiHistory> {
  List<Data> rows = [];
  final search = TextEditingController();
  Object? error;
  bool busy = true;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final e = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final items = await widget.api.list(
        '/ai/conversations?q=${Uri.encodeQueryComponent(search.text.trim())}',
      );
      if (mounted && e == epoch) setState(() => rows = items);
    } catch (err) {
      if (mounted && e == epoch) setState(() => error = err);
    } finally {
      if (mounted && e == epoch) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> manage(Data item, String action) async {
    final id = text(item, 'id');
    try {
      if (action == 'rename') {
        final title = await askText(
          context,
          '重命名会话',
          '会话名称',
          initial: text(item, 'title'),
          maxLength: 80,
          confirm: '保存',
        );
        if (title == null) return;
        await widget.api.patch('/ai/conversations/$id', {'title': title});
      } else {
        if (!await confirmAction(
          context,
          '删除这段会话？',
          '会话历史会从账号移除，关联的分享也会失效。',
          confirm: '删除',
        ))
          return;
        await widget.api.delete('/ai/conversations/$id');
        if (mounted && widget.current == id) {
          Navigator.pop(context, {'deleted': id});
          return;
        }
      }
      if (mounted) await reload();
    } catch (e) {
      if (mounted) flash(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('会话历史'),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, {'new': true}),
          icon: const Icon(Icons.add),
          label: const Text('新对话'),
        ),
      ],
    ),
    body: HarborList(
      refresh: reload,
      children: [
        TextField(
          controller: search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: '搜索会话标题',
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      search.clear();
                      reload();
                    },
                    tooltip: '清除',
                    icon: const Icon(Icons.clear),
                  ),
          ),
          onChanged: (_) => reload(),
        ),
        const SizedBox(height: 14),
        if (busy && rows.isEmpty)
          const Center(child: CircularProgressIndicator()),
        if (error != null) LoadError(error!, reload),
        if (!busy && error == null && rows.isEmpty)
          const Empty('没有找到会话', icon: Icons.chat_bubble_outline),
        for (final item in rows) ...[
          ListTile(
            onTap: () => Navigator.pop(context, item),
            leading: const Icon(Icons.chat_bubble_outline_rounded),
            title: Text(text(item, 'title', '新对话')),
            subtitle: Text(stamp(item['updated_at'], date: true)),
            selected: item['id'] == widget.current,
            trailing: PopupMenuButton<String>(
              onSelected: (a) => manage(item, a),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ),
          const Divider(),
        ],
      ],
    ),
  );
}
