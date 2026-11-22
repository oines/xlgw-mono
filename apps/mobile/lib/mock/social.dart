import '../shared/api.dart';

class MockSocial {
  static const _demo = 'demo-user';
  static const _names = {
    _demo: '林同学',
    'demo-mu': '小木',
    'demo-yu': '阿雨',
    'demo-xing': '小星',
  };

  static List<Data> _rows(Data state, String key) =>
      ((state['social_$key'] ??= <Data>[]) as List).cast<Data>();

  static Data? _find(Iterable<Data> rows, String id) =>
      rows.where((row) => row['id'] == id).firstOrNull;

  static Data _require(Iterable<Data> rows, String id) =>
      _find(rows, id) ?? (throw const ApiError(404, 'not_found', '内容已不存在'));

  static String _name(Data state, String id) => id == _demo
      ? text(data(state['profile']), 'nickname', _names[_demo]!)
      : _names[id] ?? '同学';

  static String _at([int minutesAgo = 0]) => DateTime.now()
      .toUtc()
      .subtract(Duration(minutes: minutesAgo))
      .toIso8601String();

  static int _latest(Data a, Data b) =>
      text(b, 'created_at').compareTo(text(a, 'created_at'));

  static Data _items(Iterable<Data> rows) => {
    'items': [
      for (final row in rows) {...row},
    ],
  };

  static bool _blocks(Data state, Object? user, Object? other) => _rows(
    state,
    'blocks',
  ).any((row) => row['owner_id'] == user && row['id'] == other);

  static bool _blockedPair(Data state, Object? user, Object? other) =>
      _blocks(state, user, other) || _blocks(state, other, user);

  static Data _byAuthor(Data state, Data row) {
    final author = text(row, 'author_id');
    return {
      ...row,
      'author_name': _name(state, author),
      'author_avatar': author == _demo
          ? text(data(state['profile']), 'avatar_url')
          : '',
    };
  }

  static Data _post(Data state, String user, Data row) {
    final resonances = (row['resonance_users'] as List?) ?? const [];
    final publicRow = _byAuthor(state, row)
      ..remove('resonance_users')
      ..remove('seed_resonances');
    return {
      ...publicRow,
      'resonated': resonances.contains(user),
      'resonances': (row['seed_resonances'] as int? ?? 0) + resonances.length,
      'comments': _rows(
        state,
        'comments',
      ).where((comment) => comment['post_id'] == row['id']).length,
    };
  }

  static Data _requestRow(
    Data state,
    String id,
    String sender,
    String recipient,
    String note, {
    String status = 'pending',
    String? conversation,
    String? created,
  }) => {
    'id': id,
    'sender_id': sender,
    'sender_name': _name(state, sender),
    'recipient_id': recipient,
    'recipient_name': _name(state, recipient),
    'note': note,
    'status': status,
    'conversation_id': conversation,
    'created_at': created ?? _at(),
  };

  static void addNotice(
    Data state, {
    required String userId,
    required String title,
    required String targetType,
    required String targetId,
    String body = '',
    bool work = false,
    String? id,
  }) {
    final rows = _rows(state, 'notices');
    final noticeId = id ?? newID();
    if (_find(rows, noticeId) != null) return;
    rows.add({
      'id': noticeId,
      'user_id': userId,
      'work': work,
      'kind': targetType,
      'title': title,
      'body': body,
      'target_type': targetType,
      'target_id': targetId,
      'read': false,
      'created_at': _at(),
    });
  }

  static void ensureCareConversation(
    Data state, {
    required String id,
    required String studentId,
    required String studentName,
    required String staffId,
    required String staffName,
    required String staffRole,
    String? appointmentId,
    bool? readOnly,
  }) {
    final rows = _rows(state, 'conversations');
    var row = _find(rows, id);
    if (row == null) {
      final created = _at(35);
      row = {
        'id': id,
        'kind': 'care',
        'updated_at': created,
        'messages': <Data>[
          {
            'id': 'greeting-$id',
            'sender_id': staffId == _demo ? studentId : staffId,
            'sender_name': staffId == _demo ? studentName : staffName,
            'body': staffId == _demo
                ? '你好，我想聊聊最近遇到的一些困扰。'
                : '你好，我在这里。你可以从最近的一件小事说起。',
            'created_at': created,
          },
        ],
        'last_read': <String, int>{},
      };
      rows.add(row);
    }
    row.addAll({
      'left_id': studentId,
      'left_name': studentName,
      'right_id': staffId,
      'right_name': staffName,
      'staff_role': staffRole,
    });
    if (appointmentId != null) row['appointment_id'] = appointmentId;
    if (readOnly != null) row['closed'] = readOnly;
  }

