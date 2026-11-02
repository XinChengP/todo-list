import 'package:drift/drift.dart';

/// 任务表。列名与同步契约（server/schema.sql）逐字对齐。
///
/// 同步铁律（M3 起生效）：
/// - id 一律 UUIDv7，客户端生成，绝不用自增
/// - 删除只写 deleted_at 墓碑，永不物理删除
/// - 每次本地修改都要在 field_ts 里给被改字段盖时间戳，并置 dirty
///
/// 注：drift 2.35 起列构建器是 Table 的实例方法（integer()/text()/boolean()），
/// 不再是顶层函数。
class Tasks extends Table {
  @override
  Set<Column> get primaryKey => {id};

  TextColumn get id => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get listId => text().named('list_id').nullable()();
  IntColumn get dueAt => integer().named('due_at').nullable()();
  IntColumn get remindAt => integer().named('remind_at').nullable()();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  IntColumn get completedAt => integer().named('completed_at').nullable()();
  IntColumn get deletedAt => integer().named('deleted_at').nullable()();
  /// 周期规则单位：null = 不重复；day / week / month / year
  TextColumn get repeatUnit => text().named('repeat_unit').nullable()();
  /// 周期间隔（≥1）。仅 repeatUnit 非空时有意义
  IntColumn get repeatInterval => integer().named('repeat_interval').nullable()();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get updatedAt => integer().named('updated_at')();
  /// JSON：{ "字段名": 该字段最后一次写入的毫秒时间戳 }，与服务端 field_ts 同构
  TextColumn get fieldTs => text().named('field_ts').withDefault(const Constant('{}'))();
  /// 是否有未推送到服务器的本地修改
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
}

/// 清单/分类表（M5 出 UI，M1 先按契约建表）
class TaskLists extends Table {
  @override
  Set<Column> get primaryKey => {id};

  TextColumn get id => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  IntColumn get sortOrder => integer().named('sort_order').withDefault(const Constant(0))();
  IntColumn get deletedAt => integer().named('deleted_at').nullable()();
  IntColumn get createdAt => integer().named('created_at')();
  IntColumn get updatedAt => integer().named('updated_at')();
  TextColumn get fieldTs => text().named('field_ts').withDefault(const Constant('{}'))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
}

/// 键值配置（M3 存同步游标 / API 地址 / 令牌）
class Settings extends Table {
  @override
  Set<Column> get primaryKey => {key};

  TextColumn get key => text()();
  TextColumn get value => text()();
}
