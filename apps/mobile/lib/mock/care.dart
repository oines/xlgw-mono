import '../shared/api.dart';
import 'ai.dart';
import 'social.dart';

class MockCare {
  static const demo = 'demo-user';
  static const student = 'demo-student';
  static const teacher = 'demo-teacher';
  static const peer = 'demo-peer';

  static List<Data> _rows(Data state, String kind) =>
      (state.putIfAbsent('care_$kind', () => <Data>[]) as List).cast<Data>();

  static Iterable<Data> _items(Data state, String kind) => _rows(state, kind);

  static Data? _find(Data state, String kind, String id) =>
      _items(state, kind).where((row) => row['id'] == id).firstOrNull;

  static Data _get(Data state, String kind, String id) =>
      _find(state, kind, id) ??
      (throw const ApiError(404, 'not_found', '这条服务记录不存在'));

  static String _now() => DateTime.now().toUtc().toIso8601String();
  static Data _list(Iterable<Data> rows) => {'items': rows.toList()};

  static Data _event(String name, String action, [Data input = const {}]) => {
    'actor_name': name,
    'action': action,
    'note': text(input, 'note', text(input, 'reason')),
    'student_note': text(input, 'student_note'),
    'created_at': _now(),
  };

  static void _record(
    Data row,
    String actor,
    String action, [
    Data body = const {},
  ]) {
    (row['history'] as List).add(_event(actor, action, body));
  }

  static void seed(Data state) {
    _rows(state, 'staff').addAll([
      {
        'id': teacher,
        'nickname': '周知远',
        'role': 'teacher',
        'modes': ['online', 'onsite'],
        'bio': '心理中心老师。可以一起聊聊学业压力、关系困扰，以及最近让你感到疲惫的事情。',
        'location': '心理支持中心 202 室',
      },
      {
        'id': peer,
        'nickname': '许安然',
        'role': 'peer',
        'modes': ['online', 'onsite'],
        'bio': '朋辈支持员。我愿意听听你的校园生活，也可以一起想想接下来能做什么。',
        'location': '心理支持中心 103 室',
        'supervisor_id': teacher,
        'supervisor_name': '周知远',
      },
    ]);
    for (final role in ['teacher', 'peer']) {
      state['care_self_$role'] = <String, dynamic>{
        'id': demo,
        'role': role,
        'modes': ['online', 'onsite'],
        'location': '心理支持中心',
        'bio': role == 'teacher' ? '提供校内心理支持与咨询。' : '提供朋辈倾听与支持。',
        if (role == 'peer') 'supervisor_id': teacher,
        if (role == 'peer') 'supervisor_name': '周知远',
      };
    }

    final now = DateTime.now();
    DateTime day(int offset, int hour) =>
        DateTime(now.year, now.month, now.day + offset, hour);
    for (final (staff, role) in [(teacher, 'teacher'), (peer, 'peer')]) {
      for (var i = 1; i <= 8; i++) {
        for (final (hour, mode) in [(14, 'online'), (16, 'onsite')]) {
          _addSlot(state, '$staff-$i-$hour', staff, role, day(i, hour), mode);
        }
      }
    }

    final bookSlot = _addSlot(
      state,
      'demo-booked-slot',
      teacher,
      'teacher',
      day(1, 10),
      'online',
    );
    final booking = _addAppointment(
      state,
      'demo-booking',
      demo,
      text(data(state['profile']), 'nickname', '体验同学'),
      bookSlot,
      '最近准备考试时有些紧张，想聊聊作息和压力。',
    );
    booking['status'] = 'confirmed';
    _record(booking, '周知远', 'confirm');
    _openService(state, booking, appointment: true);

    final survey = _followup(
      state,
      _participants(booking),
      'demo-student-followup',
    );
    survey['created_at'] = now
        .subtract(const Duration(days: 2))
        .toUtc()
        .toIso8601String();

    for (final (role, hour, name) in [
      ('teacher', 14, '林小雨'),
      ('peer', 16, '陈星禾'),
    ]) {
      final slot = _addSlot(
        state,
        'demo-work-$role-slot',
        demo,
        role,
        day(1, hour),
        'online',
      );
      _addAppointment(
        state,
        'demo-work-$role-booking',
        student,
        name,
        slot,
        role == 'teacher' ? '最近很难集中精力，想聊聊学习节奏。' : '刚换到新的宿舍，还在适应。',
      );
      _addSlot(
        state,
        'demo-free-$role-slot',
        demo,
        role,
        day(2, hour),
        'onsite',
      );
      final followup = _followup(state, {
        'student_id': student,
        'student_name': name,
        'staff_id': demo,
        'staff_name': '体验接待员',
        'role': role,
      }, 'demo-work-$role-followup');
      followup.addAll({
        'status': role == 'teacher' ? 'pending_contact' : 'pending_review',
        'submitted_at': _now(),
        'answers': {
          'mood': role == 'teacher' ? 'same' : 'better',
          'helpfulness': 'helpful',
          'recommendation': '愿意推荐',
          'contact_requested': role == 'teacher',
          'note': role == 'teacher' ? '想再聊聊最近的睡眠情况。' : '散步让我放松了一些。',
        },
      });
    }
    final help = _addHelp(
      state,
      'demo-work-help',
      student,
      '林小雨',
      {
        'contact': '请通过站内消息联系',
        'preferred_time': '工作日 16:00 后',
        'body': '想请老师帮忙了解一下学校能提供哪些支持。',
      },
      staffId: demo,
      staffName: '体验接待员',
    );
    _openService(state, help);
    final transferred = _openService(state, {
      'id': 'demo-peer-service',
      'student_id': student,
      'student_name': '林小雨',
      'staff_id': peer,
      'staff_name': '许安然',
      'role': 'peer',
    });
    _rows(state, 'transfers').add({
      'id': 'demo-incoming-transfer',
      'student_name': '林小雨',
      'from_id': peer,
      'from_name': '许安然',
      'to_id': demo,
      'to_name': '体验接待员',
      'service_id': transferred['id'],
      'status': 'pending',
      'note': '同学希望进一步了解心理中心的支持，辛苦老师接续。',
      'created_at': _now(),
    });
  }