  static Data _peer(
    Data state,
    String id,
    String first,
    String second, {
    List<Data> messages = const [],
  }) {
    final row = {
      'id': id,
      'kind': 'peer',
      'left_id': first,
      'left_name': _name(state, first),
      'right_id': second,
      'right_name': _name(state, second),
      'messages': [...messages],
      'last_read': <String, int>{},
      'updated_at': messages.isEmpty ? _at() : messages.last['created_at'],
    };
    _rows(state, 'conversations').add(row);
    return row;
  }

  static void seed(Data state) {
    if (state['social_seeded'] == true) return;
    _rows(state, 'posts').addAll([
      {
        'id': 'demo-post-walk',
        'author_id': 'demo-mu',
        'body': '今天下课后绕操场走了一圈。风有点凉，但走着走着就安静下来了。有没有人也喜欢在傍晚散步？',
        'tags': ['平静', '疲惫'],
        'created_at': _at(45),
        'seed_resonances': 6,
      },
      {
        'id': 'demo-post-exam',
        'author_id': 'demo-yu',
        'body': '复习进度比预想中慢，脑子里一直在算还剩多少天。决定今晚先复习一章，再早点睡。',
        'tags': ['焦虑', '期待'],
        'created_at': _at(130),
        'seed_resonances': 12,
      },
      {
        'id': 'demo-post-books',
        'author_id': _demo,
        'body': '最近在试着把睡前刷手机的时间换成读几页书。昨天读了四页，今天也想继续。',
        'tags': ['期待'],
        'created_at': _at(220),
        'seed_resonances': 3,
      },
      {
        'id': 'demo-post-sun',
        'author_id': 'demo-xing',
        'body': '和室友坐在图书馆外面的台阶上晒了会儿太阳，这周难得有这么舒服的午后。',
        'tags': ['开心'],
        'created_at': _at(390),
        'seed_resonances': 8,
      },
    ]);
    _rows(state, 'comments').addAll([
      {
        'id': 'demo-comment-walk',
        'post_id': 'demo-post-walk',
        'author_id': 'demo-xing',
        'body': '我常在晚饭后去操场，天刚暗下来那会儿最舒服。',
        'created_at': _at(39),
      },
      {
        'id': 'demo-reply-walk',
        'post_id': 'demo-post-walk',
        'parent_id': 'demo-comment-walk',
        'author_id': _demo,
        'body': '我也是，风一吹就觉得放松多了。',
        'created_at': _at(34),
      },
      {
        'id': 'demo-comment-books',
        'post_id': 'demo-post-books',
        'author_id': 'demo-mu',
        'body': '四页已经很好了。你最近在看什么书？',
        'created_at': _at(65),
      },
    ]);
    _rows(state, 'requests').addAll([
      _requestRow(
        state,
        'demo-chat-request',
        'demo-yu',
        _demo,
        '看到你在社区分享的读书习惯，也想聊聊怎么慢慢放松下来。',
        created: _at(50),
      ),
      _requestRow(
        state,
        'demo-chat-accepted',
        'demo-mu',
        _demo,
        '想跟你聊聊学校附近散步的地方。',
        status: 'accepted',
        conversation: 'demo-peer-chat',
        created: _at(160),
      ),
    ]);
    _peer(
      state,
      'demo-peer-chat',
      _demo,
      'demo-mu',
      messages: [
        {
          'id': 'demo-message-walk',
          'sender_id': 'demo-mu',
          'sender_name': '小木',
          'body': '这几天傍晚挺舒服的。我发现体育馆后面有一小段路，很安静。',
          'created_at': _at(55),
        },
      ],
    );
    addNotice(
      state,
      id: 'demo-notice-comment',
      userId: _demo,
      title: '有同学回复了你',
      body: '小木评论了你的动态。',
      targetType: 'post',
      targetId: 'demo-post-books',
    );
    addNotice(
      state,
      id: 'demo-notice-request',
      userId: _demo,
      title: '收到了同学的交流申请',
      targetType: 'chat_request',
      targetId: 'demo-chat-request',
    );
    state['social_seeded'] = true;
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
    if (segments.length > 3) return null;
    final id = segments.elementAtOrNull(1) ?? '';
    final action = segments.elementAtOrNull(2) ?? '';
    switch (segments.first) {
      case 'posts':
        return _posts(state, userId, method, id, action, query, body);
      case 'comments':
        final rows = _rows(state, 'comments');
        final mine = rows.where((row) => row['author_id'] == userId);
        if (method == 'GET' && id.isEmpty) {
          return _items(
            (mine.toList()..sort(_latest)).map((row) => _byAuthor(state, row)),
          );
        }
        if (method != 'DELETE' && method != 'PATCH') return null;
        final row = _require(mine, id);
        if (method == 'DELETE') {
          rows.remove(row);
          return {};
        }
        if (method == 'PATCH') {
          row['body'] = _body(body, 500);
          return _byAuthor(state, row);
        }
        return null;
      case 'people':
        if (method != 'GET' || id.isEmpty) return null;
        return {
          'id': id,
          'nickname': _name(state, id),
          'avatar_url': id == _demo
              ? text(data(state['profile']), 'avatar_url')
              : '',
          'blocked': _blocks(state, userId, id),
        };
      case 'blocks':
        return _block(state, userId, method, id);
      case 'reports':
        if (method != 'POST' || id.isNotEmpty) return null;
        final targetType = text(body, 'target_type');
        if (!{'post', 'comment', 'message'}.contains(targetType) ||
            text(body, 'target_id').isEmpty ||
            text(body, 'reason').trim().isEmpty) {
          throw const ApiError(400, 'invalid_input', '请提供举报对象和原因');
        }
        final row = {
          ...body,
          'id': newID(),
          'reporter_id': userId,
          'status': 'pending',
          'created_at': _at(),
        };
        _rows(state, 'reports').add(row);
        return {...row};
      case 'chat-requests':
        return _chatRequests(state, userId, method, id, action, body);
      case 'conversations':
        return _conversations(state, userId, method, id, action, query, body);
      case 'notifications':
        final mine = _rows(
          state,
          'notices',
        ).where((row) => row['user_id'] == userId);
        if (method == 'GET') {
          final work = query['scope'] == 'work';
          return _items(
            mine.where((row) => row['work'] == work).toList()..sort(_latest),
          );
        }
        if (method != 'POST') return null;
        if (id == 'read-all') {
          final work = body['scope'] == 'work';
          for (final row in mine.where((row) => row['work'] == work)) {
            row['read'] = true;
          }
        } else if (action == 'read') {
          _require(mine, id)['read'] = true;
        } else {
          return null;
        }
        return {};
    }
    return null;
  }

