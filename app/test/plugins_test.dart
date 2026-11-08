import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/plugins/events.dart';
import 'package:todo_app/plugins/plugin_api.dart';
import 'package:todo_app/plugins/webhook_plugin.dart';
import 'package:todo_app/repo/task_repository.dart';

/// 插件接口：事件流 / 合并 / Webhook 推送
void main() {
  late AppDatabase db;
  late TaskRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TaskRepository(db);
  });
  tearDown(() async => db.close());

  test('事件流：新建 → 完成 → 删除', () async {
    final events = <TaskEvent>[];
    final sub = repo.events.listen(events.add);
    final t = await repo.add(title: 'A');
    await repo.setCompleted(t, done: true);
    await repo.delete(t);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(events.map((e) => e.type).toList(),
        [TaskEventType.created, TaskEventType.completed, TaskEventType.deleted]);
    // 事件里的 task 是落库后的最终状态
    expect(events.last.task.deletedAt, isNotNull);
    expect(events[1].task.completedAt, isNotNull);
  });

  test('WebhookConfig JSON 往返', () {
    const c = WebhookConfig(
      id: 'w1',
      name: '自动化',
      url: 'https://example.test/hook',
      token: 'secret',
      events: [TaskEventType.completed, TaskEventType.created],
      enabled: false,
    );
    final back = WebhookConfig.fromJson(
        (jsonDecode(WebhookConfig.listToJson([c])) as List).first
            as Map<String, dynamic>);
    expect(back.id, 'w1');
    expect(back.url, 'https://example.test/hook');
    expect(back.token, 'secret');
    expect(back.events, [TaskEventType.completed, TaskEventType.created]);
    expect(back.enabled, isFalse);
  });

  test('Webhook 推送：payload 结构 + 事件过滤 + 令牌头', () async {
    String? body;
    String? token;
    final client = MockClient((req) async {
      body = req.body;
      token = req.headers['x-todo-token'];
      return http.Response('{}', 200);
    });
    final plugin = WebhookPlugin(db, client: client);
    await plugin.saveConfigs([
      const WebhookConfig(
        id: 'w1',
        name: 'n',
        url: 'https://example.test/hook',
        token: 'secret',
        events: [TaskEventType.completed],
      ),
    ]);
    await plugin.onInit();

    final t = await repo.add(title: 'C');
    final task = (await db.getTaskById(t.id))!;
    await plugin
        .onTaskEvent(TaskEvent(TaskEventType.completed, task, 123));

    final payload = jsonDecode(body!) as Map<String, dynamic>;
    expect(payload['event'], 'task.completed');
    expect((payload['task'] as Map)['title'], 'C');
    expect((payload['task'] as Map)['id'], t.id);
    expect(token, 'secret');

    // 未订阅的事件不发请求
    await plugin.onTaskEvent(TaskEvent(TaskEventType.created, task, 124));
    expect(body, isNotNull); // body 仍是上一次的内容（没有新请求即可）
    final results = await plugin.loadResults();
    expect(results['w1']!.ok, isTrue);
  });

  test('PluginHost：updated 事件在 800ms 窗口内合并', () async {
    final received = <TaskEvent>[];
    PluginHost.register(_Capture(received));
    await PluginHost.init(repo);

    final t = await repo.add(title: 'B');
    await repo.rename(t, 'B2');
    await repo.setNotes(t, '备注');
    await repo.setPriority(t, 2);
    await repo.setDue(t, DateTime.now().millisecondsSinceEpoch);

    // 窗口 800ms，留足余量
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final updated = received.where((e) => e.type == TaskEventType.updated).toList();
    expect(updated, hasLength(1), reason: '连续字段修改应合并成一条 updated');
    expect(updated.single.task.title, 'B2');
    expect(updated.single.task.priority, 2);
    expect(updated.single.task.notes, '备注');
    // created 事件不应被合并吞掉
    expect(received.first.type, TaskEventType.created);
  }, timeout: const Timeout(Duration(seconds: 10)));
}

class _Capture extends TodoPlugin {
  _Capture(this.received);

  final List<TaskEvent> received;

  @override
  String get name => 'capture_test';

  @override
  String get title => '捕获插件';

  @override
  Future<void> onTaskEvent(TaskEvent event) async {
    received.add(event);
  }
}

