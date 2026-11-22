import '../shared/api.dart';

class MockAi {
  static const _demoUser = 'demo-user';
  static const _limit = 30;

  static void seed(Data state) {
    final created = DateTime.now()
        .subtract(const Duration(days: 1))
        .toUtc()
        .toIso8601String();
    state.putIfAbsent(
      'ai_conversations',
      () => <Data>[
        {
          'id': 'demo-ai-orientation',
          'user_id': _demoUser,
          'title': '新学期的安排',
          'created_at': created,
          'updated_at': created,
        },
      ],
    );
    state.putIfAbsent(
      'ai_messages',
      () => <Data>[
        {
          'id': 'demo-ai-question',
          'conversation_id': 'demo-ai-orientation',
          'role': 'user',
          'text': '开学后事情一下子多起来了，我不知道该从哪件开始。',
          'created_at': created,
        },
        {
          'id': 'demo-ai-answer',
          'conversation_id': 'demo-ai-orientation',
          'role': 'assistant',
          'text': '事情同时涌上来时，很难决定从哪里开始。要不要先列出今天必须完成的一件事，再给它找一个十分钟就能做完的开头？',
          'created_at': created,
        },
      ],
    );
    for (final key in ['ai_runs', 'ai_shares', 'ai_admissions', 'ai_ratings']) {
      state.putIfAbsent(key, () => <Data>[]);
    }
    state.putIfAbsent('ai_consent', () => <String, dynamic>{});
  }

  List<Data> _rows(Data state, String key) => (state[key] as List).cast<Data>();

  static String _stamp() => DateTime.now().toUtc().toIso8601String();

  static const _missing = ApiError(404, 'not_found', '找不到这条记录');

  Data _owned(List<Data> rows, String id, String userId) => rows.firstWhere(
    (row) => row['id'] == id && row['user_id'] == userId,
    orElse: () => throw _missing,
  );

  Data? _latest(Data state, String conversationId) {
    for (final row in _rows(state, 'ai_runs').reversed) {
      if (row['conversation_id'] == conversationId) return row;
    }
    return null;
  }

  static bool _active(Data run) =>
      run['status'] == 'waiting' || run['status'] == 'streaming';

  static Data _runView(Data run) => {
    for (final key in [
      'id',
      'input_id',
      'conversation_id',
      'status',
      'created_at',
      'actions',
    ])
      if (run.containsKey(key)) key: run[key],
  };

  List<Data> _messages(Data state, String conversationId) => _rows(
    state,
    'ai_messages',
  ).where((row) => row['conversation_id'] == conversationId).toList();

  int _pageLimit(Map<String, String> query) {
    final limit = int.tryParse(query['limit'] ?? '') ?? 100;
    return limit <= 0 ? 100 : limit.clamp(1, 200).toInt();
  }

  Data _quota(Data state, String userId) {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final date = DateTime(now.year, now.month, now.day);
    final used = _rows(state, 'ai_admissions').where((record) {
      final created = DateTime.parse(text(record, 'created_at'));
      return record['user_id'] == userId && !created.isBefore(date);
    }).length;
    return {
      'enabled': true,
      'daily_limit': _limit,
      'used': used,
      'remaining': _limit - used,
      'reset_at': tomorrow.toUtc().toIso8601String(),
    };
  }

