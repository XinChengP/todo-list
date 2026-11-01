import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/db/sync_fields.dart';
import 'package:todo_app/repo/task_repository.dart';

Future<Task> _row(AppDatabase db, String id) async => (await db.getTaskById(id))!;

void main() {
  late AppDatabase db;
  late TaskRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TaskRepository(db);
  });
  tearDown(() async => db.close());

  test('新增任务：UUID 主键、dirty、字段时间戳齐全', () async {
    final t = await repo.add(title: '买牛奶');
    expect(t.id, isNotEmpty);
    expect(t.dirty, isTrue);
    final fts = FieldTs.parse(t.fieldTs);
    expect(fts['title'], greaterThan(0));
    expect(fts['notes'], greaterThan(0));
    expect(fts['priority'], greaterThan(0));
    expect(t.updatedAt, greaterThan(0));
  });

  test('带截止日期新建时 due_at 也盖时间戳', () async {
    final t = await repo.add(title: '交房租', dueAt: 1700000000000);
    final fts = FieldTs.parse(t.fieldTs);
    expect(fts['due_at'], greaterThan(0));
  });

  test('勾选完成只推进 completed_at 的时间戳，title 不受影响', () async {
    final t = await repo.add(title: 'A');
    final before = FieldTs.parse(t.fieldTs);
    await repo.setCompleted(t, done: true);

    final after = await _row(db, t.id);
    expect(after.completedAt, isNotNull);
    final fts = FieldTs.parse(after.fieldTs);
    expect(fts['completed_at'], greaterThan(before['completed_at']));
    expect(fts['title'], before['title']); // title 未被改动
  });

  test('取消完成也是一次写入（时间戳继续前进）', () async {
    final t = await repo.add(title: 'B');
    await repo.setCompleted(t, done: true);
    final doneRow = await _row(db, t.id);
    await repo.setCompleted(doneRow, done: false);

    final row = await _row(db, t.id);
    expect(row.completedAt, isNull);
    expect(FieldTs.parse(row.fieldTs)['completed_at'],
        greaterThan(FieldTs.parse(doneRow.fieldTs)['completed_at']));
  });

  test('软删除：行保留、deleted_at 有值、watch 不再返回', () async {
    final t = await repo.add(title: '要删的');
    await repo.delete(t);

    final row = await _row(db, t.id);
    expect(row.deletedAt, isNotNull);
    expect(row.dirty, isTrue);

    final visible = await repo.watch().first;
    expect(visible.map((x) => x.id), isNot(contains(t.id)));
  });

  test('筛选：active / done', () async {
    final a = await repo.add(title: '进行中');
    await repo.add(title: '已完成');
    await repo.setCompleted(a, done: true);

    final active = await repo.watch(filter: TaskFilter.active).first;
    expect(active, hasLength(1));
    expect(active.first.title, '已完成');

    final done = await repo.watch(filter: TaskFilter.done).first;
    expect(done, hasLength(1));
    expect(done.first.title, '进行中');
  });

  test('排序：优先级高在前，已完成沉底，截止日期早在前', () async {
    await repo.add(title: '低', priority: 1, dueAt: 1800000000000);
    await repo.add(title: '高', priority: 3, dueAt: 1800000000000);
    final lowDone = await repo.add(title: '低但已完成', priority: 3);
    await repo.setCompleted(lowDone, done: true);

    final all = await repo.watch().first;
    expect(all.map((x) => x.title).toList(), ['高', '低', '低但已完成']);
    expect(all.first.priority, 3);
    expect(all.last.completedAt, isNotNull);
  });

  test('编辑字段：单个字段盖时间戳、其余不动', () async {
    final t = await repo.add(title: '原标题', notes: '原备注');
    final before = FieldTs.parse(t.fieldTs);
    await repo.rename(t, '新标题');

    final row = await _row(db, t.id);
    expect(row.title, '新标题');
    expect(row.notes, '原备注');
    final fts = FieldTs.parse(row.fieldTs);
    expect(fts['title'], greaterThan(before['title']));
    expect(fts['notes'], before['notes']);
  });

  test('清除截止日期同样盖时间戳（LWW 语义）', () async {
    final t = await repo.add(title: 'C', dueAt: 1700000000000);
    final before = FieldTs.parse(t.fieldTs);
    await repo.setDue(t, null);

    final row = await _row(db, t.id);
    expect(row.dueAt, isNull);
    expect(FieldTs.parse(row.fieldTs)['due_at'], greaterThan(before['due_at']));
  });
}
