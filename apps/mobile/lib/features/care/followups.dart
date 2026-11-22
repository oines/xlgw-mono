import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import 'widgets.dart';

class FollowupsPage extends StatefulWidget {
  const FollowupsPage(this.api, {super.key, this.work = false});
  final HarborApi api;
  final bool work;
  @override
  State<FollowupsPage> createState() => _FollowupsPageState();
}

class _FollowupsPageState extends State<FollowupsPage> {
  List<Data> rows = [];
  bool loading = true;
  Object? error;
  String filter = 'all';
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
        '/followups${widget.work ? '?scope=work' : ''}',
      );
      if (mounted) setState(() => rows = result);
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = rows
        .where(
          (row) =>
              filter == 'all' ||
              (widget.work
                  ? row['status'] != 'closed'
                  : row['submitted_at'] == null),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.work ? '回访与跟进' : '我的回访')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'all', label: Text('全部回访')),
                ButtonSegment(
                  value: 'pending',
                  label: Text(widget.work ? '待处理' : '待填写'),
                ),
              ],
              selected: {filter},
              onSelectionChanged: (value) =>
                  setState(() => filter = value.first),
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? LoadError(error!, load)
                : HarborList(
                    refresh: load,
                    children: [
                      if (visible.isEmpty)
                        Empty(
                          '暂时没有${filter == 'pending' ? '待处理的' : ''}回访',
                          body: '完成一次校内服务后，关联问卷会出现在这里。',
                          icon: Icons.assignment_outlined,
                        ),
                      for (final row in visible)
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
                                  FollowupDetail(
                                    widget.api,
                                    row['id'],
                                    work: widget.work,
                                  ),
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
                                            '咨询后的感受',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                        ),
                                        CareStatus(
                                          row['status'],
                                          label: widget.work
                                              ? null
                                              : row['submitted_at'] == null
                                              ? '待填写'
                                              : '已提交',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      widget.work
                                          ? '${text(row, 'student_name')} · ${text(row, 'staff_name')}'
                                          : '接待人员 · ${text(row, 'staff_name')}',
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            stamp(
                                              row['created_at'],
                                              date: true,
                                            ),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelMedium,
                                          ),
                                        ),
                                        const Icon(
                                          Icons.chevron_right,
                                          size: 18,
                                        ),
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
          ),
        ],
      ),
    );
  }
}

class FollowupDetail extends StatefulWidget {
  const FollowupDetail(this.api, this.id, {super.key, this.work = false});
  final HarborApi api;
  final String id;
  final bool work;
  @override
  State<FollowupDetail> createState() => _FollowupDetailState();
}

