import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';

String careDay(DateTime value) => DateFormat('yyyy-MM-dd').format(value);
String careDateLabel(Object? value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  return date == null ? '时间待确认' : DateFormat('M月d日 EEEE', 'zh_CN').format(date);
}

class CareStatus extends StatelessWidget {
  const CareStatus(this.value, {super.key, this.label});
  final Object? value;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final completed = [
      'completed',
      'closed',
      'canceled',
      'rejected',
      'expired',
      'no_show',
    ].contains(value);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: completed ? colors.surfaceContainer : colors.primaryContainer,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label ?? stateName(value),
        style: TextStyle(
          fontSize: 12,
          color: completed ? colors.onSurfaceVariant : colors.primary,
        ),
      ),
    );
  }
}

class CareSection extends StatelessWidget {
  const CareSection(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class CareInfoLine extends StatelessWidget {
  const CareInfoLine(this.icon, this.label, this.value, {super.key});
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 19,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value.isEmpty ? '尚未填写' : value)),
      ],
    ),
  );
}

class CareActionError extends StatelessWidget {
  const CareActionError(this.error, {super.key});
  final Object? error;
  @override
  Widget build(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            error.toString(),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
}

class CareBottomActions extends StatelessWidget {
  const CareBottomActions({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => children.isEmpty
      ? const SizedBox.shrink()
      : Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                runSpacing: 8,
                spacing: 8,
                children: children,
              ),
            ),
          ),
        );
}

class CareHistory extends StatelessWidget {
  const CareHistory(this.rows, {super.key});
  final List<Data> rows;
  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    const actions = {
      'create': '提交申请',
      'confirm': '确认预约',
      'start': '开始服务',
      'complete': '完成服务',
      'cancel': '取消预约',
      'reject': '拒绝申请',
      'submit': '提交回访',
      'review': '已查看',
      'contact': '记录联系',
      'close': '结束跟进',
      'assign': '分配人员',
      'claim': '接收请求',
      'accept': '接收转交',
      'resend': '补发通知',
      'reassign': '重新分配',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CareSection('处理记录'),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Icon(
                    Icons.circle,
                    size: 7,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${text(row, 'actor_name')} ${actions[text(row, 'action')] ?? text(row, 'action')}'
                            .trim(),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (text(row, 'note').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(text(row, 'note')),
                        ),
                      if (text(row, 'student_note').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(text(row, 'student_note')),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          stamp(row['created_at'], date: true),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class CareContactDialog extends StatefulWidget {
  const CareContactDialog(this.title, {super.key, this.required = true});
  final String title;
  final bool required;
  @override
  State<CareContactDialog> createState() => CareContactDialogState();
}

class CareContactDialogState extends State<CareContactDialog> {
  final note = TextEditingController();
  final studentNote = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    note.dispose();
    studentNote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: note,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '处理记录'),
              validator: (value) =>
                  widget.required && (value ?? '').trim().isEmpty
                  ? '请记录联系情况'
                  : null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: studentNote,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: const InputDecoration(labelText: '发给同学的安排（选填）'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate())
            Navigator.pop(context, {
              'note': note.text.trim(),
              'student_note': studentNote.text.trim(),
            });
        },
        child: const Text('保存记录'),
      ),
    ],
  );
}
