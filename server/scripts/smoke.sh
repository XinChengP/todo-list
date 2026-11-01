#!/usr/bin/env bash
# 同步协议冒烟测试：验证 push/pull、字段级 LWW、软删除墓碑、游标语义、鉴权
# 用法: bash scripts/smoke.sh <BASE_URL> <TOKEN>
#   本地: bash scripts/smoke.sh http://127.0.0.1:7777 dev-local-token
#   远端: bash scripts/smoke.sh https://todo-api.example.com <你的SYNC_TOKEN>
#
# 注意：JSON payload 一律经临时文件传递（--data-binary @file），
#       不要用命令行内联中文——Windows 下 argv 编码转换会损坏非 ASCII 字符。
set -euo pipefail

BASE="${1:?用法: smoke.sh <BASE_URL> <TOKEN>}"
TOKEN="${2:?用法: smoke.sh <BASE_URL> <TOKEN>}"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

step() { printf '\n===== %s =====\n' "$*"; }
P()    { printf '%s' "$1" > "$TMP_JSON"; }
# 国内直连 Cloudflare 偶发 SSL 握手抖动：统一带重试与单请求超时
CURL=(curl -sS --retry 4 --retry-all-errors --retry-delay 2 -m 30)
do_push() { "${CURL[@]}" "${AUTH[@]}" -X POST "$BASE/v1/sync/push" --data-binary @"$TMP_JSON"; echo; }
do_pull() { "${CURL[@]}" "${AUTH[@]}" "$BASE/v1/sync/pull?since=$1"; echo; }
code()   { "${CURL[@]}" -o /dev/null -w '%{http_code}\n' "$@"; }

step "1. 健康检查（无需令牌）"
"${CURL[@]}" "$BASE/health"; echo

step "2. 无令牌访问应 401"
code "$BASE/v1/sync/pull?since=0"

step "3. 错误令牌应 401"
code -H "Authorization: Bearer wrong-token" "$BASE/v1/sync/pull?since=0"

step "4. 空库全量拉取（tasks/lists 应为空数组）"
do_pull 0

step "5. 首次推送：手机端 t=1000 建任务A + 建清单[家庭]"
P '{"tasks":[{"id":"smoke-task-0001","created_at":900,"fields":{"title":{"v":"买牛奶","at":1000},"completed_at":{"v":null,"at":1000}}}],"lists":[{"id":"smoke-list-home","created_at":900,"fields":{"name":{"v":"家庭","at":1000},"sort_order":{"v":0,"at":1000}}}]}'
do_push

step "6. 电脑端 t=2000 改 title+notes（应全部生效）"
P '{"tasks":[{"id":"smoke-task-0001","fields":{"title":{"v":"买豆奶","at":2000},"notes":{"v":"低脂","at":2000}}}],"lists":[]}'
do_push

step "7. 字段级合并关键用例：手机端迟到编辑 title(t=1500,应丢弃) + 完成任务(t=3000,应生效)"
P '{"tasks":[{"id":"smoke-task-0001","fields":{"title":{"v":"过时的标题","at":1500},"completed_at":{"v":4000,"at":3000}}}],"lists":[]}'
do_push
echo "  ^ 期望: title 仍是「买豆奶」(at=2000), notes=低脂, completed_at=4000 (at=3000)"

step "8. 软删除墓碑 t=5000"
P '{"tasks":[{"id":"smoke-task-0001","fields":{"deleted_at":{"v":5000,"at":5000}}}],"lists":[]}'
do_push

step "9. 全量拉取（任务A 应为墓碑行且字段合并正确）"
do_pull 0

step "10. 增量拉取 since=4999（应只含任务A 这一行）"
do_pull 4999

step "11. 增量拉取 since=99999999999999（应为空）"
do_pull 99999999999999

step "12. 全量导出备份"
"${CURL[@]}" "${AUTH[@]}" "$BASE/v1/export"; echo

printf '\n===== 冒烟测试执行完毕，请对照注释核对上方输出 =====\n'