class _FollowupDetailState extends State<FollowupDetail> {
  Data? row;
  bool loading = true, busy = false;
  Object? error, actionError;
  String mood = '', helpfulness = '', recommendation = '';
  bool wantsContact = false;
  final note = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request('/followups/${widget.id}');
      if (!mounted) return;
      final answers = data(result['answers']);
      setState(() {
        row = result;
        mood = text(answers, 'mood');
        helpfulness = text(answers, 'helpfulness');
        recommendation = text(answers, 'recommendation');
        wantsContact = answers['contact_requested'] == true;
        note.text = text(answers, 'note');
      });
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Data get answers => {
    'mood': mood,
    'helpfulness': helpfulness,
    'recommendation': recommendation,
    'note': note.text.trim(),
    'contact_requested': wantsContact,
  };
  Future<void> save(bool submit) async {
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      if (submit) {
        await widget.api.post('/followups/${widget.id}/submit', answers);
      } else {
        await widget.api.put('/followups/${widget.id}/draft', answers);
      }
      if (!mounted) return;
      flash(context, submit ? '回访已提交，感谢你告诉我们后来的感受。' : '草稿已保存');
      if (submit) await load();
    } catch (caught) {
      if (mounted) setState(() => actionError = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> act(String action) async {
    Data body = {};
    if (action != 'resend') {
      final result = await showDialog<Data>(
        context: context,
        builder: (_) => CareContactDialog(
          action == 'contact'
              ? '记录联系'
              : action == 'close'
              ? '结束本次跟进'
              : '已阅，无需联系',
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
      await widget.api.post('/followups/${widget.id}/$action', body);
      if (!mounted) return;
      flash(context, action == 'resend' ? '填写提醒已发送' : '处理进度已更新');
      await load();
    } catch (caught) {
      if (mounted) setState(() => actionError = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitted = row?['submitted_at'] != null;
    final editable = !widget.work && !submitted;
    final status = row?['status'];
    return Scaffold(
      appBar: AppBar(
        title: const Text('咨询回访'),
        actions: [
          if (editable && row != null)
            TextButton(
              onPressed: busy ? null : () => save(false),
              child: const Text('保存草稿'),
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? LoadError(error!, load)
          : HarborList(
              children: [
                CareActionError(actionError),
                Row(
                  children: [
                    CareStatus(
                      status,
                      label: !widget.work && submitted ? '已提交' : null,
                    ),
                    const Spacer(),
                    Text(
                      stamp(row!['created_at'], date: true),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  widget.work
                      ? '${text(row!, 'student_name')}的咨询回访'
                      : '后来，感觉怎么样？',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  '关联接待人员：${text(row!, 'staff_name')}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (editable) ...[
                  const SizedBox(height: 26),
                  _ChoiceQuestion(
                    '目前的状态如何？',
                    '相比咨询之前，你现在的感受。',
                    const {
                      'better': '有所好转',
                      'same': '与之前差不多',
                      'worse': '感到更困扰',
                    },
                    mood,
                    (value) => setState(() => mood = value),
                    required: true,
                  ),
                  _ChoiceQuestion(
                    '这次交流有帮助吗？',
                    '',
                    const {
                      'helpful': '有帮助',
                      'neutral': '一般',
                      'unhelpful': '没有帮助',
                    },
                    helpfulness,
                    (value) => setState(() => helpfulness = value),
                    required: true,
                  ),
                  _ChoiceQuestion(
                    '愿意推荐给有需要的同学吗？',
                    '选填',
                    const {'愿意': '愿意', '不确定': '不确定', '不太愿意': '不太愿意'},
                    recommendation,
                    (value) => setState(() => recommendation = value),
                  ),
                  const CareSection('还想告诉我们什么'),
                  TextField(
                    controller: note,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      hintText: '可以写下感受、想法或建议（选填）',
                    ),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: wantsContact,
                    onChanged: (value) =>
                        setState(() => wantsContact = value ?? false),
                    title: const Text('希望工作人员继续联系我'),
                    subtitle: const Text('提交后会进入负责老师的跟进待办。'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ] else if (!submitted)
                  const Empty(
                    '同学尚未提交回答',
                    body: '问卷提交后，答案会显示在这里。',
                    icon: Icons.assignment_outlined,
                  )
                else ...[
                  const CareSection('回访回答'),
                  _Answer(
                    '目前状态',
                    const {
                          'better': '有所好转',
                          'same': '与之前差不多',
                          'worse': '感到更困扰',
                        }[mood] ??
                        mood,
                  ),
                  _Answer(
                    '帮助程度',
                    const {
                          'helpful': '有帮助',
                          'neutral': '一般',
                          'unhelpful': '没有帮助',
                        }[helpfulness] ??
                        helpfulness,
                  ),
                  _Answer(
                    '推荐意愿',
                    recommendation.isEmpty ? '未填写' : recommendation,
                  ),
                  _Answer('补充意见', note.text.isEmpty ? '未填写' : note.text),
                  _Answer('希望继续联系', wantsContact ? '是' : '否'),
                ],
                CareHistory(objects(row!['history'])),
              ],
            ),
      bottomNavigationBar: row == null || loading
          ? null
          : CareBottomActions(
              children: [
                if (editable)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy || mood.isEmpty || helpfulness.isEmpty
                          ? null
                          : () => save(true),
                      child: Text(busy ? '正在保存…' : '提交回访'),
                    ),
                  ),
                if (widget.work && status == 'awaiting')
                  OutlinedButton(
                    onPressed: busy ? null : () => act('resend'),
                    child: const Text('补发填写提醒'),
                  ),
                if (widget.work && status == 'pending_review')
                  OutlinedButton(
                    onPressed: busy ? null : () => act('review'),
                    child: const Text('已阅，无需联系'),
                  ),
                if (widget.work &&
                    [
                      'pending_review',
                      'pending_contact',
                      'following',
                    ].contains(status)) ...[
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
}

class _ChoiceQuestion extends StatelessWidget {
  const _ChoiceQuestion(
    this.title,
    this.description,
    this.options,
    this.value,
    this.onChanged, {
    this.required = false,
  });
  final String title, description, value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  final bool required;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title${required ? ' *' : ''}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(
              description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 10),
        for (final option in options.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              selected: value == option.key,
              button: true,
              child: Material(
                color: value == option.key
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onChanged(option.key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 15,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          value == option.key
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 21,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(option.value)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Answer extends StatelessWidget {
  const _Answer(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 23),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 7),
        SelectableText(value),
      ],
    ),
  );
}