  Data _start(
    Data state,
    Data conversation,
    String inputId,
    String message, {
    String retryId = '',
  }) {
    final id = text(conversation, 'id');
    final userId = text(conversation, 'user_id');
    final runs = _rows(state, 'ai_runs');
    for (final run in runs) {
      if (run['conversation_id'] == id &&
          run['input_id'] == inputId &&
          run['retry_id'] == retryId) {
        if (run['prompt'] != message) {
          throw const ApiError(409, 'input_conflict', '同一消息标识已用于不同内容');
        }
        return _runView(run);
      }
    }
    if (runs.any((run) => run['user_id'] == userId && _active(run))) {
      throw const ApiError(409, 'busy', '已有一条回复正在生成');
    }
    final created = _stamp();
    if (retryId.isEmpty) {
      if ((_quota(state, userId)['remaining'] as int) <= 0) {
        throw const ApiError(429, 'quota_exhausted', '今日次数已用完');
      }
      _rows(
        state,
        'ai_admissions',
      ).add({'user_id': userId, 'created_at': created});
      _rows(state, 'ai_messages').add({
        'id': newID(),
        'conversation_id': id,
        'role': 'user',
        'text': message,
        'input_id': inputId,
        'created_at': created,
      });
      if (conversation['title'] == '新对话') {
        conversation['title'] = _clip(message, 24);
      }
    } else {
      final latest = _latest(state, id);
      if (latest?['input_id'] != inputId || latest?['status'] != 'cancelled') {
        throw const ApiError(409, 'not_retryable', '只能重试最近一条未完成的回复');
      }
    }
    conversation['updated_at'] = created;
    final run = <String, dynamic>{
      'id': newID(),
      'user_id': userId,
      'input_id': inputId,
      'conversation_id': id,
      'retry_id': retryId,
      'created_at': created,
      'status': 'waiting',
      'prompt': message,
      'parts': _response(message),
    };
    if (['预约', '老师', '朋辈', '人工', '咨询'].any(message.contains)) {
      run['actions'] = [
        {'kind': 'support', 'title': '查看校内支持'},
      ];
    }
    runs.add(run);
    return _runView(run);
  }

  static String _clip(String value, int limit) =>
      String.fromCharCodes(value.runes.take(limit));

  static List<String> _response(String message) {
    if (['预约', '老师', '咨询', '朋辈', '人工'].any(message.contains)) {
      return [
        '如果你希望找人聊聊，可以先看看有哪些校内支持。',
        '你可以浏览老师或朋辈的服务时间，',
        '也可以在人工求助中留下你希望被联系的方式。',
      ];
    }
    if (['考试', '作业', '学习', '压力', '焦虑'].any(message.contains)) {
      return ['这听起来很耗费心力。', '如果眼下积了好几件事，可以先选一件你能在十分钟内开始的。', '你想从哪件事说起？'];
    }
    if (['室友', '朋友', '同学', '关系', '孤单'].any(message.contains)) {
      return [
        '这些相处中的细节有时会在心里留很久。',
        '我们可以慢慢理一理当时发生了什么，以及你希望对方理解什么。',
        '哪一段最想先说？',
      ];
    }
    if (['睡', '失眠', '累'].any(message.contains)) {
      return ['听起来你这段时间很累。', '如果想聊聊，可以从最近一次特别疲惫的时候说起。', '那天有哪些事在占用你的精力？'];
    }
    if (['开心', '高兴', '顺利', '成功'].any(message.contains)) {
      return ['可以留一点时间记住这个顺利的时刻。', '回想一下，哪件事让你最想分享？'];
    }
    return ['我听到了。你可以按自己的节奏说。', '如果你想继续，可以挑一件最近印象最深的事，', '从当时发生了什么开始。'];
  }

  Data? reply(
    String userId,
    String method,
    List<String> segments,
    Map<String, String> query,
    Data body,
    Data state,
  ) {
    if (segments.isEmpty) return null;
    if (segments.first == 'me' &&
        segments.length == 2 &&
        segments[1] == 'ai-consent') {
      final consent = state['ai_consent'] as Data;
      if (method == 'POST') {
        if (body['agreed'] != true) {
          throw const ApiError(400, 'invalid_consent', '请确认是否同意使用 AI 伙伴');
        }
        consent[userId] = true;
      }
      if (method == 'POST' || method == 'GET') {
        return {'agreed': consent[userId] == true};
      }
    }
    if (segments.first != 'ai') {
      return _shareRoutes(userId, method, segments, body, state);
    }
    if (segments.length == 2 && segments[1] == 'quota' && method == 'GET') {
      return _quota(state, userId);
    }
    if (segments.length == 3 && segments[1] == 'runs' && method == 'GET') {
      return _runView(_owned(_rows(state, 'ai_runs'), segments[2], userId));
    }
    if (segments.length == 4 && method == 'POST') {
      if (segments[1] == 'runs' && segments[3] == 'cancel') {
        final run = _owned(_rows(state, 'ai_runs'), segments[2], userId);
        if (_active(run)) run['status'] = 'cancelled';
        return _runView(run);
      }
      if (segments[1] == 'inputs' && segments[3] == 'retry') {
        final retryId = text(body, 'id').trim();
        if (retryId.isEmpty) {
          throw const ApiError(400, 'invalid_input', '缺少重试标识');
        }
        final original = _rows(state, 'ai_runs').firstWhere(
          (row) => row['input_id'] == segments[2] && row['user_id'] == userId,
          orElse: () => throw _missing,
        );
        final conversation = _owned(
          _rows(state, 'ai_conversations'),
          text(original, 'conversation_id'),
          userId,
        );
        return _start(
          state,
          conversation,
          segments[2],
          text(original, 'prompt'),
          retryId: retryId,
        );
      }
    }
    if (segments.length < 2 || segments[1] != 'conversations') return null;
    return _conversationRoutes(userId, method, segments, query, body, state);
  }

