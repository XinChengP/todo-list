import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { exportAll, pull, pushAll, syncCombined } from './sync'
import { HttpError, type Env } from './types'

const app = new Hono<{ Bindings: Env }>()

/**
 * 服务端版本：与客户端解耦，独立语义化。
 * 每次 deploy 前 bump，部署后用 `curl /health` 核对——
 * 靠这个字段才能确认"线上跑的到底是哪一版"（踩过这个坑）。
 */
const SERVER_VERSION = '1.3.0'

// 原生 App 不受 CORS 约束，这里放开以便将来复用（鉴权由令牌兜底，无风险）
app.use('*', cors())

app.onError((err, c) => {
  if (err instanceof HttpError) return c.json({ ok: false, error: err.message }, err.status as 400)
  console.error(err)
  return c.json({ ok: false, error: 'internal error' }, 500)
})

// 健康检查无需鉴权（可用作域名绑定后的连通性探针）
app.get('/health', (c) =>
  c.json({ ok: true, version: SERVER_VERSION, server_time: Date.now() }),
)

// 根路径：浏览器直接打开域名时能看到的可读状态页（404 会让人误以为服务挂了）
app.get('/', (c) => {
  const now = new Date().toISOString()
  return c.html(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>任务清单 · 同步服务</title></head>
<body style="font-family:system-ui,sans-serif;max-width:560px;margin:60px auto;padding:0 16px;color:#202a35">
  <h1>✅ 任务清单同步服务运行中</h1>
  <p>服务器时间：${now}　版本：v${SERVER_VERSION}</p>
  <ul>
    <li><a href="/health">/health</a> — 健康检查（JSON）</li>
    <li>/v1/sync · /v1/sync/pull · /v1/sync/push · /v1/export — 同步接口（需令牌）</li>
  </ul>
  <p style="color:#667">手机浏览器打开本页能看到这个 ✅，说明该设备的网络可以连通服务。</p>
</body></html>`)
})

// 未匹配路径：JSON 404（保持 API 一致性），并提示可用路径
app.notFound((c) =>
  c.json({ ok: false, error: 'not found', hint: '可用路径：/health、/v1/sync、/v1/sync/pull、/v1/sync/push、/v1/export' }, 404),
)

/** 恒时比较，避免令牌校验的时序侧信道 */
function timingSafeEqualStr(a: string, b: string): boolean {
  const enc = new TextEncoder()
  const ab = enc.encode(a)
  const bb = enc.encode(b)
  const n = Math.max(ab.length, bb.length)
  let diff = ab.length ^ bb.length
  for (let i = 0; i < n; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0)
  return diff === 0
}

app.use('/v1/*', async (c, next) => {
  const token = (c.req.header('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  const expected = c.env.SYNC_TOKEN
  if (!expected) throw new HttpError(500, '服务端未配置 SYNC_TOKEN（wrangler secret put SYNC_TOKEN）')
  if (!token || !timingSafeEqualStr(token, expected)) throw new HttpError(401, '令牌无效')
  await next()
})

app.get('/v1/sync/pull', async (c) => {
  const since = Number(c.req.query('since') ?? '0')
  if (!Number.isFinite(since) || since < 0) throw new HttpError(400, 'since 必须是非负数字')
  return c.json(await pull(c.env.DB, Math.floor(since)))
})

app.post('/v1/sync/push', async (c) => {
  const body: unknown = await c.req.json().catch(() => null)
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, '请求体必须是 JSON 对象')
  return c.json(await pushAll(c.env.DB, body as Record<string, unknown>))
})

/**
 * 一次往返完成推送 + 拉取（客户端首选路径）。
 * 请求体：{ since, cursor?, tasks?, lists? }（字段与 /v1/sync/push 相同，另加 since）
 * 响应：{ ok, server_time, tasks, lists, pull: { tasks, lists, cursor, has_more } }
 */
app.post('/v1/sync', async (c) => {
  const body: unknown = await c.req.json().catch(() => null)
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, '请求体必须是 JSON 对象')
  const obj = body as Record<string, unknown>
  const since = Number(obj.since ?? 0)
  if (!Number.isFinite(since) || since < 0) throw new HttpError(400, 'since 必须是非负数字')
  return c.json(await syncCombined(c.env.DB, obj, Math.floor(since)))
})

app.get('/v1/export', async (c) => c.json(await exportAll(c.env.DB)))

export default app