  static Data _addSlot(
    Data state,
    String id,
    String staffId,
    String role,
    DateTime start,
    String mode, {
    String? end,
  }) {
    final slot = <String, dynamic>{
      'id': id,
      'staff_id': staffId,
      'role': role,
      'mode': mode,
      'start_at': start.toUtc().toIso8601String(),
      'end_at':
          end ??
          start
              .add(Duration(minutes: role == 'peer' ? 30 : 50))
              .toUtc()
              .toIso8601String(),
      'available': true,
    };
    _rows(state, 'slots').add(slot);
    return slot;
  }

  static Data _staff(Data state, String staffId, String role) {
    if (staffId != demo) return _get(state, 'staff', staffId);
    return {
      ...data(state['care_self_$role']),
      'nickname': text(data(state['profile']), 'nickname', '体验接待员'),
    };
  }

  static Data _addAppointment(
    Data state,
    String id,
    String studentId,
    String studentName,
    Data slot,
    String note,
  ) {
    final staff = _staff(state, text(slot, 'staff_id'), text(slot, 'role'));
    final row = <String, dynamic>{
      'id': id,
      'slot_id': slot['id'],
      'staff_id': slot['staff_id'],
      'staff_name': staff['nickname'],
      'student_id': studentId,
      'student_name': studentName,
      'role': slot['role'],
      'mode': slot['mode'],
      'location': staff['location'],
      'start_at': slot['start_at'],
      'end_at': slot['end_at'],
      'status': 'pending',
      'note': note,
      'created_at': _now(),
      'history': [_event(studentName, 'create')],
    };
    slot.addAll({'available': false, 'appointment_id': id});
    _rows(state, 'appointments').insert(0, row);
    return row;
  }

  static Data _addHelp(
    Data state,
    String id,
    String studentId,
    String studentName,
    Data input, {
    String? staffId,
    String? staffName,
  }) {
    final row = <String, dynamic>{
      'id': id,
      'student_id': studentId,
      'student_name': studentName,
      'staff_id': ?staffId,
      'staff_name': ?staffName,
      'role': 'teacher',
      'body': text(input, 'body'),
      'contact': text(input, 'contact'),
      'preferred_time': text(input, 'preferred_time'),
      'status': staffId == null ? 'submitted' : 'assigned',
      'created_at': _now(),
      'history': [_event(studentName, 'submit')],
    };
    _rows(state, 'help-requests').insert(0, row);
    return row;
  }

