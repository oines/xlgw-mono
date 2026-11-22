import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import '../messages.dart';
import 'widgets.dart';

class CareTransferCreate extends StatefulWidget {
  const CareTransferCreate(this.api, this.serviceId, {super.key});
  final HarborApi api;
  final String serviceId;
  @override
  State<CareTransferCreate> createState() => CareTransferCreateState();
}

class CareTransferCreateState extends State<CareTransferCreate> {
  List<Data> teachers = [];
  String? selected;
  final note = TextEditingController();
  final form = GlobalKey<FormState>();
  bool loading = true, busy = false;
  Object? error;
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
      final result = await Future.wait([
        widget.api.list('/staff?role=teacher'),
        widget.api.request('/staff/me'),
      ]);
      if (!mounted) return;
      final people = result[0] as List<Data>;
      final me = result[1] as Data;
      setState(() {
        teachers = people.where((person) => person['id'] != me['id']).toList();
        final supervisor = text(me, 'supervisor_id');
        if (teachers.any((person) => person['id'] == supervisor))
          selected = supervisor;
      });
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.post('/transfers', {
        'service_id': widget.serviceId,
        'staff_id': selected,
        'note': note.text.trim(),
      });
      if (!mounted) return;
      flash(context, '转交申请已发送，等待老师确认');
      Navigator.pop(context, true);
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('转交给心理老师')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Form(
            key: form,
            child: HarborList(
              children: [
                CareActionError(error),
                Text(
                  '把需要进一步支持的事情交接清楚。',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const Text('接收老师确认后，服务负责人会更新。学生此前分享的 AI 内容需要向新老师重新授权。'),
                const SizedBox(height: 24),
                if (teachers.isEmpty)
                  Empty(
                    '当前没有可接收的老师',
                    body: '请联系学校管理人员确认人员安排。',
                    action: OutlinedButton(
                      onPressed: load,
                      child: const Text('重新加载'),
                    ),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '接收老师'),
                    items: teachers
                        .map(
                          (person) => DropdownMenuItem<String>(
                            value: person['id'],
                            child: Text(text(person, 'nickname')),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => selected = value),
                    validator: (value) => value == null ? '请选择接收老师' : null,
                  ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: note,
                  minLines: 5,
                  maxLines: 10,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '交接说明'),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请说明需要转交的事项' : null,
                ),
              ],
            ),
          ),
    bottomNavigationBar: CareBottomActions(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: busy || teachers.isEmpty ? null : submit,
            child: Text(busy ? '正在发送…' : '发送转交申请'),
          ),
        ),
      ],
    ),
  );
}

class CareTransferDetail extends StatefulWidget {
  const CareTransferDetail(this.api, this.initial, this.user, {super.key});
  final HarborApi api;
  final Data initial, user;
  @override
  State<CareTransferDetail> createState() => CareTransferDetailState();
}

class CareTransferDetailState extends State<CareTransferDetail> {
  late Data row = widget.initial;
  bool busy = false;
  Object? error;
  Future<void> act(String action) async {
    String? note;
    if (action == 'reject') {
      note = await askText(context, '拒绝这次转交', '说明原因');
      if (note == null || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.post('/transfers/${row['id']}/$action', {
        'note': note ?? '',
      });
      if (!mounted) return;
      setState(() => row = result);
      flash(context, action == 'accept' ? '已接收这项服务' : '已拒绝转交');
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('服务转交')),
    body: HarborList(
      children: [
        CareActionError(error),
        CareStatus(row['status']),
        const SizedBox(height: 24),
        Text(
          text(row, 'student_name'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 20),
        CareInfoLine(Icons.person_outline, '转出人员', text(row, 'from_name')),
        CareInfoLine(Icons.person_outline, '接收老师', text(row, 'to_name')),
        CareInfoLine(
          Icons.schedule_outlined,
          '提交时间',
          stamp(row['created_at'], date: true),
        ),
        const CareSection('交接说明'),
        Text(text(row, 'note')),
        if (row['status'] == 'accepted' &&
            row['to_id'] == widget.user['id']) ...[
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              try {
                final service = await widget.api.request(
                  '/services/${row['service_id']}',
                );
                if (!context.mounted) return;
                if (text(service, 'conversation_id').isNotEmpty)
                  await open(
                    context,
                    ChatPage(widget.api, service['conversation_id']),
                  );
              } catch (caught) {
                if (context.mounted) flash(context, caught);
              }
            },
            child: const Text('进入服务会话'),
          ),
        ],
      ],
    ),
    bottomNavigationBar:
        row['status'] == 'pending' && row['to_id'] == widget.user['id']
        ? CareBottomActions(
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => act('reject'),
                child: const Text('拒绝转交'),
              ),
              FilledButton(
                onPressed: busy ? null : () => act('accept'),
                child: const Text('接收服务'),
              ),
            ],
          )
        : null,
  );
}
