# todo-sync-api

任务清单的同步后端：Cloudflare Workers + D1（SQLite），Hono 路由。
为 Flutter 双端（Windows / Android）客户端提供字段级 Last-Write-Wins 的增量同步。

## 目录结构

```
server/
├── wrangler.jsonc      # Workers 配置（D1 绑定、域名路由）
├── schema.sql          # D1 建表脚本
├── .dev.vars           # 本地开发令牌（已 gitignore）
├── src/
│   ├── index.ts        # Hono 入口：路由 + Bearer 鉴权
│   ├── sync.ts         # 同步核心：push/pull/export
│   ├── model.ts        # 表/字段规格（加字段只改这里）
│   └── types.ts
└── scripts/smoke.sh    # 协议冒烟测试（同时是协议的活文档）
```

## 本地开发

```bash
npm install
npm run db:init:local     # 初始化本地 D1
npm run dev               # http://127.0.0.1:7777
npm run smoke             # 另开终端跑冒烟测试
```

> 注：默认用 7777 端口。Windows 上 8787 常落在 Hyper-V/WSL 的保留端口段
> （可用 `netsh interface ipv4 show excludedportrange protocol=tcp` 查看），绑定会莫名失败。
```

## 部署 Runbook（一次性）

> **✅ 已于 2026-10-31 完成部署：**
> - 线上地址：`https://todoapi.example.com`（Cloudflare Workers 自定义域名，证书自动）
> - D1 数据库：`todo-db`（id `9b55427e-d432-4617-a6d5-1e07b584bd73`）
> - 同步令牌：本目录 `.sync-token` 文件（已 gitignore；App 里填的就是它）
> - 远端冒烟 12/12 通过；国内直连 CF 偶发 SSL 抖动，客户端必须带重试（冒烟脚本已内置 `--retry`）

前提：域名 DNS 已托管到 Cloudflare（免费计划即可，改 NS 即可，无需转注册商）。

```bash
npx wrangler login                          # 浏览器授权
npx wrangler d1 create todo-db              # 把输出的 database_id 填进 wrangler.jsonc
npm run db:init:remote                      # 远端建表
npx wrangler secret put SYNC_TOKEN          # 粘贴强随机令牌（openssl rand -hex 24）
                                            # 这个令牌就是以后 App 里要填的同步密钥
npx wrangler deploy
```

绑定自有域名（二选一）：

- **Dashboard**：Workers & Pages → todo-sync-api → Settings → Domains & Routes →
  Add → Custom Domain → 填 `todo-api.你的域名.com`
- **配置文件**：取消 `wrangler.jsonc` 里 `routes` 的注释并改成你的子域名，再 `npx wrangler deploy`

验证：

```bash
curl https://todo-api.你的域名.com/health
bash scripts/smoke.sh https://todo-api.你的域名.com <你的SYNC_TOKEN>
```

## 同步协议（M3 客户端实现契约）

所有接口走 HTTPS + `Authorization: Bearer <SYNC_TOKEN>`。

### 数据行格式

```json
{
  "id": "0193aa11-uuid",          // 客户端生成的 UUID，主键
  "created_at": 1730000000000,    // 仅首次创建时采纳
  "fields": {
    "title":        { "v": "买牛奶", "at": 1730000001000 },
    "due_at":       { "v": null,     "at": 1730000001000 },
    "deleted_at":   { "v": null,     "at": 0 }
  },
  "updated_at": 1730000005000     // 服务器维护，响应中返回
}
```

可同步字段：

- `tasks`：title, notes, list_id, due_at, remind_at, priority, completed_at, deleted_at
- `lists`：name, sort_order, deleted_at

### GET /v1/sync/pull?since=<游标>

返回 `[since, now)` 内 `updated_at` 命中的行（含软删除墓碑），按 `updated_at` 升序。
响应：`{ ok, cursor, has_more, server_time, tasks: [...], lists: [...] }`

- 客户端持久化 `cursor`，下次带来；首次传 0
- `has_more=true` 时用返回的 `cursor` 继续拉（它已退回本页最后一行）
- 正常结束时 `cursor` 回退了 2 秒冗余窗口，覆盖多端时钟毫秒级偏差；重拉幂等无害
- 单表单页上限 1000 行（个人规模基本触不到）

### POST /v1/sync/push

请求体：`{ "tasks": [数据行...], "lists": [数据行...] }`（单表单次最多 500 行）

服务器逐字段判定：`at > 库里该字段的时间戳` 才接受（**平局服务器赢**），
被丢弃的字段不影响其他字段 —— 这就是字段级 LWW：
手机改的标题和电脑勾的完成状态可以同时存活。

响应：`{ ok, server_time, tasks: [最终状态...], lists: [最终状态...] }`

**客户端铁律：推送后必须用响应里的行覆盖本地对应行（含输掉的写入），
本地状态由此与服务器收敛，不会反复推送同一冲突。**

### GET /v1/export

全量导出（备份/调试），格式同 pull 但无游标语义。

## 设计注记

- 删除 = 写 `deleted_at` 墓碑，永不物理删除（GC 是将来的事）
- 冲突判定以字段时间戳为准，客户端时钟只影响"谁赢"，不影响一致性
  —— 最终状态由服务器仲裁并回发，多端必然收敛
- 每行推送 = SELECT + 写 + SELECT 共 3 次查询；个人规模（几百行）毫无压力，
  将来有需要可换 `db.batch()` 批量优化
- 同步时机建议：App 启动 / 下拉刷新 / 桌面端每 15 分钟定时器（见 M3/M4）