  static String _body(Data body, int limit) {
    final value = text(body, 'body').trim();
    if (value.isEmpty || value.runes.length > limit) {
      throw ApiError(400, 'invalid_input', '请输入 1–$limit 字的内容');
    }
    return value;
  }

  static Data? _posts(
    Data state,
    String user,
    String method,
    String id,
    String action,
    Map<String, String> query,
    Data body,
  ) {
    final rows = _rows(state, 'posts');
    final visible = rows.where(
      (row) => !_blocks(state, user, row['author_id']),
    );
    if (id.isEmpty && method == 'GET') {
      final author = query['author_id'];
      final sort = query['sort'];
      final items = visible
          .where((row) => author == null || row['author_id'] == author)
          .map((row) => _post(state, user, row))
          .toList();
      int score(Data row) => switch (sort) {
        'hot' => (row['resonances'] as int) + (row['comments'] as int) * 2,
        'resonance' => row['resonances'] as int,
        _ => 0,
      };
      items.sort((a, b) {
        final byScore = score(b).compareTo(score(a));
        return byScore == 0 ? _latest(a, b) : byScore;
      });
      return _items(items);
    }
    if (action.isEmpty && (id.isEmpty ? method == 'POST' : method == 'PATCH')) {
      final content = _body(body, 2000);
      final tags = (body['tags'] as List?)?.whereType<String>().toList() ?? [];
      if (tags.isEmpty || tags.length > 3) {
        throw const ApiError(400, 'invalid_input', '请选择 1–3 个情绪标签');
      }
      final row = id.isEmpty
          ? <String, dynamic>{
              'id': newID(),
              'author_id': user,
              'created_at': _at(),
            }
          : _require(visible.where((row) => row['author_id'] == user), id);
      row.addAll({
        'body': content,
        'tags': tags,
        'edited': id.isNotEmpty,
        'updated_at': _at(),
      });
      if (id.isEmpty) rows.add(row);
      return _post(state, user, row);
    }
    final row = _require(visible, id);
    final comments = _rows(state, 'comments');
    if (action == 'comments') {
      final onPost = comments.where(
        (comment) =>
            comment['post_id'] == id &&
            !_blocks(state, user, comment['author_id']),
      );
      if (method == 'GET')
        return _items(onPost.map((row) => _byAuthor(state, row)));
      if (method == 'POST') {
        final content = _body(body, 500);
        final parentId = text(body, 'parent_id');
        final parent = parentId.isEmpty ? null : _require(onPost, parentId);
        final comment = {
          'id': newID(),
          'post_id': id,
          'parent_id': parent?['parent_id'] ?? parent?['id'],
          'author_id': user,
          'body': content,
          'created_at': _at(),
        };
        comments.add(comment);
        final recipient = text(parent ?? row, 'author_id');
        if (recipient != user) {
          addNotice(
            state,
            userId: recipient,
            title: '有同学回复了你',
            targetType: 'post',
            targetId: id,
          );
        }
        return _byAuthor(state, comment);
      }
    }
    if (action == 'resonance' && method == 'PUT') {
      final users = (row['resonance_users'] ??= <String>[]) as List;
      if (body['active'] != true) {
        users.remove(user);
      } else if (!users.contains(user)) {
        users.add(user);
      }
      return _post(state, user, row);
    }
    if (action.isEmpty && method == 'DELETE') {
      if (row['author_id'] != user) {
        throw const ApiError(404, 'not_found', '动态已不存在');
      }
      rows.remove(row);
      comments.removeWhere((comment) => comment['post_id'] == id);
      return {};
    }
    return action.isEmpty && method == 'GET' ? _post(state, user, row) : null;
  }

