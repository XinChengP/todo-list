# 插件与自动化指南

任务清单的扩展面有两层：**事件 + Webhook**（不用写代码，配 URL 就行）和
**Dart 插件接口**（自己写代码，编译进应用）。

## 一、事件模型

所有扩展的输入都是同一个事件结构：

```json
{
  "event": "task.completed",
  "at": 1794121301866,
  "task": {
    "id": "0192…",
    "title": "买牛奶",
    "notes": "",
    "list_id": "0191…",
    "due_at": 1794198000000,
    "priority": 2,
    "completed_at": 1794121301860,
    "deleted_at": null,
    "repeat_rule": "{\"unit\":\"day\",\"n\":1}",
    "remind_offset": 10,
    "remind_at": 1794197400000
  }
}
```

| 事件 | 触发时机 |
|---|---|
| `task.created` | 新建任务 |
| `task.updated` | 修改任务（连续多次修改会合并成一条，800ms 静默窗口） |
| `task.completed` | 勾选完成（周期任务也触发，task 是滚动后的状态） |
| `task.uncompleted` | 取消完成 |
| `task.deleted` | 删除（软删除） |
| `task.restored` | 撤销删除 |

注意：
- `task` 是**落库后的最终状态**（不是操作前的旧值）
- 只在**本机操作**时触发；从其它设备同步来的变更不触发
- Windows 悬浮窗里完成的任务走独立子引擎，**不会**触发事件（已知限制）

## 二、Webhook（零代码）

设置 → 插件与自动化 → 添加：

| 字段 | 说明 |
|---|---|
| 名称 | 随意 |
| URL | POST 目标地址 |
| 令牌 | 可选，随请求头 `X-Todo-Token` 发送 |
| 订阅事件 | 多选；不选 = 全部事件 |

- 每条可单独启停、发送测试事件；最近一次结果（HTTP 状态/错误）显示在列表里
- 超时 10 秒；失败不影响 App 主流程
- 配置存在本机（不同设备可接不同的自动化）

### 接收端示例

任意 HTTP 服务都行，几个思路：

```bash
# 最简接收器（本机 8787 端口，把事件打进日志文件）
while true; do
  echo -e 'HTTP/1.1 200 OK\n\n' | nc -l -p 8787 >> ~/todo-events.log
done
```

```javascript
// Node：收到"完成任务"事件就做点什么
require('http').createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const e = JSON.parse(body);
    if (e.event === 'task.completed') console.log('完成：', e.task.title);
    res.end();
  });
}).listen(8787);
```

n8n / Home Assistant / 企业机器人 webhook 均可直接接。

## 三、只读开放接口（服务端）

服务端暴露了稳定的只读接口，供脚本拉取全部未删除任务：

```bash
curl -H "Authorization: Bearer $SYNC_TOKEN" https://你的域名/v1/tasks
```

返回 `{"ok":true,"tasks":[...协议行...]}`，格式与 `/v1/sync/pull` 的任务行一致。
写操作请走 `/v1/sync`（字段级 LWW，幂等），完整契约见 `API.md`。

## 四、Dart 插件接口（自己写代码）

所有内置能力都可以用同一个接口实现。新增一个插件：

```dart
// lib/plugins/my_plugin.dart
import 'plugin_api.dart';

class MyPlugin extends TodoPlugin {
  @override
  String get name => 'my_plugin';

  @override
  String get title => '我的插件';

  @override
  Future<void> onTaskEvent(TaskEvent e) async {
    if (e.type == TaskEventType.completed) {
      // e.task 是完成后的最终状态
    }
  }
}
```

然后注册（`lib/ui/home_page.dart` 的启动回调里，与内置插件并列）：

```dart
PluginHost.register(MyPlugin());
unawaited(PluginHost.init(repo));
```

约定：
- 插件抛出的任何异常都会被宿主吞掉，**绝不影响主流程**
- `updated` 事件会合并（800ms 窗口），不要假设每次字段写入都有事件
- 插件里不要做耗时同步操作；网络请求自己控制超时
- 配置存取可以用 `SettingsRepository`（`settings` 表，本机不参与同步）

内置的 Webhook 推送就是用这个接口写的，可作参考实现
（`lib/plugins/webhook_plugin.dart`）。

## 五、已知限制

- Windows 悬浮窗（独立引擎）里的操作不产生事件
- 插件配置只存本机；换设备需重新配置
- 事件不保证送达（webhook 失败只记录最近一次结果）
