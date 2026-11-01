-- D1 建表脚本：本地  npm run db:init:local
--              远端  npm run db:init:remote
--
-- 同步设计铁律：
--   1. 主键一律 UUID（客户端生成），绝不用自增
--   2. 删除只做软删除（deleted_at 墓碑），永不物理删除
--   3. updated_at 由服务器维护 = 全部字段时间戳的最大值，是增量拉取游标的依据
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