  static Data _openService(Data state, Data row, {bool appointment = false}) {
    final existing = _find(state, 'services', text(row, 'service_id'));
    if (existing != null) return existing;
    final id = row['id'] == 'demo-booking' ? 'demo-service-booking' : newID();
    final conversationId = 'care-$id';
    row.addAll({'service_id': id, 'conversation_id': conversationId});
    final service = <String, dynamic>{
      ..._participants(row),
      'id': id,
      'conversation_id': conversationId,
      if (appointment) 'appointment_id': row['id'],
      'status': appointment ? 'waiting' : 'in_progress',
      'created_at': _now(),
    };
    _rows(state, 'services').insert(0, service);
    _syncConversation(state, service);
    return service;
  }

  static void _syncConversation(Data state, Data service) {
    MockSocial.ensureCareConversation(
      state,
      id: text(service, 'conversation_id'),
      studentId: text(service, 'student_id'),
      studentName: text(service, 'student_name'),
      staffId: text(service, 'staff_id'),
      staffName: text(service, 'staff_name'),
      staffRole: text(service, 'role'),
      appointmentId: service['appointment_id'] as String?,
      readOnly: service['status'] == 'closed',
    );
  }

  static Data _participants(Data row) => {
    'student_id': row['student_id'],
    'student_name': row['student_name'],
    'staff_id': row['staff_id'],
    'staff_name': row['staff_name'],
    'role': row['role'],
  };

  static Data _followup(Data state, Data row, [String? id]) {
    final survey = <String, dynamic>{
      ..._participants(row),
      'id': id ?? newID(),
      'service_id': row['service_id'],
      'status': 'awaiting',
      'answers': <String, dynamic>{},
      'created_at': _now(),
      'history': <Data>[],
    };
    _rows(state, 'followups').insert(0, survey);
    return survey;
  }

  static void _complete(Data state, Data row, Data body) {
    final service = _get(state, 'services', text(row, 'service_id'));
    service.addAll({
      'status': 'completed',
      'completed_at': _now(),
      'internal_note': text(body, 'internal_note', text(body, 'note')),
      'student_note': text(body, 'student_note'),
    });
    _followup(state, row);
  }

  static Never _stale([String message = '当前状态无法进行这项操作']) =>
      throw ApiError(409, 'conflict', message);