  Data? _conversationRoutes(
    String userId,
    String method,
    List<String> segments,
    Map<String, String> query,
    Data body,
    Data state,
  ) {
    final conversations = _rows(state, 'ai_conversations');
    if (segments.length == 2) {
      if (method == 'GET') {
        final search = (query['q'] ?? '').trim().toLowerCase();
        final found =
            conversations
                .where(
                  (row) =>
                      row['user_id'] == userId &&
                      text(row, 'title').toLowerCase().contains(search),
                )
                .toList()
              ..sort(
                (a, b) =>
                    text(b, 'updated_at').compareTo(text(a, 'updated_at')),
              );
        return {'items': found.take(_pageLimit(query)).toList()};
      }
      if (method == 'POST') {
        final title = text(body, 'title').trim();
        if (title.runes.length > 80) {
          throw const ApiError(400, 'invalid_title', '会话标题不能超过 80 字');
        }
        final created = _stamp();
        final conversation = <String, dynamic>{
          'id': newID(),
          'user_id': userId,
          'title': title.isEmpty ? '新对话' : title,
          'created_at': created,
          'updated_at': created,
        };
        conversations.add(conversation);
        return Map.of(conversation);
      }
      return null;
    }
    final id = segments[2];
    final conversation = _owned(conversations, id, userId);
    if (segments.length == 3) {
      if (method == 'GET') return Map.of(conversation);
      if (method == 'PATCH') {
        final title = text(body, 'title').trim();
        if (title.isEmpty || title.runes.length > 80) {
          throw const ApiError(400, 'invalid_title', '请输入 1 到 80 字的会话标题');
        }
        conversation['title'] = title;
        conversation['updated_at'] = _stamp();
        return Map.of(conversation);
      }
      if (method == 'DELETE') {
        conversations.remove(conversation);
        for (final run in _rows(state, 'ai_runs')) {
          if (run['conversation_id'] == id && _active(run)) {
            run['status'] = 'cancelled';
          }
        }
        for (final key in ['ai_messages', 'ai_runs', 'ai_ratings']) {
          _rows(state, key).removeWhere((row) => row['conversation_id'] == id);
        }
        for (final share in _rows(state, 'ai_shares')) {
          if (share['conversation_id'] == id && share['revoked_at'] == null) {
            share['revoked_at'] = _stamp();
          }
        }
        return {};
      }
    }
    if (segments.length < 4) return null;
    final section = segments[3];
    if (segments.length == 4 && section == 'messages' && method == 'GET') {
      final messages = _messages(state, id);
      final before = query['before'] ?? '';
      final end = before.isEmpty
          ? messages.length
          : messages.indexWhere((row) => row['id'] == before);
      if (end < 0) throw _missing;
      final start = (end - _pageLimit(query)).clamp(0, end).toInt();
      final page = messages.sublist(start, end);
      final run = _latest(state, id);
      return {
        'items': page,
        if (start > 0) 'next_before': page.first['id'],
        if (run != null) 'run': _runView(run),
      };
    }
    if (segments.length == 4 && section == 'inputs' && method == 'POST') {
      if ((state['ai_consent'] as Data)[userId] != true) {
        throw const ApiError(403, 'consent_required', '请先确认 AI 使用说明');
      }
      final inputId = text(body, 'id').trim();
      final message = text(body, 'text').trim();
      if (inputId.isEmpty || message.isEmpty || message.runes.length > 4000) {
        throw const ApiError(400, 'invalid_input', '请输入 1 到 4000 字的消息');
      }
      return _start(state, conversation, inputId, message);
    }
    if (segments.length == 4 &&
        section == 'share-summary' &&
        method == 'POST') {
      final selected = _selectedMessages(state, id, body);
      final summary = selected
          .map(
            (row) =>
                _clip(text(row, 'text').replaceAll(RegExp(r'\s+'), ' '), 140),
          )
          .join('\n');
      return {'summary': summary};
    }
    if (segments.length == 6 &&
        section == 'messages' &&
        segments[5] == 'feedback' &&
        method == 'PUT') {
      final messageId = segments[4];
      if (!_messages(
        state,
        id,
      ).any((row) => row['id'] == messageId && row['role'] == 'assistant')) {
        throw _missing;
      }
      final helpful = body['helpful'];
      final note = text(body, 'note').trim();
      if (helpful is! bool || note.runes.length > 500) {
        throw const ApiError(400, 'invalid_feedback', '请选择反馈类型，意见最多 500 字');
      }
      final ratings = _rows(state, 'ai_ratings');
      ratings.removeWhere((row) => row['message_id'] == messageId);
      ratings.add({
        'conversation_id': id,
        'message_id': messageId,
        'helpful': helpful,
        'note': note,
      });
      return {};
    }
    return null;
  }

