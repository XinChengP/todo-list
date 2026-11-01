import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:todo_app/sync/api_client.dart';

// http.Response 默认 latin1 编码，中文响应体会抛异常；统一用 UTF-8 JSON 响应
http.Response resp(String body, int status) => http.Response(
    body, status,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  const config = SyncConfig(baseUrl: 'http://test.local', token: 'secret-token');

  test('网络抖动：500 一次后重试成功', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls == 1) {
        return resp('{"ok":false,"error":"boom"}', 500);
      }
      return resp('{"ok":true}', 200);
    });
    final api = ApiClient(config: config, client: client, retries: 3);

    final pulled = await api.getJson('/v1/sync/pull?since=0');
    expect(pulled['ok'], isTrue);
    expect(calls, 2);
  });

  test('重试耗尽后抛 SyncNetworkException', () async {
    final client = MockClient((req) async => resp('{"error":"down"}', 503));
    final api = ApiClient(config: config, client: client, retries: 2);

    await expectLater(
      api.getJson('/v1/health'),
      throwsA(isA<SyncNetworkException>()),
    );
  });

  test('401 立即抛 SyncAuthException 且不重试', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return resp('{"ok":false,"error":"令牌无效"}', 401);
    });
    final api = ApiClient(config: config, client: client);

    await expectLater(
      api.getJson('/v1/sync/pull?since=0'),
      throwsA(isA<SyncAuthException>()),
    );
    expect(calls, 1);
  });

  test('4xx 立即抛 SyncRequestException 且不重试', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return resp('{"ok":false,"error":"bad request"}', 400);
    });
    final api = ApiClient(config: config, client: client);

    await expectLater(
      api.postJson('/v1/sync/push', {'tasks': []}),
      throwsA(isA<SyncRequestException>()),
    );
    expect(calls, 1);
  });

  test('请求带 Bearer 头且 POST body 为契约 JSON', () async {
    http.Request? captured;
    final client = MockClient((req) async {
      captured = req;
      return resp('{"ok":true}', 200);
    });
    final api = ApiClient(config: config, client: client);

    await api.postJson('/v1/sync/push', {'tasks': [1, 2]});
    expect(captured!.headers['Authorization'], 'Bearer secret-token');
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect((body['tasks'] as List), hasLength(2));
  });
}
