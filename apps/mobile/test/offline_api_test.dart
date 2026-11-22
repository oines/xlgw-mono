import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spiritual_harbor/mock/offline_api.dart';
import 'package:spiritual_harbor/shared/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'offline account, avatar and resource filters survive a fresh API instance',
    () async {
      final old = OfflineHarborApi();
      await old.restore();
      final login = await old.post('/auth/offline');
      await old.remember(text(login, 'token'));
      expect(data(login['user'])['roles'], ['student', 'teacher', 'peer']);
      old.changeSpace('teacher');
      await old.patch('/me', {'nickname': '小海', 'theme': 'dark'});
      final avatar = await old.request('/avatars/me');
      final config = {...data(avatar['config']), 'preset': 'soft'};
      await old.put('/avatars/me', {
        'revision': avatar['revision'],
        'config': config,
      });

      final fresh = OfflineHarborApi();
      await fresh.restore();
      expect(fresh.token, text(login, 'token'));
      expect((await fresh.request('/me'))['nickname'], '小海');
      expect(
        data((await fresh.request('/avatars/me'))['config'])['preset'],
        'soft',
      );
      final articles = await fresh.list('/resources?kind=article');
      expect(articles, hasLength(1));
      expect(articles.single['kind'], 'article');
    },
  );

  test('offline posts and comments appear together and persist', () async {
    final api = OfflineHarborApi();
    await api.restore();
    final post = await api.post('/posts', {
      'body': '今天去操场走了一圈。',
      'tags': ['平静'],
    });
    final route = '/posts/${post['id']}';
    await api.post('$route/comments', {'body': '给自己一点时间。'});

    final fresh = OfflineHarborApi();
    await fresh.restore();
    expect((await fresh.request(route))['body'], '今天去操场走了一圈。');
    final comments = await fresh.list('$route/comments');
    expect(comments.single['body'], '给自己一点时间。');
  });

  test('offline AI replies stream and stay in local history', () async {
    final api = OfflineHarborApi();
    await api.restore();
    await api.post('/me/ai-consent', {'agreed': true});
    final conversation = await api.post('/ai/conversations');
    final route = '/ai/conversations/${conversation['id']}';
    final run = await api.post('$route/inputs', {
      'id': newID(),
      'text': '我想休息一会儿',
    });
    final events = await api.events(text(run, 'id')).toList();
    expect(data(events.last['run'])['status'], 'completed');
    expect(events.any((e) => text(e, 'text').isNotEmpty), isTrue);
    final fresh = OfflineHarborApi();
    await fresh.restore();
    final history = await fresh.list('$route/messages');
    expect(history.map((msg) => msg['role']), ['user', 'assistant']);
  });

  test(
    'offline booking and workspaces exercise their own appointment queues',
    () async {
      final api = OfflineHarborApi();
      await api.restore();
      final teacher = (await api.list('/staff?role=teacher')).single;
      final slots = await api.list('/slots?staff_id=${teacher['id']}');
      final booking = await api.post('/appointments', {
        'slot_id': slots.first['id'],
        'note': '想聊聊学习节奏',
      });
      expect(booking['status'], 'pending');
      expect(
        (await api.list(
          '/appointments',
        )).any((row) => row['id'] == booking['id']),
        isTrue,
      );

      api.changeSpace('teacher');
      final teacherQueue = await api.list('/appointments?scope=work');
      final assigned = teacherQueue.firstWhere(
        (row) => row['status'] == 'pending',
      );
      final confirmed = await api.post(
        '/appointments/${assigned['id']}/confirm',
      );
      expect(confirmed['status'], 'confirmed');
      expect(confirmed['conversation_id'], isNotEmpty);

      api.changeSpace('peer');
      final peerQueue = await api.list('/appointments?scope=work');
      expect(peerQueue, isNotEmpty);
      expect(peerQueue.every((row) => row['role'] == 'peer'), isTrue);
    },
  );
}
