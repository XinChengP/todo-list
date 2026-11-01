# 任务清单同步 API 接口文档

> 供其他自研产品接入任务清单数据使用。任何能发 HTTPS + JSON 的语言/平台都可接入，
> 无需 SDK。本文档对应线上版本 v1.0.5+（含字段级 LWW 与 at≥0 语义）。

## 基本信息

| 项 | 值 |
|---|---|
| 生产地址 | `https://todoapi.example.com` |
| 备用端口 | `2053` / `2083` / `2087` / `2096` / `8443`（HTTPS，同一证书，443 劣化时的备选） |
| 认证 | 请求头 `Authorization: Bearer <SYNC_TOKEN>` |
| 编码 | UTF-8 JSON |
| 存储 | Cloudflare D1（SQLite），字段级 Last-Write-Wins 冲突合并 |

鉴权失败返回 `401`；请求错误 `400`；服务端错误 `5xx`。
错误响应统一为 `{"ok": false, "error": "原因"}`。

## 数据模型

两张表，字段级独立时间戳（`at`，毫秒）：

**tasks**：`title`(string) / `notes`(string) / `list_id`(string?) / `due_at`(int?) /
`remind_at`(int?) / `priority`(int 0-3) / `completed_at`(int?) / `deleted_at`(int? 墓碑)

**lists**：`name`(string) / `sort_order`(int) / `deleted_at`(int? 墓碑)

铁律：
- `id` 用 UUIDv7（客户端生成）；`at = 0` 表示从未写入（永不获胜）
- 删除 = 写 `deleted_at` 增碑，永不物理删除
- 同字段两次写入，`at` 大者赢；平局服务器赢
- 客户端时钟不影响服务端判断，但会影响"谁的新鲜"——设备时钟尽量准确

## 接口

### GET /health

无鉴权。返回 `{"ok":true,"server_time":...}`，用于连通性探测。

### GET /v1/sync/pull?since=<游标>

拉取 `[since, now)` 内有变化的行（含墓碑）。首次传 `0`。

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://todoapi.example.com/v1/sync/pull?since=0"
```

响应：
```json
{
  "ok": true,
  "cursor": 1793548866361,
  "has_more": false,
  "server_time": 1793548866400,
  "tasks": [ { "id": "...", "created_at": 900, "updated_at": 1000,
               "fields": { "title": {"v":"买牛奶","at":1000}, ... } } ],
  "lists": []
}
```

- 客户端持久化 `cursor`，下次带上；`has_more=true` 时用返回的 `cursor` 续拉
- 游标回退了 2 秒冗余窗口（覆盖多端时钟偏差），重复拉到同一行是正常的，幂等合并即可

### POST /v1/sync/push

推送本地变更。body 只需带**有变化的字段**：

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"tasks":[{"id":"<uuidv7>","created_at":1730000000000,
        "fields":{"title":{"v":"新任务","at":1730000000000}}}],
       "lists":[]}' \
  "https://todoapi.example.com/v1/sync/push"
```

响应 `tasks`/`lists` 为每行的**服务器最终状态**——客户端必须用它覆盖本地
（包括输掉的写入），由此保证多端收敛。单次每表限 500 行，超出分批。

删除 = 推送 `{"deleted_at":{"v":<毫秒>,"at":<毫秒>}}`。

### GET /v1/export

全量导出（含墓碑），备份/调试用。

## 最小接入示例（任何语言）

一个只读同步客户端的核心循环：

```
1. 读取本地存储的 cursor（没有则 0）
2. GET /v1/sync/pull?since=cursor
3. 对每行按字段合并进本地存储（fields[f].at 大于本地该字段时间戳才覆盖）
4. 保存响应里的 cursor
5. 本地有未推送修改时，把修改字段包成 fields 发 POST /v1/sync/push，
   并用响应覆盖本地
```

## 已知限制

- 国内直连 Cloudflare 免费节点按时段波动，客户端建议实现重试 + 多端点回退
  （443 劣化时 2053/2083/2087/2096/8443 常存活）
- 墓碑永久保留（多端离线语义要求），个人规模无压力
- 服务器不做权限分级：一个令牌 = 全部数据读写
