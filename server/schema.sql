-- D1 建表脚本：本地  npm run db:init:local
--              远端  npm run db:init:remote
--
-- 同步设计铁律：
--   1. 主键一律 UUID（客户端生成），绝不用自增
--   2. 删除只做软删除（deleted_at 墓碑），永不物理删除
--   3. updated_at 由服务器维护 = **服务器实际接收这次写入的时刻**（单调不减），
--      是增量拉取游标的唯一依据。绝不能用客户端时间戳来算：
--      field_ts 才是 LWW 判定依据，两者混用会让"创建后延迟推送"的行
--      落在其他端已推进的游标之前，导致该记录永久拉不到。
--   4. field_ts 是 JSON 列：{ "字段名": 该字段最后一次被接受写入的时间戳 }
--      冲突判定按字段做 Last-Write-Wins，粒度到字段而不是整行

CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY,
  title        TEXT NOT NULL DEFAULT '',
  notes        TEXT NOT NULL DEFAULT '',
  list_id      TEXT,
  due_at       INTEGER,
  remind_at    INTEGER,
  priority     INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  deleted_at   INTEGER,
  repeat_unit      TEXT,
  repeat_interval  INTEGER,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  field_ts     TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_tasks_updated ON tasks(updated_at);
CREATE INDEX IF NOT EXISTS idx_tasks_list    ON tasks(list_id);

CREATE TABLE IF NOT EXISTS lists (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  field_ts   TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_lists_updated ON lists(updated_at);