  List<Data> _selectedMessages(Data state, String conversationId, Data body) {
    final ids = body['message_ids'];
    if (ids is! List || ids.isEmpty || ids.length > 20) {
      throw const ApiError(400, 'invalid_messages', '请选择 1 到 20 条消息');
    }
    final rows = _messages(
      state,
      conversationId,
    ).where((row) => ids.contains(row['id'])).toList();
    if (ids.length != rows.length) throw _missing;
    return rows;
  }

  Data _service(String id, Data state) {
    for (final service in objects(state['care_services'])) {
      if (service['id'] == id) return service;
    }
    return {};
  }

  static bool _shareable(Data service) {
    if (service.isEmpty || service['status'] == 'closed') return false;
    final completed = DateTime.tryParse(text(service, 'completed_at'));
    return completed == null ||
        completed.add(const Duration(days: 7)).isAfter(DateTime.now());
  }

  static bool _shareActive(Data share, Data service) =>
      share['revoked_at'] == null &&
      share['staff_id'] == service['staff_id'] &&
      _shareable(service);

  static List<Data> serviceShares(String userId, Data service, Data state) {
    if (userId != service['student_id'] && userId != service['staff_id']) {
      return [];
    }
    return objects(state['ai_shares']).reversed
        .where(
          (row) =>
              row['service_id'] == service['id'] && _shareActive(row, service),
        )
        .toList();
  }

  static void revokeServiceShares(String serviceId, Data state) {
    for (final share in (state['ai_shares'] as List? ?? []).cast<Data>()) {
      if (share['service_id'] == serviceId && share['revoked_at'] == null) {
        share['revoked_at'] = _stamp();
      }
    }
  }

