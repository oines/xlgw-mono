import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import 'widgets.dart';
import 'appointments.dart';

class SlotEditor extends StatefulWidget {
  const SlotEditor(this.api, {super.key});
  final HarborApi api;
  @override
  State<SlotEditor> createState() => _SlotEditorState();
}

class _SlotEditorState extends State<SlotEditor> {
  Data school = {}, person = {};
  List<Data> slots = [];
  DateTime date = DateTime.now().add(const Duration(days: 1));
  TimeOfDay time = const TimeOfDay(hour: 9, minute: 0);
  String mode = 'online';
  int count = 1;
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
      final result = await Future.wait([
        widget.api.request('/school'),
        widget.api.request('/staff/me'),
        widget.api.request('/slots?scope=work'),
      ]);
      if (!mounted) return;
      setState(() {
        school = result[0];
        person = result[1];
        slots = objects(result[2]['items']);
        final modes = person['modes'] as List? ?? [];
        if (modes.isNotEmpty && !modes.contains(mode))
          mode = modes.first.toString();
      });
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  int get minutes =>
      ((person['role'] == 'peer'
                  ? school['peer_minutes']
                  : school['teacher_minutes'])
              as num?)
          ?.toInt() ??
      (person['role'] == 'peer' ? 30 : 50);
  int get gap => (school['slot_gap_minutes'] as num?)?.toInt() ?? 10;
  DateTime get start =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);
  Future<void> publish() async {
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      final items = List.generate(count, (index) {
        final begin = start.add(Duration(minutes: index * (minutes + gap)));
        return {
          'start_at': begin.toUtc().toIso8601String(),
          'end_at': begin
              .add(Duration(minutes: minutes))
              .toUtc()
              .toIso8601String(),
          'mode': mode,
        };
      });
      await widget.api.post('/slots', {'items': items});
      if (!mounted) return;
      flash(context, '可约时间已发布');
      await load();
    } catch (caught) {
      if (mounted) setState(() => actionError = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(Data slot) async {
    if (!await confirmAction(
          context,
          '撤下这个时段？',
          '${stamp(slot['start_at'], date: true)} 撤下后，同学将无法再预约该时间。',
          confirm: '撤下时段',
        ) ||
        !mounted)
      return;
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      await widget.api.delete('/slots/${slot['id']}');
      if (!mounted) return;
      flash(context, '时段已撤下');
      await load();
    } catch (caught) {
      if (mounted) setState(() => actionError = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置可约时间')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? LoadError(error!, load)
        : HarborList(
            refresh: load,
            children: [
              CareActionError(actionError),
              Text(
                '给下一次交流留出时间',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Text(
                '每次 $minutes 分钟，相邻时段间隔 $gap 分钟。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Surface(
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.calendar_today_outlined),
                      title: const Text('接待日期'),
                      subtitle: Text(
                        DateFormat('M月d日 EEEE', 'zh_CN').format(date),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final now = DateTime.now();
                        final chosen = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: now.add(const Duration(days: 14)),
                        );
                        if (chosen != null && mounted)
                          setState(() => date = chosen);
                      },
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule_outlined),
                      title: const Text('开始时间'),
                      subtitle: Text(time.format(context)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final chosen = await showTimePicker(
                          context: context,
                          initialTime: time,
                        );
                        if (chosen != null && mounted)
                          setState(() => time = chosen);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: '接待方式'),
                items: (person['modes'] as List? ?? ['online'])
                    .map(
                      (value) => DropdownMenuItem(
                        value: value.toString(),
                        child: Text(modeName(value)),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => mode = value);
                },
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<int>(
                initialValue: count,
                decoration: const InputDecoration(labelText: '连续发布几个时段'),
                items: [
                  for (final value in [1, 2, 3, 4])
                    DropdownMenuItem(value: value, child: Text('$value 个时段')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => count = value);
                },
              ),
              const SizedBox(height: 16),
              Text(
                '将发布 ${DateFormat('HH:mm').format(start)}–${DateFormat('HH:mm').format(start.add(Duration(minutes: count * minutes + (count - 1) * gap)))} 的 $count 个时段。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: busy ? null : publish,
                icon: const Icon(Icons.add),
                label: Text(busy ? '正在处理…' : '发布可约时间'),
              ),
              const CareSection('已经发布的时段'),
              if (slots.isEmpty)
                const Empty(
                  '还没有可约时间',
                  body: '发布后，同学可以在校内支持里预约你。',
                  icon: Icons.calendar_month_outlined,
                ),
              for (final slot in slots)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      title: Text(stamp(slot['start_at'], date: true)),
                      subtitle: Text(
                        '${modeName(slot['mode'])} · ${slot['available'] == true ? '可预约' : '已被预约'}',
                      ),
                      trailing: slot['available'] == true
                          ? IconButton(
                              tooltip: '撤下时段',
                              onPressed: busy ? null : () => remove(slot),
                              icon: const Icon(Icons.delete_outline),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: text(slot, 'appointment_id').isEmpty
                          ? null
                          : () async {
                              await open(
                                context,
                                AppointmentDetail(
                                  widget.api,
                                  slot['appointment_id'],
                                  work: true,
                                ),
                              );
                              if (mounted) load();
                            },
                    ),
                  ),
                ),
            ],
          ),
  );
}
