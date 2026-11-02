import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Tasks, TaskLists, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  /// 测试用：注入内存数据库
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  /// 迁移：v1 → v2 增加周期任务两列（repeat_unit / repeat_interval）。
  /// 老库就地 ALTER，不动已有数据。
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(tasks, tasks.repeatUnit);
            await m.addColumn(tasks, tasks.repeatInterval);
          }
        },
      );

  /// 按 UUID 主键取单行（drift 对 TEXT 主键不生成 getTask 这类便捷方法）
  Future<Task?> getTaskById(String id) {
    return (select(tasks)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  static QueryExecutor _open() => driftDatabase(
        name: 'todo_app',
        native: const DriftNativeOptions(setup: _setupConnection),
      );

  /// 连接级 pragma（每条 SQLite 连接都要设一次）：
  /// - WAL：桌面卡片的原生接收器（另一个连接）与 App 同时写库时不互相阻塞，
  ///   写入 fsync 次数也更少（手机端更省电）
  /// - busy_timeout：并发写时等待，而不是直接抛 "database is locked"
  /// - synchronous=NORMAL：WAL 下仍然安全，写入更快（掉电最多丢最后一笔事务）
  static void _setupConnection(CommonDatabase db) {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA busy_timeout = 3000');
    db.execute('PRAGMA synchronous = NORMAL');
  }
}