  Data? reply(
    String userId,
    String method,
    List<String> segments,
    Map<String, String> query,
    Data body,
    Data state,
  ) {
    if (segments.isEmpty) return null;
    final kind = segments.first;
    final id = segments.elementAtOrNull(1) ?? '';
    final action = segments.elementAtOrNull(2) ?? '';
    final work = query['scope'] == 'work';
    final space = text(state, 'space', 'student');
    final role = space == 'peer' ? 'peer' : 'teacher';
    final actor = text(data(state['profile']), 'nickname', '体验同学');

    switch (kind) {
      case 'staff':
        if (id == 'me') {
          if (method == 'PATCH') {
            final profile = state['care_self_$role'] as Data;
            for (final key in ['bio', 'modes', 'location']) {
              if (body.containsKey(key)) profile[key] = body[key];
            }
          }
          return _staff(state, demo, role);
        }
        if (method != 'GET') return null;
        if (id.isNotEmpty) return _get(state, kind, id);
        return _list(
          _items(state, kind)
              .where(
                (row) => query['role'] == null || row['role'] == query['role'],
              )
              .map((row) {
                final matching =
                    _items(state, 'slots')
                        .where(
                          (slot) =>
                              slot['staff_id'] == row['id'] &&
                              slot['available'] == true &&
                              DateTime.parse(
                                slot['start_at'],
                              ).isAfter(DateTime.now()) &&
                              (query['mode'] == null ||
                                  slot['mode'] == query['mode']) &&
                              (query['date'] == null ||
                                  DateTime.parse(slot['start_at'])
                                      .toLocal()
                                      .toIso8601String()
                                      .startsWith(query['date']!)),
                        )
                        .toList()
                      ..sort(
                        (a, b) =>
                            text(a, 'start_at').compareTo(text(b, 'start_at')),
                      );
                return {...row, 'next_slot': matching.firstOrNull?['start_at']};
              })
              .where(
                (row) =>
                    (query['mode'] == null && query['date'] == null) ||
                    row['next_slot'] != null,
              ),
        );
      case 'slots':
        if (method == 'GET' && id.isEmpty) {
          final rows =
              _items(state, kind)
                  .where(
                    (row) => work
                        ? row['staff_id'] == userId && row['role'] == role
                        : row['staff_id'] == query['staff_id'] &&
                              row['available'] == true &&
                              DateTime.parse(
                                row['start_at'],
                              ).isAfter(DateTime.now()),
                  )
                  .toList()
                ..sort(
                  (a, b) => text(a, 'start_at').compareTo(text(b, 'start_at')),
                );
          return _list(rows);
        }
        if (method == 'POST' && id.isEmpty) {
          final items = objects(body['items']);
          final slots = <Data>[];
          for (final item in items) {
            final start = DateTime.tryParse(text(item, 'start_at'));
            final end = DateTime.tryParse(text(item, 'end_at'));
            if (start == null ||
                end == null ||
                !start.isAfter(DateTime.now()) ||
                !end.isAfter(start)) {
              _stale('请设置一个未来的有效时段');
            }
            final conflict = [..._items(state, kind), ...slots].any(
              (row) =>
                  row['staff_id'] == userId &&
                  row['role'] == role &&
                  start.isBefore(DateTime.parse(row['end_at'])) &&
                  end.isAfter(DateTime.parse(row['start_at'])),
            );
            if (conflict) _stale('所选时间与已发布时段重叠');
            slots.add({
              ...item,
              'id': newID(),
              'staff_id': userId,
              'role': role,
              'available': true,
            });
          }
          _rows(state, kind).addAll(slots);
          return _list(slots);
        }
        if (method == 'DELETE' && id.isNotEmpty) {
          final slot = _get(state, kind, id);
          if (slot['available'] != true || slot['staff_id'] != userId) {
            _stale('该时段无法撤下');
          }
          _rows(state, kind).remove(slot);
          return {};
        }
      case 'appointments':
      case 'followups':
      case 'help-requests':
        if (method == 'GET' && id.isEmpty) {
          return _list(
            _items(state, kind).where(
              (row) => work
                  ? row['staff_id'] == userId && row['role'] == role
                  : row['student_id'] == userId,
            ),
          );
        }
        if (method == 'GET' && action.isEmpty) return _get(state, kind, id);
        if (method == 'POST' && id.isEmpty && kind == 'appointments') {
          final requestId = text(body, 'id', newID());
          final existing = _find(state, kind, requestId);
          if (existing != null) return existing;
          final slot = _get(state, 'slots', text(body, 'slot_id'));
          if (slot['available'] != true ||
              !DateTime.parse(slot['start_at']).isAfter(DateTime.now())) {
            _stale('这个时段已无法预约，请选择另一个时间');
          }
          return _addAppointment(
            state,
            requestId,
            userId,
            actor,
            slot,
            text(body, 'note'),
          );
        }
        if (method == 'POST' && id.isEmpty && kind == 'help-requests') {
          return _addHelp(state, newID(), userId, actor, body);
        }
        if (id.isNotEmpty &&
            action.isNotEmpty &&
            (method == 'POST' || method == 'PUT')) {
          final row = _get(state, kind, id);
          switch (kind) {
            case 'appointments':
              if (method == 'POST')
                return _appointmentAction(
                  state,
                  row,
                  userId,
                  actor,
                  action,
                  body,
                );
            case 'followups':
              if (method == 'POST' || (method == 'PUT' && action == 'draft')) {
                return _followupAction(row, userId, actor, action, body);
              }
            case 'help-requests':
              if (method == 'POST')
                return _helpAction(state, row, userId, actor, action, body);
          }
        }
      case 'services':
        if (method != 'GET' || action.isNotEmpty) return null;
        if (id.isEmpty) {
          return _list(
            _items(state, kind).where((row) => row['student_id'] == userId),
          );
        }
        final service = _get(state, kind, id);
        return {
          ...service,
          if (service['staff_id'] != userId) 'internal_note': '',
          'shares': MockAi.serviceShares(userId, service, state),
        };
      case 'transfers':
        if (method == 'GET' && id.isEmpty) {
          return _list(
            _items(state, kind).where(
              (row) =>
                  (row['to_id'] == userId && role == 'teacher') ||
                  (row['from_id'] == userId && row['from_role'] == role),
            ),
          );
        }
        if (method == 'POST' && id.isEmpty) {
          final service = _get(state, 'services', text(body, 'service_id'));
          final target = _get(state, 'staff', text(body, 'staff_id'));
          if (service['staff_id'] != userId ||
              target['role'] != 'teacher' ||
              !['waiting', 'in_progress'].contains(service['status'])) {
            _stale('这项服务当前无法转交');
          }
          final pending = _items(state, kind).any(
            (row) =>
                row['service_id'] == service['id'] &&
                row['status'] == 'pending',
          );
          if (pending) _stale('此项服务已有待接收的转交');
          final row = <String, dynamic>{
            'id': newID(),
            'service_id': service['id'],
            'student_name': service['student_name'],
            'from_id': userId,
            'from_name': actor,
            'from_role': role,
            'to_id': target['id'],
            'to_name': target['nickname'],
            'status': 'pending',
            'note': text(body, 'note'),
            'created_at': _now(),
          };
          _rows(state, kind).insert(0, row);
          return row;
        }
        if (method == 'POST' && ['accept', 'reject'].contains(action)) {
          final row = _get(state, kind, id);
          if (row['status'] != 'pending' || row['to_id'] != userId) _stale();
          if (action == 'accept') {
            final service = _get(state, 'services', text(row, 'service_id'));
            final assignee = {
              'staff_id': userId,
              'staff_name': actor,
              'role': 'teacher',
            };
            service.addAll(assignee);
            _find(
              state,
              'appointments',
              text(service, 'appointment_id'),
            )?.addAll(assignee);
            MockAi.revokeServiceShares(text(service, 'id'), state);
            _syncConversation(state, service);
          }
          row['status'] = action == 'accept' ? 'accepted' : 'rejected';
          return row;
        }
    }
    return null;
  }

