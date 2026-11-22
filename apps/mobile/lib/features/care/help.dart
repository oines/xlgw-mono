import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import '../messages.dart';
import 'widgets.dart';

class HelpPage extends StatefulWidget {
  const HelpPage(this.api, {super.key, this.work = false});
  final HarborApi api;
  final bool work;
  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  List<Data> rows = [];
  bool loading = true;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.list(
        '/help-requests${widget.work ? '?scope=work' : ''}',
      );
      if (mounted) setState(() => rows = result);
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> create() async {
    await open(context, _HelpCreate(widget.api));
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.work ? '人工求助' : '希望有人联系我')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? LoadError(error!, load)
        : HarborList(
            refresh: load,
            children: [
              if (!widget.work) ...[
                Text(
                  '留下一份联系请求',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  '告诉校内工作人员怎么联系你。提交后可以在这里查看处理进度。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
              ],
              if (rows.isEmpty)
                Empty(
                  widget.work ? '当前没有联系请求' : '你还没有提交联系请求',
                  body: widget.work ? '被分配的请求会出现在这里。' : '需要的时候，可以先把想说的话写下来。',
                  icon: Icons.support_agent_outlined,
                ),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        await open(
                          context,
                          HelpDetail(widget.api, row['id'], work: widget.work),
                        );
                        if (mounted) load();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.work
                                        ? text(row, 'student_name')
                                        : '联系请求',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                CareStatus(row['status']),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              text(row, 'body'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    stamp(row['created_at'], date: true),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 18),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
    bottomNavigationBar: widget.work
        ? null
        : CareBottomActions(
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: create,
                  icon: const Icon(Icons.add),
                  label: const Text('发起联系请求'),
                ),
              ),
            ],
          ),
  );
}

class _HelpCreate extends StatefulWidget {
  const _HelpCreate(this.api);
  final HarborApi api;
  @override
  State<_HelpCreate> createState() => _HelpCreateState();
}

class _HelpCreateState extends State<_HelpCreate> {
  final form = GlobalKey<FormState>();
  final contact = TextEditingController();
  final body = TextEditingController();
  final preferred = TextEditingController();
  Data school = {};
  bool busy = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    widget.api
        .request('/school')
        .then((value) {
          if (mounted) setState(() => school = value);
        })
        .catchError((Object caught) {
          if (mounted) setState(() => error = caught);
        });
  }

  @override
  void dispose() {
    contact.dispose();
    body.dispose();
    preferred.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.post('/help-requests', {
        'contact': contact.text.trim(),
        'body': body.text.trim(),
        'preferred_time': preferred.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => HelpDetail(widget.api, result['id'])),
      );
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('发起联系请求')),
    body: Form(
      key: form,
      child: HarborList(
        children: [
          CareActionError(error),
          Text('我们可以怎样联系你？', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          if (text(school, 'service_hours').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                '学校服务时间：${text(school, 'service_hours')}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          TextFormField(
            controller: contact,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: '联系方式',
              hintText: '手机、邮箱或其他方便联系的方式',
            ),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? '请填写联系方式' : null,
          ),
          const SizedBox(height: 18),
          TextFormField(
            controller: preferred,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: '方便联系的时间（选填）',
              hintText: '例如：工作日下午四点以后',
            ),
          ),
          const SizedBox(height: 18),
          TextFormField(
            controller: body,
            minLines: 5,
            maxLines: 10,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '想说明的事情',
              hintText: '简单告诉我们，你希望得到怎样的支持。',
            ),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? '请简单说明你的需求' : null,
          ),
          const SizedBox(height: 12),
          Text(
            '提交后，学校会分配负责人员。联系方式仅用于这次请求的接待与跟进。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
    bottomNavigationBar: CareBottomActions(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? '正在提交…' : '提交请求'),
          ),
        ),
      ],
    ),
  );
}

class HelpDetail extends StatefulWidget {
  const HelpDetail(this.api, this.id, {super.key, this.work = false});
  final HarborApi api;
  final String id;
  final bool work;
  @override
  State<HelpDetail> createState() => _HelpDetailState();
}

class _HelpDetailState extends State<HelpDetail> {
  Data? row;
  bool loading = true, busy = false;
  Object? error, actionError;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request('/help-requests/${widget.id}');
      if (mounted) setState(() => row = result);
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> act(String action) async {
    Data body = {};
    if (action != 'claim') {
      final result = await showDialog<Data>(
        context: context,
        builder: (_) => CareContactDialog(
          action == 'contact' ? '记录联系' : '结束本次跟进',
          required: action == 'contact',
        ),
      );
      if (result == null || !mounted) return;
      body = result;
    }
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      await widget.api.post('/help-requests/${widget.id}/$action', body);
      if (!mounted) return;
      flash(context, '联系进度已更新');
      await load();
    } catch (caught) {
      if (mounted) setState(() => actionError = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('联系请求')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? LoadError(error!, load)
        : HarborList(
            refresh: load,
            children: [
              CareActionError(actionError),
              CareStatus(row!['status']),
              const SizedBox(height: 20),
              Text(
                widget.work ? '${text(row!, 'student_name')}的联系请求' : '让这次联系有进展',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 20),
              CareInfoLine(
                Icons.person_outline,
                '负责人员',
                text(row!, 'staff_name', '等待分配'),
              ),
              CareInfoLine(Icons.phone_outlined, '联系方式', text(row!, 'contact')),
              CareInfoLine(
                Icons.schedule_outlined,
                '方便时间',
                text(row!, 'preferred_time', '未特别说明'),
              ),
              const CareSection('想说明的事情'),
              SelectableText(text(row!, 'body')),
              if (text(row!, 'conversation_id').isNotEmpty) ...[
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () => open(
                    context,
                    ChatPage(widget.api, row!['conversation_id']),
                  ),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('进入服务会话'),
                ),
              ],
              CareHistory(objects(row!['history'])),
            ],
          ),
    bottomNavigationBar:
        !widget.work || row == null || row!['status'] == 'closed'
        ? null
        : CareBottomActions(
            children: [
              if (row!['status'] == 'assigned')
                FilledButton(
                  onPressed: busy ? null : () => act('claim'),
                  child: const Text('接收请求'),
                ),
              if (['assigned', 'contacting'].contains(row!['status'])) ...[
                OutlinedButton(
                  onPressed: busy ? null : () => act('close'),
                  child: const Text('结案'),
                ),
                FilledButton(
                  onPressed: busy ? null : () => act('contact'),
                  child: const Text('记录联系'),
                ),
              ],
            ],
          ),
  );
}
