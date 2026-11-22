import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import 'widgets.dart';
import 'appointments.dart';
import 'followups.dart';
import 'help.dart';
import 'slots.dart';
import 'transfers.dart';

class WorkPage extends StatefulWidget {
  const WorkPage(this.api, this.user, {super.key});
  final HarborApi api;
  final Data user;
  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  List<Data> appointments = [], followups = [], requests = [], transfers = [];
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
      final result = await Future.wait([
        widget.api.list('/appointments?scope=work'),
        widget.api.list('/followups?scope=work'),
        ((widget.user['roles'] as List? ?? []).contains('teacher'))
            ? widget.api.list('/help-requests?scope=work')
            : Future.value(<Data>[]),
        widget.api.list('/transfers'),
      ]);
      if (mounted)
        setState(() {
          appointments = result[0];
          followups = result[1];
          requests = result[2];
          transfers = result[3];
        });
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> enter(Data item) async {
    final Widget page = switch (item['_kind']) {
      'appointment' => AppointmentDetail(widget.api, item['id'], work: true),
      'followup' => FollowupDetail(widget.api, item['id'], work: true),
      'help' => HelpDetail(widget.api, item['id'], work: true),
      _ => CareTransferDetail(widget.api, item, widget.user),
    };
    await open(context, page);
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) {
    final roles = widget.user['roles'] as List? ?? [];
    final role = text(
      widget.user,
      'space',
      roles.contains('teacher') ? 'teacher' : 'peer',
    );
    final today = careDay(DateTime.now());
    final todayAppointments = appointments.where((row) {
      final start = DateTime.tryParse(text(row, 'start_at'))?.toLocal();
      return start != null &&
          careDay(start) == today &&
          ['pending', 'confirmed', 'in_progress'].contains(row['status']);
    }).toList();
    final tasks = <Data>[
      for (final item in appointments.where(
        (row) => row['status'] == 'pending',
      ))
        {...item, '_kind': 'appointment', '_label': '预约待确认'},
      for (final item in followups.where(
        (row) => [
          'pending_review',
          'pending_contact',
          'following',
        ].contains(row['status']),
      ))
        {...item, '_kind': 'followup', '_label': '回访与跟进'},
      for (final item in requests.where((row) => row['status'] != 'closed'))
        {...item, '_kind': 'help', '_label': '人工联系'},
      for (final item in transfers.where((row) => row['status'] == 'pending'))
        {
          ...item,
          '_kind': 'transfer',
          '_label': item['to_id'] == widget.user['id'] ? '待接收转交' : '转交进度',
        },
    ];
    final visible = tasks
        .where((item) => filter == 'all' || item['_kind'] == filter)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作台'),
        actions: [
          IconButton(
            tooltip: '管理排班',
            onPressed: () async {
              await open(context, SlotEditor(widget.api));
              if (mounted) load();
            },
            icon: const Icon(Icons.edit_calendar_outlined),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? LoadError(error!, load)
          : HarborList(
              refresh: load,
              children: [
                Text(
                  '${roleName(role)} · ${text(widget.user, 'nickname')}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '今天，也从倾听开始。',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  DateFormat('M月d日 EEEE', 'zh_CN').format(DateTime.now()),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _WorkMetric(
                        '今日安排',
                        '${todayAppointments.length}',
                        Icons.event_outlined,
                        () => open(
                          context,
                          AppointmentsPage(widget.api, work: true),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _WorkMetric(
                        '待处理事项',
                        '${tasks.length}',
                        Icons.checklist_outlined,
                        () => setState(() => filter = 'all'),
                      ),
                    ),
                  ],
                ),
                CareSection(
                  '需要你留意',
                  trailing: Text(
                    '${tasks.length} 项',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final item in const {
                        'all': '全部',
                        'appointment': '预约',
                        'followup': '回访',
                        'help': '联系',
                        'transfer': '转交',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(item.value),
                            selected: filter == item.key,
                            onSelected: (_) =>
                                setState(() => filter = item.key),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (visible.isEmpty)
                  const Empty(
                    '当前没有待处理事项',
                    body: '新预约、回访与联系请求会显示在这里。',
                    icon: Icons.task_alt_outlined,
                  ),
                for (final item in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => enter(item),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              PersonIcon(
                                text(item, 'student_name'),
                                radius: 21,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      text(item, 'student_name', '服务事项'),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      text(item, '_label'),
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      item['start_at'] == null
                                          ? stamp(
                                              item['created_at'],
                                              date: true,
                                            )
                                          : stamp(item['start_at'], date: true),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelMedium,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (todayAppointments.isNotEmpty) ...[
                  const CareSection('今天的安排'),
                  for (final item in todayAppointments)
                    CareAppointmentTile(
                      item,
                      work: true,
                      onTap: () => enter({...item, '_kind': 'appointment'}),
                    ),
                ],
                const CareSection('常用入口'),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        await open(
                          context,
                          FollowupsPage(widget.api, work: true),
                        );
                        if (mounted) load();
                      },
                      icon: const Icon(Icons.assignment_outlined, size: 18),
                      label: const Text('回访记录'),
                    ),
                    if (role == 'teacher')
                      OutlinedButton.icon(
                        onPressed: () async {
                          await open(context, HelpPage(widget.api, work: true));
                          if (mounted) load();
                        },
                        icon: const Icon(
                          Icons.support_agent_outlined,
                          size: 18,
                        ),
                        label: Text(role == 'teacher' ? '联系请求' : '转交与求助'),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _WorkMetric extends StatelessWidget {
  const _WorkMetric(this.label, this.value, this.icon, this.onTap);
  final String label, value;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
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
                    label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Icon(
                  icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
          ],
        ),
      ),
    ),
  );
}
