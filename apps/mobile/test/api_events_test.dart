import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spiritual_harbor/shared/api.dart';

void main() {
  test(
    'SSE parses a full snapshot and subsequent delta across byte chunks',
    () async {
      final bytes = utf8.encode(
        ': heartbeat\r\n\r\n'
        'event: snapshot\r\n'
        'data: {"run":{"id":"run-1","status":"running"},\r\n'
        'data: "text":"我听见了","reset":true}\r\n\r\n'
        'event: delta\n'
        'data: {"text":"。","attempt_id":"attempt-1"}\n\n'
        'event: done\n'
        'data: {"run":{"id":"run-1","status":"completed"}}\n\n',
      );
      final client = MockClient.streaming((request, body) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/ai/runs/run-1/events');
        expect(request.headers['Accept'], 'text/event-stream');
        expect(request.headers['Authorization'], 'Bearer test-session');
        expect(await body.toBytes(), isEmpty);
        return http.StreamedResponse(
          Stream.fromIterable(bytes.map((byte) => [byte])),
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      });
      addTearDown(client.close);
      final api = HarborApi(client: client, base: 'https://harbor.test')
        ..token = 'test-session';

      final events = await api.events('run-1').toList();
      expect(events.map((event) => event['event']), [
        'snapshot',
        'delta',
        'done',
      ]);
      expect(events.first['text'], '我听见了');
      expect(events.first['reset'], isTrue);
      expect(events.first['run']['status'], 'running');
      expect(events[1]['text'], '。');
      expect(events[1]['attempt_id'], 'attempt-1');
      expect(events.last['run']['status'], 'completed');
    },
  );

  test('SSE reports authorization loss before emitting any data', () async {
    final client = MockClient(
      (_) async => http.Response(
        '{"code":"unauthorized","message":"登录已过期"}',
        401,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    addTearDown(client.close);
    var expired = 0;
    final api = HarborApi(client: client, base: 'https://harbor.test')
      ..token = 'expired-session'
      ..onUnauthorized = () => expired++;

    await expectLater(
      api.events('run-1'),
      emitsInOrder([
        emitsError(
          isA<ApiError>()
              .having((error) => error.status, 'status', 401)
              .having((error) => error.code, 'code', 'unauthorized'),
        ),
        emitsDone,
      ]),
    );
    expect(expired, 1);
  });
}
