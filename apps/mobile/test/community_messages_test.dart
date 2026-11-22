import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spiritual_harbor/features/community.dart';
import 'package:spiritual_harbor/features/messages.dart';
import 'package:spiritual_harbor/shared/api.dart';
import 'package:spiritual_harbor/shared/design.dart';

const student = <String, dynamic>{'id': 'student-1', 'nickname': '小海'};
const timestamp = '2026-01-10T12:00:00Z';

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Widget host(Widget page) =>
    MaterialApp(theme: harborTheme(Brightness.light), home: page);

Data post({
  String body = '今天在学校散步',
  bool resonated = false,
  int resonances = 0,
}) => {
  'id': 'post-1',
  'author_id': 'student-2',
  'author_name': '同学甲',
  'body': body,
  'tags': ['平静'],
  'resonated': resonated,
  'resonances': resonances,
  'comments': 0,
  'created_at': timestamp,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'community filters topics and updates resonance from the server',
    (tester) async {
      final sorts = <String?>[];
      final toggles = <bool>[];
      final api = HarborApi(
        base: 'https://harbor.test',
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/posts' && request.method == 'GET') {
            final sort = request.url.queryParameters['sort'];
            sorts.add(sort);
            return jsonResponse({
              'items': [post(body: '最新的校园散步')],
            });
          }
          if (request.url.path == '/api/v1/posts/post-1/resonance' &&
              request.method == 'PUT') {
            final active = data(jsonDecode(request.body))['active'] as bool;
            toggles.add(active);
            return jsonResponse(
              post(
                body: '最新的校园散步',
                resonated: active,
                resonances: active ? 7 : 6,
              ),
            );
          }
          throw StateError(
            'Unexpected request ${request.method} ${request.url}',
          );
        }),
      );
      addTearDown(api.client.close);

      await tester.pumpWidget(host(CommunityPage(api, student)));
      await tester.pumpAndSettle();
      expect(find.text('最新的校园散步'), findsOneWidget);
      expect(find.text('平静'), findsOneWidget);

      await tester.tap(find.text('焦虑'));
      await tester.pumpAndSettle();
      expect(find.text('这个主题下暂时没有帖子'), findsOneWidget);
      await tester.tap(find.text('推荐'));
      await tester.pumpAndSettle();
      expect(sorts, ['latest']);
      expect(find.text('最新的校园散步'), findsOneWidget);

      await tester.tap(find.text('共鸣 0'));
      await tester.pumpAndSettle();
      expect(find.text('共鸣 7'), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      await tester.tap(find.text('共鸣 7'));
      await tester.pumpAndSettle();
      expect(toggles, [true, false]);
      expect(find.text('共鸣 6'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    },
  );

  testWidgets('plaza keeps anonymous posts and shows only I relate', (
    tester,
  ) async {
    final requests = <String>[];
    final plazaPost = {
      ...post(body: '此刻想慢一点', resonances: 17),
      'mode': 'resonance',
      'author_name': '示例署名',
      'comments': 9,
    };
    final api = HarborApi(
      base: 'https://harbor.test',
      client: MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' && request.url.path == '/api/v1/posts') {
          expect(request.url.queryParameters, {'mode': 'resonance'});
          return jsonResponse({
            'items': [plazaPost],
          });
        }
        if (request.method == 'PUT' &&
            request.url.path == '/api/v1/posts/post-1/resonance') {
          expect(data(jsonDecode(request.body)), {'active': true});
          return jsonResponse({...plazaPost, 'resonated': true});
        }
        throw StateError('Unexpected request ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.client.close);

    await tester.pumpWidget(
      host(CommunityPage(api, student, resonanceOnly: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('匿名同学'), findsOneWidget);
    expect(find.text('示例署名'), findsNothing);
    expect(find.text('共鸣 17'), findsNothing);
    expect(find.text('9 条回应'), findsNothing);
    expect(find.byTooltip('我的帖子'), findsNothing);
    await tester.tap(find.text('此刻想慢一点'));
    await tester.pumpAndSettle();
    expect(requests, ['GET /api/v1/posts']);
    await tester.tap(find.text('我也是'));
    await tester.pumpAndSettle();
    expect(requests.last, 'PUT /api/v1/posts/post-1/resonance');
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('removed community post has an explicit unavailable state', (
    tester,
  ) async {
    final api = HarborApi(
      base: 'https://harbor.test',
      client: MockClient(
        (request) async =>
            jsonResponse({'code': 'not_found', 'message': '内容不存在'}, 404),
      ),
    );
    addTearDown(api.client.close);
    await tester.pumpWidget(host(PostDetail(api, 'post-1', student)));
    await tester.pumpAndSettle();
    expect(find.text('内容已不可用'), findsOneWidget);
  });

  testWidgets('posting a comment refreshes the detail and the feed', (
    tester,
  ) async {
    const message = '谢谢你的分享';
    final comments = <Data>[];
    var feedLoads = 0;
    var detailLoads = 0;
    final api = HarborApi(
      base: 'https://harbor.test',
      client: MockClient((request) async {
        switch ((request.method, request.url.path)) {
          case ('GET', '/api/v1/posts'):
            feedLoads++;
            return jsonResponse({
              'items': [
                {...post(), 'comments': comments.length},
              ],
            });
          case ('GET', '/api/v1/posts/post-1'):
            detailLoads++;
            return jsonResponse({...post(), 'comments': comments.length});
          case ('GET', '/api/v1/posts/post-1/comments'):
            return jsonResponse({'items': comments});
          case ('POST', '/api/v1/posts/post-1/comments'):
            final body = data(jsonDecode(request.body));
            expect(body, {'body': message});
            final comment = <String, dynamic>{
              'id': 'comment-1',
              'author_id': student['id'],
              'author_name': student['nickname'],
              'body': body['body'],
              'created_at': timestamp,
            };
            comments.add(comment);
            return jsonResponse(comment);
        }
        throw StateError('Unexpected request ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.client.close);

    await tester.pumpWidget(host(CommunityPage(api, student)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天在学校散步'));
    await tester.pumpAndSettle();
    expect(find.text('还没有评论'), findsOneWidget);

    final input = find.byType(TextField);
    await tester.enterText(input, message);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();
    expect(comments, hasLength(1));
    expect(detailLoads, 2);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(find.text(message), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(feedLoads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed human message preserves its body and retries the same ID',
    (tester) async {
      const path = '/api/v1/conversations/chat-1';
      final attempts = <Data>[];
      final committed = <Data>[];
      final api = HarborApi(
        base: 'https://harbor.test',
        client: MockClient((request) async {
          if (request.url.path == path && request.method == 'GET') {
            return jsonResponse({
              'id': 'chat-1',
              'kind': 'peer',
              'participant_id': 'student-2',
              'name': '同学甲',
              'read_only': false,
              'unread': 0,
            });
          }
          if (request.url.path == '$path/messages') {
            if (request.method == 'GET') {
              return jsonResponse({'items': committed});
            }
            final message = data(jsonDecode(request.body));
            attempts.add(message);
            if (attempts.length == 1) {
              return jsonResponse({
                'code': 'temporary',
                'message': '暂时发不出去',
              }, 503);
            }
            final stored = {
              ...message,
              'sender_id': student['id'],
              'sender_name': student['nickname'],
              'created_at': timestamp,
            };
            committed.add(stored);
            return jsonResponse(stored);
          }
          throw StateError(
            'Unexpected request ${request.method} ${request.url}',
          );
        }),
      );
      addTearDown(api.client.close);
      await tester.pumpWidget(host(ChatPage(api, 'chat-1', user: student)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '放学后一起去图书馆吗？');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(find.text('放学后一起去图书馆吗？'), findsOneWidget);
      expect(attempts, hasLength(1));
      expect(find.text('暂时发不出去'), findsOneWidget);

      await tester.tap(find.text('暂时发不出去'));
      await tester.pumpAndSettle();
      expect(attempts, hasLength(2));
      expect(attempts.first['id'], isNotEmpty);
      expect(attempts.last, attempts.first);
      expect(find.text('暂时发不出去'), findsNothing);
      expect(find.text('放学后一起去图书馆吗？'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
