// 同步核心：字段级 Last-Write-Wins
//
// 协议（M3 客户端按此实现，详见 README「同步协议」一节）：
//   推送行 = { id, created_at?, fields: { 字段: { v: 值, at: 该字段写入的本地时间戳 } } }
//   服务器对每个字段独立判定：at > 已存时间戳才接受，平局服务器赢
//   推送响应返回每一行的最终服务器状态，客户端必须以响应覆盖本地（幂等收敛）

import { OVERLAP_MS, PULL_PAGE_SIZE, TABLE_NAMES, TABLES } from './model'
import { HttpError } from './types'

type StoredRow = Record<string, unknown>
type FieldTs = Record<string, number>

export interface IncomingField {
  v?: unknown
  at?: unknown
}

export interface IncomingRow {
  id?: unknown
  created_at?: unknown
  fields?: unknown
}

function parseTs(raw: unknown): FieldTs {
  if (typeof raw !== 'string' || !raw) return {}
  try {
    const obj: unknown = JSON.parse(raw)
    if (!obj || typeof obj !== 'object') return {}
    const out: FieldTs = {}
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      if (typeof v === 'number' && Number.isFinite(v)) out[k] = v
    }
    return out
  } catch {
    return {}
  }
}

function maxOf(map: FieldTs): number {
  let m = 0
  for (const v of Object.values(map)) if (v > m) m = v
  return m
}

function validateValue(spec: { kind: 'text' | 'int'; maxLen?: number; notNull?: boolean }, v: unknown): string | number | null {
  if (spec.kind === 'text') {
    if (v == null) return spec.notNull ? '' : null
    if (typeof v !== 'string') throw new HttpError(400, '字段类型错误：应为字符串')
    if (v.length > (spec.maxLen ?? 10000)) throw new HttpError(400, `字段超长（上限 ${spec.maxLen} 字符）`)
    return v
  }
  if (v == null) return spec.notNull ? 0 : null
  if (typeof v !== 'number' || !Number.isInteger(v)) throw new HttpError(400, '字段类型错误：应为整数')
  return v
}

/** 把库里的行组装回协议行（fields 里带每个字段的当前值+时间戳） */
function assemble(row: StoredRow, table: string) {
  const cfg = TABLES[table].fields
  const ts = parseTs(row.field_ts)
  const fields: Record<string, { v: unknown; at: number }> = {}
  for (const f of Object.keys(cfg)) {
    fields[f] = { v: row[f] ?? null, at: ts[f] ?? 0 }
  }
  return { id: row.id, created_at: row.created_at, updated_at: row.updated_at, fields }
}

export async function pushTable(db: D1Database, table: string, rows: IncomingRow[]): Promise<unknown[]> {
  const cfg = TABLES[table].fields
  const out: unknown[] = []

  for (const row of rows) {
    const id = typeof row.id === 'string' ? row.id : ''
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) throw new HttpError(400, `非法 id：${JSON.stringify(row.id ?? null)}`)
    if (row.fields !== undefined && (typeof row.fields !== 'object' || row.fields === null || Array.isArray(row.fields))) {
      throw new HttpError(400, `行 ${id} 的 fields 必须是对象`)
    }

    const existing = (await db.prepare(`SELECT * FROM "${table}" WHERE id = ?1`).bind(id).first()) as StoredRow | null
    const storedTs: FieldTs = existing ? parseTs(existing.field_ts) : {}
    const newTs: FieldTs = { ...storedTs }

    // 逐字段判定写入资格
    const setCols: string[] = []
    const setVals: unknown[] = []
    const incoming = (row.fields ?? {}) as Record<string, IncomingField>
    for (const [f, inc] of Object.entries(incoming)) {
      const spec = cfg[f]
      if (!spec) throw new HttpError(400, `${table} 不存在字段 ${f}`)
      const at = Number(inc?.at)
      // at = 0 合法：表示该字段从未被写过（客户端初建行的可空字段），
      // 0 在 LWW 比较中永不获胜，无副作用
      if (!Number.isInteger(at) || at < 0) throw new HttpError(400, `行 ${id} 字段 ${f} 的时间戳非法`)
      if (existing && at <= (storedTs[f] ?? 0)) continue // 迟到的旧写入丢弃；平局服务器赢
      setCols.push(f)
      setVals.push(validateValue(spec, inc?.v))
      newTs[f] = at
    }

    const createdNum = Number(row.created_at)
    const created_at = existing
      ? Number(existing.created_at)
      : Number.isFinite(createdNum) && createdNum > 0
        ? Math.floor(createdNum)
        : Date.now()
    const updated_at = Math.max(existing ? Number(existing.updated_at) || 0 : created_at, maxOf(newTs), created_at)

    if (existing) {
      if (setCols.length === 0) {
        out.push(assemble(existing, table)) // 全部字段都输给了服务器已有状态
        continue
      }
      const sql = `UPDATE "${table}" SET ${setCols.map((c) => `"${c}" = ?`).join(', ')}, field_ts = ?, updated_at = ? WHERE id = ?`
      await db.prepare(sql).bind(...setVals, JSON.stringify(newTs), updated_at, id).run()
    } else {
      const cols = ['id', 'created_at', 'updated_at', 'field_ts', ...setCols]
      const sql = `INSERT INTO "${table}" (${cols.map((c) => `"${c}"`).join(', ')}) VALUES (${cols.map(() => '?').join(', ')})`
      await db.prepare(sql).bind(id, created_at, updated_at, JSON.stringify(newTs), ...setVals).run()
    }

    const final = (await db.prepare(`SELECT * FROM "${table}" WHERE id = ?1`).bind(id).first()) as StoredRow
    out.push(assemble(final, table))
  }

  return out
}

