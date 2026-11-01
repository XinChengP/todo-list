import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Tasks, TaskLists, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  /// 测试用：注入内存数据库
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  /// 按 UUID 主键取单行（drift 对 TEXT 主键不生成 getTask 这类便捷方法）
  Future<Task?> getTaskById(String id) {
    return (select(tasks)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  static QueryExecutor _open() => driftDatabase(name: 'todo_app');
}
