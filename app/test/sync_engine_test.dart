import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/db/sync_fields.dart';
import 'package:todo_app/repo/task_repository.dart';
import 'package:todo_app/sync/api_client.dart';
import 'package:todo_app/sync/settings_repository.dart';
import 'package:todo_app/sync/sync_engine.dart';

// http.Response 默认 latin1 编码，中文响应体会抛异常；统一用 UTF-8 JSON 响应
http.Response resp(String body, int status) => http.Response(
    body, status,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  late AppDatabase db;
  late TaskRepository repo;
  late SettingsRepository settings;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TaskRepository(db);
    settings = SettingsRepository(db);
    engine = SyncEngine(db, settings);
  });
  tearDown(() async => db.close());

  const config = SyncConfig(baseUrl: 'http://test.local', token: 't');

  Map<String, dynamic> serverRow(String id, int updatedAt, Map<String, Map<String, dynamic>> fields) =>
      {'id': id, 'created_at': 900, 'updated_at': updatedAt, 'fields': fields};

  test('推送：payload 符合契约；响应用服务器最终状态覆盖本地并清除 dirty', () async {
    final t = await repo.add(title: '本地标题', notes: '备注A');
    http.Request? capturedPost;
    final pushResp = jsonEncode({
      'ok': true,
      'server_time': 5000,
      'tasks': [
        serverRow(t.id, 4000, {
          // 服务器赢的字段
          'title': {'v': '服务器标题', 'at': 4000},
          // 本地写入被服务器原样接受
          'notes': {'v': '备注A', 'at': FieldTs.parse(t.fieldTs)['notes']},
          'list_id': {'v': null, 'at': 0},
          'due_at': {'v': null, 'at': 0},
          'remind_at': {'v': null, 'at': 0},
          'priority': {'v': 0, 'at': FieldTs.parse(t.fieldTs)['priority']},
          'completed_at': {'v': null, 'at': 0},
          'deleted_at': {'v': null, 'at': 0},
        }),
      ],
      'lists': [],
    });
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        capturedPost = req;
        return resp(pushResp, 200);
      }
      // 推送后的增量拉取：空
      return resp(
          jsonEncode({'ok': true, 'cursor': 5000, 'has_more': false, 'tasks': [], 'lists': []}),
          200);
    });
    await engine.sync(config, client: client);

    // 校验推送 payload
    final body = jsonDecode(capturedPost!.body) as Map<String, dynamic>;
    final row = (body['tasks'] as List).first as Map<String, dynamic>;
    expect(row['id'], t.id);
    expect(((row['fields'] as Map)['title'] as Map)['v'], '本地标题');
    expect(((row['fields'] as Map)['title'] as Map)['at'], greaterThan(0));

    // 响应覆盖：标题变成服务器的，dirty 清零
    final after = await db.getTaskById(t.id);
    expect(after!.title, '服务器标题');
    expect(after.notes, '备注A');
    expect(after.dirty, isFalse);
    expect(FieldTs.parse(after.fieldTs)['title'], 4000);
  });

  test('无 dirty 行时不发起推送', () async {
    var postCalls = 0;
    final client = MockClient((req) async {
      if (req.method == 'POST') postCalls++;
      return resp(
          jsonEncode({'ok': true, 'cursor': 100, 'has_more': false, 'tasks': [], 'lists': []}),
          200);
    });
    await repo.add(title: '已同步过的'); // dirty=true，先推一次清掉
    // 第二次同步：没有新的 dirty
    await engine.sync(config, client: client);
    expect(postCalls, 1);
  });

  test('拉取：远端新行插入且不置 dirty，游标持久化', () async {
    final client = MockClient((req) async {
      expect(req.method, 'GET');
      expect(req.url.queryParameters['since'], '0');
      return resp(
        jsonEncode({
          'ok': true,
          'cursor': 7777,
          'has_more': false,
          'tasks': [
            serverRow('remote-1', 3000, {
              'title': {'v': '来自手机', 'at': 3000},
              'notes': {'v': '', 'at': 3000},
              'priority': {'v': 2, 'at': 3000},
              'list_id': {'v': null, 'at': 0},
              'due_at': {'v': null, 'at': 0},
              'remind_at': {'v': null, 'at': 0},
              'completed_at': {'v': null, 'at': 0},
              'deleted_at': {'v': null, 'at': 0},
            }),
          ],
          'lists': [],
        }),
        200,
      );
    });
    await engine.sync(config, client: client);

    final row = await db.getTaskById('remote-1');
    expect(row, isNotNull);
    expect(row!.title, '来自手机');
    expect(row.priority, 2);
    expect(row.dirty, isFalse);
    expect(await settings.get('sync_cursor'), '7777');
  });

  test('拉取合并：已同步行采纳服务器新字段，其余不动、保持 clean', () async {
    // 本地行已与服务器同步（dirty=false，字段时间戳即服务器时间戳）
    const id = 'merged-1';
    await db.into(db.tasks).insert(TasksCompanion.insert(
          id: id,
          createdAt: 900,
          updatedAt: 2000,
          title: const Value('原标题'),
          notes: const Value('旧备注'),
          priority: const Value(0),
          fieldTs: Value(FieldTs({'title': 1000, 'notes': 1000, 'priority': 1000}).encode()),
          dirty: const Value(false),
        ));

    final client = MockClient((req) async {
      expect(req.url.queryParameters['since'], '0');
      return resp(
        jsonEncode({
          'ok': true,
          'cursor': 9000,
          'has_more': false,
          'tasks': [
            serverRow(id, 3000, {
              // notes 比本地新 → 采纳
              'notes': {'v': '服务器备注', 'at': 3000},
              // title 与本地同时间戳 → 视为一致，不动
              'title': {'v': '原标题', 'at': 1000},
              'priority': {'v': 0, 'at': 1000},
              'list_id': {'v': null, 'at': 0},
              'due_at': {'v': null, 'at': 0},
              'remind_at': {'v': null, 'at': 0},
              'completed_at': {'v': null, 'at': 0},
              'deleted_at': {'v': null, 'at': 0},
            }),
          ],
          'lists': [],
        }),
        200,
      );
    });
    await engine.sync(config, client: client);

    final row = await db.getTaskById(id);
    expect(row!.title, '原标题');
    expect(row.notes, '服务器备注');
    expect(row.dirty, isFalse);
    final after = FieldTs.parse(row.fieldTs);
    expect(after['notes'], 3000);
    expect(after['title'], 1000);
    expect(row.updatedAt, 3000);
  });

  test('真实冲突：本地 dirty 字段被服务器更新的同名写入裁决（推送响应覆盖）', () async {
    final t = await repo.add(title: '本地编辑');
    final localTs = FieldTs.parse(t.fieldTs)['title'];
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        // 服务器上另一设备已写过更新的标题 → 本地输掉
        return resp(
          jsonEncode({
            'ok': true, 'server_time': 9999,
            'tasks': [serverRow(t.id, localTs + 1000, {
              'title': {'v': '另一设备的标题', 'at': localTs + 1000},
              'notes': {'v': '', 'at': 0},
              'priority': {'v': 0, 'at': 0},
              'list_id': {'v': null, 'at': 0},
              'due_at': {'v': null, 'at': 0},
              'remind_at': {'v': null, 'at': 0},
              'completed_at': {'v': null, 'at': 0},
              'deleted_at': {'v': null, 'at': 0},
            })],
            'lists': [],
          }),
          200,
        );
      }
      return resp(jsonEncode({'ok': true, 'cursor': 9999, 'has_more': false, 'tasks': [], 'lists': []}), 200);
    });
    await engine.sync(config, client: client);

    final row = await db.getTaskById(t.id);
    expect(row!.title, '另一设备的标题'); // LWW：较新的写入赢
    expect(row.dirty, isFalse);
  });

  test('拉取：远端软删除墓碑被采纳', () async {
    final t = await repo.add(title: '将被远端删除');
    final client = MockClient((req) async {
      return resp(
        jsonEncode({
          'ok': true,
          'cursor': 9500,
          'has_more': false,
          'tasks': [
            serverRow(t.id, 9500, {
              'title': {'v': '将被远端删除', 'at': 1000},
              'notes': {'v': '', 'at': 1000},
              'priority': {'v': 0, 'at': 1000},
              'completed_at': {'v': null, 'at': 0},
              'deleted_at': {'v': 9500, 'at': 9500},
              'list_id': {'v': null, 'at': 0},
              'due_at': {'v': null, 'at': 0},
              'remind_at': {'v': null, 'at': 0},
            }),
          ],
          'lists': [],
        }),
        200,
      );
    });
    await engine.sync(config, client: client);

    final row = await db.getTaskById(t.id);
    expect(row!.deletedAt, 9500);
    expect((await repo.watch().first).map((x) => x.id), isNot(contains(t.id)));
  });

  test('has_more 分页：循环拉取直到结束，游标取最后一页', () async {
    var page = 0;
    final client = MockClient((req) async {
      final since = req.url.queryParameters['since'];
      page++;
      if (page == 1) {
        expect(since, '0');
        return resp(
          jsonEncode({
            'ok': true, 'cursor': 100, 'has_more': true,
            'tasks': [serverRow('p1', 100, {'title': {'v': '第一页', 'at': 100}, 'notes': {'v': '', 'at': 0}, 'priority': {'v': 0, 'at': 0}, 'completed_at': {'v': null, 'at': 0}, 'deleted_at': {'v': null, 'at': 0}, 'list_id': {'v': null, 'at': 0}, 'due_at': {'v': null, 'at': 0}, 'remind_at': {'v': null, 'at': 0}})],
            'lists': [],
          }),
          200,
        );
      }
      expect(since, '100');
      return resp(
        jsonEncode({
          'ok': true, 'cursor': 200, 'has_more': false,
          'tasks': [serverRow('p2', 200, {'title': {'v': '第二页', 'at': 200}, 'notes': {'v': '', 'at': 0}, 'priority': {'v': 0, 'at': 0}, 'completed_at': {'v': null, 'at': 0}, 'deleted_at': {'v': null, 'at': 0}, 'list_id': {'v': null, 'at': 0}, 'due_at': {'v': null, 'at': 0}, 'remind_at': {'v': null, 'at': 0}})],
          'lists': [],
        }),
        200,
      );
    });
    await engine.sync(config, client: client);

    expect(await db.getTaskById('p1'), isNotNull);
    expect(await db.getTaskById('p2'), isNotNull);
    expect(await settings.get('sync_cursor'), '200');
  });

  test('清单同步：本地 list 推送后被服务器状态覆盖', () async {
    final now = nowMs();
    await db.into(db.taskLists).insert(TaskListsCompanion.insert(
          id: 'list-1',
          createdAt: now,
          updatedAt: now,
          name: const Value('家庭'),
          fieldTs: Value(FieldTs.empty.withWrites({'name': now, 'sort_order': now}).encode()),
          dirty: const Value(true),
        ));
    final client = MockClient((req) async {
      return resp(
        jsonEncode({
          'ok': true,
          'tasks': [],
          'lists': [
            serverRow('list-1', now + 10, {
              'name': {'v': '家庭（服务器）', 'at': now + 10},
              'sort_order': {'v': 0, 'at': now},
              'deleted_at': {'v': null, 'at': 0},
            }),
          ],
        }),
        200,
      );
    });
    await engine.sync(config, client: client);

    final row = await (db.select(db.taskLists)..where((l) => l.id.equals('list-1'))).getSingle();
    expect(row.name, '家庭（服务器）');
    expect(row.dirty, isFalse);
  });

  test('脏行超过 200 时自动分块推送，全部收敛', () async {
    final posts = <Map<String, dynamic>>[];
    for (var i = 0; i < 250; i++) {
      await db.into(db.tasks).insert(TasksCompanion.insert(
        id: 'chunk-task-$i',
        createdAt: 1000,
        updatedAt: 1000 + i,
        title: Value('任务$i'),
        fieldTs: Value(
            FieldTs({'title': 1000 + i, 'notes': 1000, 'priority': 1000}).encode()),
        dirty: const Value(true),
      ));
    }
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        posts.add(body);
        final tasks = (body['tasks'] as List).cast<Map>();
        return resp(
          jsonEncode({
            'ok': true,
            'server_time': 9999,
            'tasks': [
              for (final t in tasks)
                serverRow(t['id'] as String, 5000, {
                  'title': {'v': t['fields']['title']['v'], 'at': 5000},
                  'notes': {'v': '', 'at': 1000},
                  'priority': {'v': 0, 'at': 1000},
                  'list_id': {'v': null, 'at': 0},
                  'due_at': {'v': null, 'at': 0},
                  'remind_at': {'v': null, 'at': 0},
                  'completed_at': {'v': null, 'at': 0},
                  'deleted_at': {'v': null, 'at': 0},
                }),
            ],
            'lists': [],
          }),
          200,
        );
      }
      return resp(jsonEncode(
          {'ok': true, 'cursor': 9999, 'has_more': false, 'tasks': [], 'lists': []}),
          200);
    });
    await engine.sync(config, client: client);

    // 250 行 → 200 + 50 两批
    expect(posts.length, 2);
    expect((posts[0]['tasks'] as List).length, 200);
    expect((posts[1]['tasks'] as List).length, 50);
    // 全部行 dirty 清零（服务器响应覆盖）
    final left = await (db.select(db.tasks)..where((x) => x.dirty.equals(true))).get();
    expect(left, isEmpty);
  });
}