export async function pushAll(db: D1Database, body: Record<string, unknown>) {
  const result: Record<string, unknown> = { ok: true, server_time: Date.now() }
  for (const table of TABLE_NAMES) {
    const raw = body[table]
    if (raw === undefined || raw === null) {
      result[table] = []
      continue
    }
    if (!Array.isArray(raw)) throw new HttpError(400, `${table} 必须是数组`)
    if (raw.length > 500) throw new HttpError(400, `${table} 单次最多推送 500 行`)
    result[table] = await pushTable(db, table, raw as IncomingRow[])
  }
  return result
}

export async function pull(db: D1Database, since: number) {
  const upper = Date.now() // 上界：只返回 [since, upper) 的行，避免拉到快照之后才落库的行
  const body: Record<string, unknown> = { ok: true, server_time: upper, has_more: false }

  let hasMore = false
  let truncatedTs: number | null = null
  for (const table of TABLE_NAMES) {
    const { results } = await db
      .prepare(`SELECT * FROM "${table}" WHERE updated_at >= ?1 AND updated_at < ?2 ORDER BY updated_at ASC LIMIT ?3`)
      .bind(since, upper, PULL_PAGE_SIZE + 1)
      .all()
    let rows = results as unknown as StoredRow[]
    let truncated = false
    if (rows.length > PULL_PAGE_SIZE) {
      truncated = true
      hasMore = true
      rows = rows.slice(0, PULL_PAGE_SIZE)
    }
    if (truncated && rows.length) {
      const t = Number(rows[rows.length - 1].updated_at) || 0
      truncatedTs = truncatedTs === null ? t : Math.min(truncatedTs, t)
    }
    body[table] = rows.map((r) => assemble(r, table))
  }

  // 截断时游标退回本页最后一行（>= 语义续拉，重拉幂等）；
  // 正常结束游标回退 2 秒冗余，覆盖多端时钟偏差
  body.cursor = hasMore ? (truncatedTs ?? since) : upper - OVERLAP_MS
  body.has_more = hasMore
  return body
}

/** 全量导出（备份/调试用），无游标语义 */
export async function exportAll(db: D1Database) {
  const out: Record<string, unknown> = { ok: true, exported_at: Date.now() }
  for (const table of TABLE_NAMES) {
    const { results } = await db.prepare(`SELECT * FROM "${table}"`).all()
    out[table] = (results as unknown as StoredRow[]).map((r) => assemble(r, table))
  }
  return out
}

/**
 * 一次往返完成「推送 + 拉取」，客户端省掉一个 RTT（弱网/移动网络下收益最明显）。
 *
 * 语义与分开调用完全一致，且两步都幂等：
 *   1. 先按字段级 LWW 仲裁推送行，返回每行最终服务器状态（客户端必须覆盖本地）
 *   2. 再按游标拉 [since, upper) 增量，返回 cursor / has_more
 */
export async function syncCombined(db: D1Database, body: Record<string, unknown>, since: number) {
  const pushed = await pushAll(db, body)
  const pulled = await pull(db, since)
  return {
    ok: true,
    server_time: pulled.server_time,
    // 推送裁决结果（与 /v1/sync/push 响应同构）
    tasks: pushed.tasks ?? [],
    lists: pushed.lists ?? [],
    // 增量拉取结果（与 /v1/sync/pull 响应同构）
    pull: {
      tasks: pulled.tasks ?? [],
      lists: pulled.lists ?? [],
      cursor: pulled.cursor,
      has_more: pulled.has_more === true,
    },
  }
}