  static Data? _block(Data state, String user, String method, String id) {
    final rows = _rows(state, 'blocks');
    final mine = rows.where((row) => row['owner_id'] == user);
    if (method == 'GET') return _items(mine.toList()..sort(_latest));
    if (method == 'DELETE') {
      rows.removeWhere((row) => row['owner_id'] == user && row['id'] == id);
      return {};
    }
    if (method != 'POST') return null;
    if (id == user || id.isEmpty) {
      throw const ApiError(400, 'invalid_input', '不能屏蔽自己');
    }
    if (_find(mine, id) == null) {
      rows.add({
        'owner_id': user,
        'id': id,
        'nickname': _name(state, id),
        'created_at': _at(),
      });
    }
    for (final row in _rows(state, 'requests')) {
      if (_pair(row, user, id) && row['status'] == 'pending') {
        row['status'] = 'rejected';
      }
    }
    return {};
  }

  static bool _pair(Data row, String one, String other) =>
      (row['sender_id'] == one && row['recipient_id'] == other) ||
      (row['sender_id'] == other && row['recipient_id'] == one);

  static bool _expired(Data row) =>
      DateTime.now().difference(DateTime.parse(text(row, 'created_at'))) >=
      const Duration(days: 7);

  static Data? _chatRequests(
    Data state,
    String user,
    String method,
    String id,
    String action,
    Data body,
  ) {
    final rows = _rows(state, 'requests');
    final mine = rows.where(
      (row) => row['sender_id'] == user || row['recipient_id'] == user,
    );
    if (method == 'GET') return _items(mine.toList()..sort(_latest));
    if (method != 'POST') return null;
    if (id.isEmpty) {
      final recipient = text(body, 'recipient_id');
      if (recipient == user || !_names.containsKey(recipient)) {
        throw const ApiError(400, 'invalid_input', '请选择另一位同学');
      }
      if (_blockedPair(state, user, recipient)) {
        throw const ApiError(403, 'forbidden', '暂时无法向这位同学发起申请');
      }
      final conversations = _rows(state, 'conversations');
      final existing = mine.where((row) => _pair(row, user, recipient)).toList()
        ..sort(_latest);
      for (final row in existing) {
        if (row['status'] == 'pending' && _expired(row))
          row['status'] = 'expired';
        final conversation = _find(conversations, text(row, 'conversation_id'));
        if (row['status'] == 'pending' ||
            row['status'] == 'rejected' && !_expired(row) ||
            conversation != null && conversation['closed'] != true) {
          throw const ApiError(409, 'stale', '已有会话或交流申请，请在消息中查看');
        }
      }
      final row = _requestRow(
        state,
        newID(),
        user,
        recipient,
        text(body, 'note').trim(),
      );
      rows.add(row);
      addNotice(
        state,
        userId: recipient,
        title: '收到了同学的交流申请',
        targetType: 'chat_request',
        targetId: text(row, 'id'),
      );
      return {...row};
    }
    if (action != 'accept' && action != 'reject') return null;
    final row = _require(mine.where((row) => row['recipient_id'] == user), id);
    if (row['status'] != 'pending' || _expired(row)) {
      throw const ApiError(409, 'stale', '这条申请已处理或已过期');
    }
    final sender = text(row, 'sender_id');
    if (action == 'accept') {
      if (_blockedPair(state, user, sender)) {
        throw const ApiError(403, 'forbidden', '暂时无法与这位同学交流');
      }
      final conversation = _peer(state, newID(), user, sender);
      row['status'] = 'accepted';
      row['conversation_id'] = conversation['id'];
    } else {
      row['status'] = 'rejected';
    }
    addNotice(
      state,
      userId: sender,
      title: '你的交流申请有新进展',
      targetType: 'chat_request',
      targetId: id,
    );
    return {...row};
  }