  Data? _shareRoutes(
    String userId,
    String method,
    List<String> segments,
    Data body,
    Data state,
  ) {
    final shares = _rows(state, 'ai_shares');
    if (segments.length == 2 &&
        segments.first == 'me' &&
        segments[1] == 'shares' &&
        method == 'GET') {
      return {
        'items': [
          for (final row in shares.reversed)
            if (row['student_id'] == userId)
              {
                ...row,
                'active': _shareActive(
                  row,
                  _service(text(row, 'service_id'), state),
                ),
              },
        ].take(100).toList(),
      };
    }
    if (segments.length == 2 &&
        segments.first == 'shares' &&
        method == 'DELETE') {
      final share = shares.firstWhere(
        (row) => row['id'] == segments[1] && row['student_id'] == userId,
        orElse: () => throw _missing,
      );
      share['revoked_at'] ??= _stamp();
      return {};
    }
    if (segments.length != 3 ||
        segments.first != 'services' ||
        segments[2] != 'shares') {
      return null;
    }
    final serviceId = segments[1];
    final service = _service(serviceId, state);
    if (method == 'GET')
      return {'items': serviceShares(userId, service, state)};
    if (method != 'POST') return null;
    if (service['student_id'] != userId || !_shareable(service)) throw _missing;
    final staffId = text(service, 'staff_id');
    final expected = text(body, 'expected_staff_id');
    if (expected.isEmpty) {
      throw const ApiError(400, 'invalid_recipient', '请确认分享接收人');
    }
    if (expected != staffId) {
      throw const ApiError(409, 'stale', '负责人员已更换，请重新确认分享接收人');
    }
    final conversationId = text(body, 'conversation_id');
    _owned(_rows(state, 'ai_conversations'), conversationId, userId);
    var content = text(body, 'summary').trim();
    if (content.runes.length > 6000) {
      throw const ApiError(400, 'summary_too_long', '分享摘要最多 6000 字');
    }
    if (content.isEmpty) {
      content = _selectedMessages(state, conversationId, body)
          .map((row) {
            final speaker = row['role'] == 'user' ? '我' : 'AI';
            return '$speaker：${text(row, 'text')}';
          })
          .join('\n\n');
      if (content.runes.length > 12000) {
        throw const ApiError(400, 'share_too_long', '选中的内容过长，请减少消息数');
      }
    }
    final share = <String, dynamic>{
      'id': newID(),
      'conversation_id': conversationId,
      'service_id': serviceId,
      'staff_id': staffId,
      'staff_name': service['staff_name'],
      'student_id': userId,
      'body': content,
      'created_at': _stamp(),
    };
    shares.add(share);
    return Map.of(share);
  }

  // Completion is independent of the view's subscription. For example, opening
  // history can close the stream while a simulated reply is still in progress.
  final _finishing = <String, Future<Object?>>{};
  static const _partDelay = Duration(milliseconds: 650);

  Future<Object?> _finish(
    Data run,
    Data state,
    List<String> parts,
    Future<void> Function()? persist,
  ) async {
    try {
      await Future<void>.delayed(
        _partDelay * parts.length + const Duration(milliseconds: 250),
      );
      if (!_active(run)) return null;
      final id = text(run, 'conversation_id');
      final conversation = _owned(
        _rows(state, 'ai_conversations'),
        id,
        text(run, 'user_id'),
      );
      final now = _stamp();
      _rows(state, 'ai_messages').add({
        'id': newID(),
        'conversation_id': id,
        'input_id': run['input_id'],
        'role': 'assistant',
        'text': parts.join(),
        'created_at': now,
      });
      conversation['updated_at'] = now;
      run['status'] = 'completed';
      await persist?.call();
      return null;
    } catch (error) {
      return error;
    } finally {
      _finishing.remove(text(run, 'id'));
    }
  }

  Stream<Data> events(
    String runId,
    Data state, {
    String userId = _demoUser,
    Future<void> Function()? persist,
  }) async* {
    final run = _owned(_rows(state, 'ai_runs'), runId, userId);
    if (!_active(run)) {
      yield {'event': 'snapshot', 'run': _runView(run), 'reset': true};
      return;
    }
    final parts = (run['parts'] as List).cast<String>();
    final completion = _finishing.putIfAbsent(
      runId,
      () => _finish(run, state, parts, persist),
    );
    yield {'event': 'snapshot', 'run': _runView(run), 'reset': true};
    for (final part in parts) {
      await Future<void>.delayed(_partDelay);
      if (!_active(run)) break;
      run['status'] = 'streaming';
      yield {'event': 'delta', 'run': _runView(run), 'text': part};
    }
    if (run['status'] != 'cancelled') {
      final error = await completion;
      if (error != null) throw error;
    }
    yield {'event': 'done', 'run': _runView(run)};
  }
}
