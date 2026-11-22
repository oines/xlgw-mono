import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../companion/editor.dart' show presetConfig;
import '../shared/api.dart';
import 'ai.dart';
import 'care.dart';
import 'social.dart';

class OfflineHarborApi extends HarborApi {
  OfflineHarborApi()
    : super(base: 'https://offline.invalid', client: _OfflineClient());

  static const _stateKey = 'harbor.offline.state.v1';
  static const _tokenKey = 'harbor.offline.session';
  static const _user = 'demo-user';
  static const _school = <String, dynamic>{
    'name': '心灵港湾',
    'location': '模拟校园心理支持中心',
    'timezone': 'Asia/Shanghai',
    'initialized': true,
    'registered_open': false,
  };

  final _ai = MockAi();
  final _care = MockCare();
  final _social = MockSocial();
  Future<SharedPreferences>? _opening;
  Future<void> _writes = Future.value();
  late Data _state;

  Future<SharedPreferences> _open() => _opening ??= _read();

  Future<SharedPreferences> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_stateKey);
    try {
      _state = saved == null ? {} : data(jsonDecode(saved));
    } on FormatException {
      _state = {};
    }
    if (_state.isEmpty) {
      _state = {
        'space': 'student',
        'profile': {
          'id': _user,
          'account': 'offline',
          'nickname': '林同学',
          'roles': ['student', 'teacher', 'peer'],
          'school': _school['name'],
          'theme': 'system',
          'motion': 'standard',
          'avatar_url': '',
        },
        'avatar': {'revision': 1, 'config': presetConfig('clear')},
        'offline_feedback': <Data>[],
      };
      MockAi.seed(_state);
      MockSocial.seed(_state);
      MockCare.seed(_state);
    }
    return prefs;
  }

  Future<void> _save(SharedPreferences prefs) {
    final snapshot = jsonEncode(_state);
    _writes = _writes.catchError((Object _) {}).then((_) async {
      await prefs.setString(_stateKey, snapshot);
    });
    return _writes;
  }

  void changeSpace(String space) {
    _state['space'] = space;
    // The mobile shell already persists the selected space in its preferences.
  }

  @override
  Future<void> restore() async {
    final prefs = await _open();
    token = prefs.getString(_tokenKey);
  }

  @override
  Future<void> remember(String? value) async {
    final prefs = await _open();
    token = value;
    if (value == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, value);
    }
  }

  @override
  Future<Data> request(
    String path, {
    String method = 'GET',
    Data? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final prefs = await _open();
    final uri = Uri.parse(path);
    final payload = body ?? <String, dynamic>{};
    final local = _profile(uri, method, payload);
    final result =
        local ??
        _ai.reply(
          _user,
          method,
          uri.pathSegments,
          uri.queryParameters,
          payload,
          _state,
        ) ??
        _care.reply(
          _user,
          method,
          uri.pathSegments,
          uri.queryParameters,
          payload,
          _state,
        ) ??
        _social.reply(
          _user,
          method,
          uri.pathSegments,
          uri.queryParameters,
          payload,
          _state,
        );
    if (result == null) {
      throw const ApiError(404, 'offline_route', '离线体验暂未提供这项操作。');
    }
    if (method != 'GET') await _save(prefs);
    return data(jsonDecode(jsonEncode(result)));
  }

  @override
  Stream<Data> events(String runId) async* {
    final prefs = await _open();
    yield* _ai.events(
      runId,
      _state,
      userId: _user,
      persist: () => _save(prefs),
    );
  }

  Data? _profile(Uri uri, String method, Data body) {
    switch (uri.path) {
      case '/school':
        return _school;
      case '/auth/offline':
        return {'token': 'offline-session', 'user': _state['profile']};
      case '/auth/logout':
        return {};
      case '/me':
        if (method == 'PATCH') {
          final current = data(_state['profile']);
          for (final key in ['nickname', 'theme', 'motion']) {
            if (body.containsKey(key)) current[key] = body[key];
          }
          _state['profile'] = current;
        }
        return data(_state['profile']);
      case '/me/password':
        throw const ApiError(400, 'offline_password', '离线体验无需密码。');
      case '/avatars/catalog':
        return {'version': 1, 'presets': presetsForOffline};
      case '/avatars/me':
        if (method == 'PUT') {
          final previous = data(_state['avatar']);
          if (body['revision'] != previous['revision']) {
            throw const ApiError(409, 'conflict', '请重新加载伙伴形象。');
          }
          _state['avatar'] = {
            'revision': (previous['revision'] as int) + 1,
            'config': data(body['config']),
          };
        }
        return data(_state['avatar']);
      case '/feedback':
        final feedback = _state['offline_feedback'] as List;
        if (method == 'POST') {
          final record = {
            'id': newID(),
            'body': text(body, 'body'),
            'category': text(body, 'category'),
            'status': 'pending',
            'created_at': DateTime.now().toIso8601String(),
          };
          feedback.insert(0, record);
          return record;
        }
        return {'items': feedback};
      case '/resources':
        final kind = uri.queryParameters['kind'] ?? '';
        const resources = [
          {
            'kind': 'support',
            'title': '校园心理支持',
            'body': '在「找人聊聊」可以查看模拟的老师、朋辈和可预约时段。',
          },
          {
            'kind': 'article',
            'title': '给自己五分钟',
            'body': '把注意力放在此刻。先放松肩膀，再选一件小事，让今天慢下来。',
          },
          {
            'kind': 'activity',
            'title': '周末校园散步',
            'body': '从图书馆门口集合，沿校园步道走一圈。此活动为本地体验示例。',
          },
          {
            'kind': 'announcement',
            'title': '关于离线体验',
            'body': '这里的资源、预约、消息和反馈仅用于体验，变更保存在这台设备。',
          },
        ];
        return {
          'items': resources
              .where((item) => kind.isEmpty || item['kind'] == kind)
              .toList(),
        };
      case '/companion/assets':
        return {};
      default:
        return null;
    }
  }

  static const presetsForOffline = ['clear', 'soft', 'poised'];
}

class _OfflineClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('Offline build cannot send HTTP requests');
  }
}
