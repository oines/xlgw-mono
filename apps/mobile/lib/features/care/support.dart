import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../shared/api.dart';
import '../../shared/design.dart';
import 'widgets.dart';
import 'appointments.dart';
import 'help.dart';

class SupportPage extends StatefulWidget {
  const SupportPage(this.api, {super.key});
  final HarborApi api;
  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  List<Data> people = [];
  Data school = {};
  String role = 'teacher';
  String mode = '';
  DateTime? date;
  bool loading = true;
  Object? error;
  int requestVersion = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final version = ++requestVersion;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await Future.wait([
        widget.api.request(
          '/staff?role=$role${mode.isEmpty ? '' : '&mode=$mode'}${date == null ? '' : '&date=${careDay(date!)}'}',
        ),
        widget.api.request('/school'),
      ]);
      if (!mounted || version != requestVersion) return;
      setState(() {
        people = objects(result[0]['items']);
        school = result[1];
      });
    } catch (caught) {
      if (mounted && version == requestVersion) setState(() => error = caught);
    } finally {
      if (mounted && version == requestVersion) setState(() => loading = false);
    }
  }

  Future<void> chooseDate() async {
    final now = DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      initialDate: date ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 14)),
      helpText: '希望哪一天聊聊',
    );
    if (chosen != null && mounted) {
      setState(() => date = chosen);
      await load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('找人聊聊'),
        actions: [
          IconButton(
            tooltip: '我的预约',
            icon: const Icon(Icons.event_note_outlined),
            onPressed: () => open(context, AppointmentsPage(widget.api)),
          ),
        ],
      ),
      body: HarborList(
        refresh: load,
        children: [
          Text(
            '在校园里，找一个愿意倾听的人。',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            '选择心理老师或朋辈同学，了解接待方式，再约一个合适的时间。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'teacher', label: Text('心理老师')),
              ButtonSegment(value: 'peer', label: Text('朋辈同学')),
            ],
            selected: {role},
            onSelectionChanged: (value) {
              setState(() => role = value.first);
              load();
            },
          ),
          if (role == 'peer')
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '经学校认可的同伴支持成员，陪你倾听与交流。需要老师帮助时，可以转交指导老师。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilterChip(
                label: Text(
                  date == null ? '选择日期' : DateFormat('M月d日').format(date!),
                ),
                selected: date != null,
                onSelected: (_) => chooseDate(),
                avatar: const Icon(Icons.calendar_today_outlined, size: 16),
              ),
              FilterChip(
                label: const Text('线上文字'),
                selected: mode == 'online',
                onSelected: (selected) {
                  setState(() => mode = selected ? 'online' : '');
                  load();
                },
              ),
              FilterChip(
                label: const Text('线下见面'),
                selected: mode == 'onsite',
                onSelected: (selected) {
                  setState(() => mode = selected ? 'onsite' : '');
                  load();
                },
              ),
              if (mode.isNotEmpty || date != null)
                TextButton(
                  onPressed: () {
                    setState(() {
                      mode = '';
                      date = null;
                    });
                    load();
                  },
                  child: const Text('重置'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            LoadError(error!, load)
          else if (people.isEmpty)
            const Empty(
              '暂时没有符合条件的人员',
              body: '可以换一个日期或接待方式，再看看校内支持。',
              icon: Icons.people_outline,
            )
          else
            for (final person in people)
              _StaffTile(person, () async {
                await open(context, StaffDetail(widget.api, person['id']));
                if (mounted) load();
              }),
          const CareSection('希望有人联系你'),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '也可以先留下一份联系请求',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  text(school, 'service_hours').isEmpty
                      ? '提交后可在请求详情查看实际处理进度。'
                      : '校内服务时间：${text(school, 'service_hours')}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => open(context, HelpPage(widget.api)),
                  icon: const Icon(Icons.support_agent_outlined),
                  label: const Text('希望有人联系我'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile(this.person, this.onTap);
  final Data person;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 1),
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PersonIcon(
                text(person, 'nickname'),
                url: text(person, 'avatar_url'),
                radius: 28,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          text(person, 'nickname'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          roleName(person['role']),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      text(person, 'bio', '校内倾听与支持'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.schedule_outlined,
                          size: 15,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            person['next_slot'] == null
                                ? '近期暂无可约时间'
                                : '最近可约 ${stamp(person['next_slot'], date: true)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Icon(Icons.chevron_right, size: 20),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class StaffDetail extends StatefulWidget {
  const StaffDetail(this.api, this.id, {super.key, this.slotId});
  final HarborApi api;
  final String id;
  final String? slotId;
  @override
  State<StaffDetail> createState() => _StaffDetailState();
}

class _StaffDetailState extends State<StaffDetail> {
  Data? person;
  List<Data> slots = [];
  Data? selected;
  DateTime day = DateTime.now();
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
      final result = await Future.wait([
        widget.api.request('/staff/${widget.id}'),
        widget.api.request('/slots?staff_id=${widget.id}'),
      ]);
      if (!mounted) return;
      final available = objects(
        result[1]['items'],
      ).where((slot) => slot['available'] == true).toList();
      setState(() {
        person = result[0];
        slots = available;
        selected = null;
        for (final slot in available) {
          if (slot['id'] == widget.slotId) {
            selected = slot;
            break;
          }
        }
        if (available.isNotEmpty)
          day = DateTime.parse(
            (selected ?? available.first)['start_at'],
          ).toLocal();
      });
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dates = List.generate(
      14,
      (index) => DateTime(now.year, now.month, now.day + index),
    );
    final available = slots
        .where(
          (slot) =>
              careDay(DateTime.parse(slot['start_at']).toLocal()) ==
              careDay(day),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('了解接待人员')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? LoadError(error!, load)
          : HarborList(
              refresh: load,
              children: [
                Row(
                  children: [
                    PersonIcon(
                      text(person!, 'nickname'),
                      url: text(person!, 'avatar_url'),
                      radius: 35,
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            text(person!, 'nickname'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            roleName(person!['role']),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const CareSection('可以怎样陪伴你'),
                Text(text(person!, 'bio', '尚未填写接待介绍')),
                const SizedBox(height: 14),
                CareInfoLine(
                  Icons.forum_outlined,
                  '接待方式',
                  (person!['modes'] as List? ?? []).map(modeName).join('、'),
                ),
                if (text(person!, 'location').isNotEmpty)
                  CareInfoLine(
                    Icons.place_outlined,
                    '线下地点',
                    text(person!, 'location'),
                  ),
                if (text(person!, 'supervisor_name').isNotEmpty)
                  CareInfoLine(
                    Icons.person_outline,
                    '指导老师',
                    text(person!, 'supervisor_name'),
                  ),
                const CareSection('选择一个时间'),
                SizedBox(
                  height:
                      88 *
                      MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.4),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: dates.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, index) {
                      final date = dates[index];
                      final active = careDay(date) == careDay(day);
                      return Material(
                        color: active
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() {
                            day = date;
                            selected = null;
                          }),
                          child: SizedBox(
                            width: 58,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  index == 0
                                      ? '今天'
                                      : DateFormat('E', 'zh_CN').format(date),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '${date.day}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                if (available.isEmpty)
                  const Empty(
                    '这一天暂无可约时段',
                    body: '试试其他日期，或查看其他接待人员。',
                    icon: Icons.event_busy_outlined,
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final count =
                          MediaQuery.textScalerOf(context).scale(1) > 1.3
                          ? 2
                          : 3;
                      final width =
                          (constraints.maxWidth - 8 * (count - 1)) / count;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final slot in available)
                            SizedBox(
                              width: width,
                              child: ChoiceChip(
                                label: Column(
                                  children: [
                                    Text(stamp(slot['start_at'])),
                                    Text(
                                      modeName(slot['mode']),
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ],
                                ),
                                selected: selected?['id'] == slot['id'],
                                onSelected: (_) =>
                                    setState(() => selected = slot),
                                showCheckmark: false,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
              ],
            ),
      bottomNavigationBar: person == null
          ? null
          : CareBottomActions(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    selected == null
                        ? '请选择时间'
                        : '${careDateLabel(selected!['start_at'])} ${stamp(selected!['start_at'])} · ${modeName(selected!['mode'])}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: selected == null
                        ? null
                        : () async {
                            await open(
                              context,
                              _BookingConfirm(widget.api, person!, selected!),
                            );
                            if (mounted) load();
                          },
                    child: const Text('预约这次交流'),
                  ),
                ),
              ],
            ),
    );
  }
}

class _BookingConfirm extends StatefulWidget {
  const _BookingConfirm(this.api, this.person, this.slot);
  final HarborApi api;
  final Data person, slot;
  @override
  State<_BookingConfirm> createState() => _BookingConfirmState();
}

class _BookingConfirmState extends State<_BookingConfirm> {
  final note = TextEditingController();
  final requestId = newID();
  bool busy = false;
  Object? error;
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.post('/appointments', {
        'id': requestId,
        'slot_id': widget.slot['id'],
        'note': note.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AppointmentDetail(widget.api, result['id']),
        ),
      );
    } catch (caught) {
      if (mounted) setState(() => error = caught);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('确认预约')),
    body: HarborList(
      children: [
        CareActionError(error),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text(widget.person, 'nickname'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              CareInfoLine(
                Icons.calendar_today_outlined,
                '日期',
                careDateLabel(widget.slot['start_at']),
              ),
              CareInfoLine(
                Icons.schedule_outlined,
                '时间',
                '${stamp(widget.slot['start_at'])}–${stamp(widget.slot['end_at'])}',
              ),
              CareInfoLine(
                Icons.forum_outlined,
                '方式',
                modeName(widget.slot['mode']),
              ),
              if (widget.slot['mode'] == 'onsite')
                CareInfoLine(
                  Icons.place_outlined,
                  '地点',
                  text(widget.person, 'location'),
                ),
            ],
          ),
        ),
        const CareSection('想提前说些什么'),
        TextField(
          controller: note,
          maxLength: 500,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '可以简单说说想聊的话题，也可以见面再聊。'),
        ),
        const SizedBox(height: 14),
        Text(
          '预约提交后，接待人员会确认这次安排。你的 AI 聊天记录由你自己决定是否分享。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
    bottomNavigationBar: CareBottomActions(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? '正在提交…' : '提交预约'),
          ),
        ),
      ],
    ),
  );
}
