// 两张同步表的字段规格。协议层完全由这张表驱动，
// 以后加表/加字段只需要在这里登记，sync.ts 的逻辑不用动。

export interface FieldSpec {
  kind: 'text' | 'int'
  /** text 字段最大长度 */
  maxLen?: number
  /** notNull 字段收到 null 时落库为默认值（text→''，int→0） */
  notNull?: boolean
}

export interface TableSpec {
  fields: Record<string, FieldSpec>
}

export const TABLES: Record<string, TableSpec> = {
  tasks: {
    fields: {
      title: { kind: 'text', maxLen: 5000, notNull: true },
      notes: { kind: 'text', maxLen: 20000, notNull: true },
      list_id: { kind: 'text', maxLen: 64 },
      due_at: { kind: 'int' },
      remind_at: { kind: 'int' },
      priority: { kind: 'int', notNull: true },
      completed_at: { kind: 'int' },
      deleted_at: { kind: 'int' },
      // 周期任务：repeat_unit = day/week/month/year（null = 不重复），
      // repeat_interval = 间隔（≥1）。客户端完成后原地滚到下一次。
      repeat_unit: { kind: 'text', maxLen: 8 },
      repeat_interval: { kind: 'int' },
    },
  },
  lists: {
    fields: {
      name: { kind: 'text', maxLen: 200, notNull: true },
      sort_order: { kind: 'int', notNull: true },
      deleted_at: { kind: 'int' },
    },
  },
}

export const TABLE_NAMES = Object.keys(TABLES)

export const ID_RE = /^[A-Za-z0-9_-]{1,64}$/
export const MAX_PUSH_ROWS = 500
export const PULL_PAGE_SIZE = 1000
/** 拉取游标向前回退的冗余窗口，覆盖多端时钟的毫秒级偏差；重拉幂等无害 */
export const OVERLAP_MS = 2000
