import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import '../messages.dart';
import 'widgets.dart';
import 'support.dart';
import 'followups.dart';
import 'slots.dart';
import 'transfers.dart';

class AppointmentsPage extends StatefulWidget {
  const AppointmentsPage(this.api, {super.key, this.work = false});
  final HarborApi api;
  final bool work;
  @override
  State<AppointmentsPage> createState() => _AppointmentsPageState();
}

class _AppointmentsPageState extends State<AppointmentsPage> {
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
        '/appointments${widget.work ? '?scope=work' : ''}',
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
              (filter == 'active'
                  ? [
                      'pending',
                      'confirmed',
                      'in_progress',
                    ].contains(row['status'])
                  : row['status'] == filter),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.work ? '预约与排班' : '我的预约'),
        actions: [
          if (widget.work)
            TextButton(
              onPressed: () async {
                await open(context, SlotEditor(widget.api));
                if (mounted) load();
              },
              child: const Text('排班'),
            ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                for (final choice in const {
                  'all': '全部',
                  'active': '待完成',
                  'pending': '待确认',
                  'completed': '已完成',
                }.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(choice.value),
                      selected: filter == choice.key,
                      onSelected: (_) => setState(() => filter = choice.key),
                    ),
                  ),
              ],
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
                          '这里还没有预约',
                          body: widget.work
                              ? '同学提交申请后，会在这里等待你确认。'
                              : '需要的时候，选择一位校内人员聊聊。',
                          icon: Icons.event_note_outlined,
                          action: widget.work
                              ? OutlinedButton(
                                  onPressed: () =>
                                      open(context, SlotEditor(widget.api)),
                                  child: const Text('设置可约时间'),
                                )
                              : OutlinedButton(
                                  onPressed: () =>
                                      open(context, SupportPage(widget.api)),
                                  child: const Text('找人聊聊'),
                                ),
                        ),
                      for (final row in visible)
                        CareAppointmentTile(
                          row,
                          work: widget.work,
                          onTap: () async {
                            await open(
                              context,
                              AppointmentDetail(
                                widget.api,
                                row['id'],
                                work: widget.work,
                              ),
                            );
                            if (mounted) load();
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class CareAppointmentTile extends StatelessWidget {
  const CareAppointmentTile(
    this.row, {
    super.key,
    required this.work,
    required this.onTap,
  });
  final Data row;
  final bool work;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      careDateLabel(row['start_at']),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  CareStatus(row['status']),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${stamp(row['start_at'])}–${stamp(row['end_at'])}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  PersonIcon(
                    text(row, work ? 'student_name' : 'staff_name'),
                    radius: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text(row, work ? 'student_name' : 'staff_name'),
                    ),
                  ),
                  Text(
                    modeName(row['mode']),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right, size: 19),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class AppointmentDetail extends StatefulWidget {
  const AppointmentDetail(this.api, this.id, {super.key, this.work = false});
  final HarborApi api;
  final String id;
  final bool work;
  @override
  State<AppointmentDetail> createState() => _AppointmentDetailState();
}

class _AppointmentDetailState extends State<AppointmentDetail> {
  Data? row;
  Data? service;
  Object? error;
  Object? actionError;
  bool loading = true;
  bool busy = false;
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
      final result = await widget.api.request('/appointments/${widget.id}');
      Data? detail;
      if (text(result, 'service_id').isNotEmpty)
        detail = await widget.api.request('/services/${result['service_id']}');
      if (mounted)
        setState(() {
          row = result;
          service = detail;
        });
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> act(String action, [Data body = const {}]) async {
    if (busy) return;
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      await widget.api.post('/appointments/${widget.id}/$action', body);
      if (!mounted) return;
      flash(context, '预约进度已更新');
      await load();
    } catch (caught) {
      if (mounted) setState(() => actionError = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> explain(String action, String title) async {
    final reason = await askText(context, title, '原因', required: widget.work);
    if (reason != null && mounted) await act(action, {'reason': reason});
  }

  Future<void> complete() async {
    final result = await showDialog<Data>(
      context: context,
      builder: (_) => const _ServiceNoteDialog(),
    );
    if (result != null && mounted) await act('complete', result);
  }

  Future<void> cancel() async {
    if (widget.work) {
      await explain('cancel', '取消预约');
      return;
    }
    final confirmed = await confirmAction(
      context,
      '取消这次预约？',
      '取消后原时段会释放。需要改期时，可以重新选择时间。',
      confirm: '取消预约',
    );
    if (confirmed && mounted) await act('cancel');
  }

  @override
  Widget build(BuildContext context) {
    final status = row?['status'];
    final start = DateTime.tryParse(text(row ?? {}, 'start_at'));
    final canCancel =
        ['pending', 'confirmed'].contains(status) &&
        (start?.isAfter(DateTime.now()) ?? false);
    final canNoShow =
        widget.work &&
        status == 'confirmed' &&
        start != null &&
        DateTime.now().isAfter(start.add(const Duration(minutes: 10)));
    return Scaffold(
      appBar: AppBar(title: const Text('预约详情')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? LoadError(error!, load)
          : HarborList(
              refresh: load,
              children: [
                CareActionError(actionError),
                Row(
                  children: [
                    CareStatus(status),
                    const Spacer(),
                    Text(
                      '免费校内支持',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  careDateLabel(row!['start_at']),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 5),
                Text(
                  '${stamp(row!['start_at'])}–${stamp(row!['end_at'])}',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 24),
                Surface(
                  child: Column(
                    children: [
                      CareInfoLine(
                        Icons.person_outline,
                        widget.work ? '预约同学' : '接待人员',
                        text(row!, widget.work ? 'student_name' : 'staff_name'),
                      ),
                      CareInfoLine(
                        Icons.school_outlined,
                        '人员身份',
                        roleName(row!['role']),
                      ),
                      CareInfoLine(
                        Icons.forum_outlined,
                        '服务方式',
                        modeName(row!['mode']),
                      ),
                      if (row!['mode'] == 'onsite')
                        CareInfoLine(
                          Icons.place_outlined,
                          '接待地点',
                          text(row!, 'location'),
                        ),
                    ],
                  ),
                ),
                if (text(row!, 'note').isNotEmpty) ...[
                  const CareSection('预约时想说的话'),
                  Text(text(row!, 'note')),
                ],
                if (text(row!, 'reason').isNotEmpty) ...[
                  const CareSection('处理说明'),
                  Text(text(row!, 'reason')),
                ],
                if (text(service ?? {}, 'student_note').isNotEmpty) ...[
                  const CareSection('下一步安排'),
                  Text(text(service!, 'student_note')),
                ],
                if (widget.work &&
                    text(service ?? {}, 'internal_note').isNotEmpty) ...[
                  const CareSection('内部服务记录'),
                  Text(text(service!, 'internal_note')),
                ],
                if (text(row!, 'conversation_id').isNotEmpty) ...[
                  const CareSection('本次交流'),
                  OutlinedButton.icon(
                    onPressed: () => open(
                      context,
                      ChatPage(widget.api, row!['conversation_id']),
                    ),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('打开服务会话'),
                  ),
                ],
                if (widget.work && objects(service?['shares']).isNotEmpty) ...[
                  const CareSection('同学分享的内容'),
                  for (final share in objects(service?['shares']))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Surface(
                        child: SelectableText(text(share, 'body')),
                      ),
                    ),
                ],
                if (status == 'completed') ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => open(
                      context,
                      FollowupsPage(widget.api, work: widget.work),
                    ),
                    icon: const Icon(Icons.assignment_outlined),
                    label: const Text('查看咨询回访'),
                  ),
                ],
                if (widget.work &&
                    text(row!, 'service_id').isNotEmpty &&
                    ['confirmed', 'in_progress'].contains(status)) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () async {
                      await open(
                        context,
                        CareTransferCreate(widget.api, row!['service_id']),
                      );
                      if (mounted) load();
                    },
                    icon: const Icon(Icons.switch_account_outlined),
                    label: const Text('转交给心理老师'),
                  ),
                ],
                CareHistory(objects(row!['history'])),
              ],
            ),
      bottomNavigationBar: row == null || loading
          ? null
          : CareBottomActions(
              children: [
                if (canCancel)
                  OutlinedButton(
                    onPressed: busy ? null : cancel,
                    child: const Text('取消预约'),
                  ),
                if (widget.work && status == 'pending') ...[
                  OutlinedButton(
                    onPressed: busy ? null : () => explain('reject', '拒绝预约申请'),
                    child: const Text('拒绝申请'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : () => act('confirm'),
                    child: Text(busy ? '处理中…' : '确认预约'),
                  ),
                ],
                if (widget.work && status == 'confirmed')
                  FilledButton(
                    onPressed: busy ? null : () => act('start'),
                    child: const Text('开始服务'),
                  ),
                if (canNoShow)
                  TextButton(
                    onPressed: busy ? null : () => explain('no-show', '记录未到场'),
                    child: const Text('标记未到场'),
                  ),
                if (widget.work && status == 'in_progress')
                  FilledButton(
                    onPressed: busy ? null : complete,
                    child: const Text('结束服务'),
                  ),
                if (!widget.work &&
                    [
                      'canceled',
                      'rejected',
                      'expired',
                      'no_show',
                    ].contains(status))
                  FilledButton(
                    onPressed: () => open(context, SupportPage(widget.api)),
                    child: const Text('重新预约'),
                  ),
              ],
            ),
    );
  }
}

class _ServiceNoteDialog extends StatefulWidget {
  const _ServiceNoteDialog();
  @override
  State<_ServiceNoteDialog> createState() => _ServiceNoteDialogState();
}

class _ServiceNoteDialogState extends State<_ServiceNoteDialog> {
  final internal = TextEditingController();
  final student = TextEditingController();
  @override
  void dispose() {
    internal.dispose();
    student.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('结束本次服务'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: internal,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '内部服务记录',
              helperText: '仅授权工作人员可见',
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: student,
            minLines: 2,
            maxLines: 4,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: '给同学的下一步安排（选填）'),
          ),
          const SizedBox(height: 12),
          const Text('完成后，系统会为同学创建关联回访。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('再等等'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'internal_note': internal.text.trim(),
          'student_note': student.text.trim(),
        }),
        child: const Text('确认完成'),
      ),
    ],
  );
}