  static Data _conversation(Data state, Data row, String user) {
    final right = row['right_id'] == user;
    final other = text(row, right ? 'left_id' : 'right_id');
    final messages = (row['messages'] as List).cast<Data>();
    final lastRead = (row['last_read'] as Map)[user] as int? ?? 0;
    final closed = row['closed'] == true;
    return {
      'id': row['id'],
      'kind': row['kind'],
      'name': row[right ? 'left_name' : 'right_name'],
      'participant_id': other,
      'staff_role': row['staff_role'],
      'appointment_id': row['appointment_id'],
      'closed': closed,
      'read_only':
          closed || row['kind'] == 'peer' && _blockedPair(state, user, other),
      'unread': messages
          .skip(lastRead)
          .where((item) => item['sender_id'] != user)
          .length,
      'last_message': messages.isEmpty ? '' : messages.last['body'],
      'updated_at': row['updated_at'],
    };
  }

  static Data? _conversations(
    Data state,
    String user,
    String method,
    String id,
    String action,
    Map<String, String> query,
    Data body,
  ) {
    final mine = _rows(
      state,
      'conversations',
    ).where((row) => row['left_id'] == user || row['right_id'] == user);
    if (id.isEmpty && method == 'GET') {
      final work = query['scope'] == 'work';
      final rows =
          mine.where((row) {
            final onStaffSide =
                row['kind'] == 'care' && row['right_id'] == user;
            return work == onStaffSide;
          }).toList()..sort(
            (a, b) => text(b, 'updated_at').compareTo(text(a, 'updated_at')),
          );
      return _items(rows.map((row) => _conversation(state, row, user)));
    }
    final row = _require(mine, id);
    final details = _conversation(state, row, user);
    final messages = (row['messages'] as List).cast<Data>();
    if (action.isEmpty && method == 'GET') return details;
    if (action == 'messages' && method == 'GET') {
      final before = DateTime.tryParse(query['before'] ?? '');
      final limit = (int.tryParse(query['limit'] ?? '') ?? 30).clamp(1, 100);
      final recent = messages.reversed.where(
        (row) =>
            before == null ||
            DateTime.parse(text(row, 'created_at')).isBefore(before),
      );
      return _items(recent.take(limit).toList().reversed);
    }
    if (method != 'POST') return null;
    if (action == 'read') {
      (row['last_read'] as Map)[user] = messages.length;
      return {};
    }
    if (action == 'close' && row['kind'] == 'peer') {
      row['closed'] = true;
      return {};
    }
    if (action == 'messages') {
      final messageId = text(body, 'id', newID());
      final existing = _find(
        messages.where((item) => item['sender_id'] == user),
        messageId,
      );
      if (existing != null) return {...existing};
      if (details['read_only'] == true) {
        throw const ApiError(409, 'stale', '此会话已结束或暂不可发送');
      }
      final message = {
        'id': messageId,
        'sender_id': user,
        'sender_name': _name(state, user),
        'body': _body(body, 2000),
        'created_at': _at(),
      };
      messages.add(message);
      row['updated_at'] = message['created_at'];
      return {...message};
    }
    return null;
  }
}