  static Data _appointmentAction(
    Data state,
    Data row,
    String userId,
    String actor,
    String action,
    Data body,
  ) {
    final status = row['status'];
    final staff = row['staff_id'] == userId;
    if (action != 'cancel' && !staff) _stale();
    final next = switch ((status, action)) {
      ('pending', 'confirm') => 'confirmed',
      ('pending', 'reject') => 'rejected',
      ('pending' || 'confirmed', 'cancel') => 'canceled',
      ('confirmed', 'start') => 'in_progress',
      ('confirmed', 'no-show') => 'no_show',
      ('in_progress', 'complete') => 'completed',
      _ => _stale(),
    };
    if (next == 'confirmed') _openService(state, row, appointment: true);
    if (next == 'in_progress') {
      _get(state, 'services', text(row, 'service_id'))['status'] = next;
    }
    if (next == 'completed') _complete(state, row, body);
    if (['canceled', 'rejected', 'no_show'].contains(next)) {
      final slot = _find(state, 'slots', text(row, 'slot_id'));
      slot?['available'] = true;
      slot?.remove('appointment_id');
      final service = _find(state, 'services', text(row, 'service_id'));
      if (service != null) {
        service['status'] = 'closed';
        MockAi.revokeServiceShares(text(service, 'id'), state);
        _syncConversation(state, service);
      }
    }
    row['status'] = next;
    row['reason'] = text(body, 'reason');
    _record(row, actor, action, body);
    return row;
  }

  static Data _followupAction(
    Data row,
    String userId,
    String actor,
    String action,
    Data body,
  ) {
    final status = row['status'];
    if (action == 'draft' || action == 'submit') {
      if (row['student_id'] != userId || status != 'awaiting') _stale();
      row['answers'] = body;
      if (action == 'draft') return row;
      row['submitted_at'] = _now();
      row['status'] =
          body['mood'] == 'worse' || body['contact_requested'] == true
          ? 'pending_contact'
          : 'pending_review';
    } else {
      if (row['staff_id'] != userId) _stale();
      row['status'] = switch ((status, action)) {
        ('awaiting', 'resend') => 'awaiting',
        ('pending_review', 'review') => 'closed',
        ('pending_contact' || 'following' || 'pending_review', 'contact') =>
          'following',
        ('pending_contact' || 'following' || 'pending_review', 'close') =>
          'closed',
        _ => _stale(),
      };
    }
    _record(row, actor, action, body);
    return row;
  }

  static Data _helpAction(
    Data state,
    Data row,
    String userId,
    String actor,
    String action,
    Data body,
  ) {
    if (row['staff_id'] != userId) _stale();
    row['status'] = switch ((row['status'], action)) {
      ('assigned', 'claim') => 'contacting',
      ('assigned' || 'contacting', 'contact') => 'contacting',
      ('assigned' || 'contacting', 'close') => 'closed',
      _ => _stale(),
    };
    if (action == 'close') _complete(state, row, body);
    _record(row, actor, action, body);
    return row;
  }
}
