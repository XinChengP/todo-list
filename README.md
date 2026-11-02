# 任务清单

Windows / Android 双端任务清单应用，字段级 Last-Write-Wins 增量同步，后端 Cloudflare Workers（免费额度）。

```
┌────────────┐  ┌────────────┐     HTTPS + Bearer Token
│ Flutter    │  │ Flutter    │ ─────────────────────►  https://todoapi.xinchengp.cn
│ Windows 端 │  │ Android 端 │        Cloudflare Workers + D1
│ 本地SQLite │  │ 本地SQLite │        （字段级 LWW 同步）
└────────────┘  └────────────┘
```

## 目录

- `app/` —— Flutter 客户端（Windows + Android 一套代码）
- `server/` —— Cloudflare Workers 同步后端（已上线，详见其 README）

## 同步设计铁律（两端共同遵守）

1. 主键一律 UUIDv7，客户端生成，绝不用自增
2. 删除只写 `deleted_at` 墓碑，永不物理删除
3. 每个可同步字段有独立时间戳（`field_ts`），冲突按字段 Last-Write-Wins，平局服务器赢
4. 推送后必须用服务器返回的最终状态覆盖本地（幂等收敛）
5. 客户端 `nowMs()` 单调递增，同字段后写的必然赢
6. `at = 0` 表示字段从未被写入，在 LWW 比较中永不获胜

## 开发

```bash
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift 代码生成
flutter test                                               # 24 个测试（不含真机 E2E）
# 真实端到端（对接线上 API）：
flutter test test/live_e2e_test.dart --dart-define=LIVE_E2E=true \
  --dart-define=LIVE_URL=https://todoapi.xinchengp.cn \
  --dart-define=LIVE_TOKEN=$(cat ../server/.sync-token)
```

环境变量（国内镜像 + 构建缓存放 D 盘，C 盘已满勿改回）：

```
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
PUB_HOSTED_URL=https://pub.flutter-io.cn
GRADLE_USER_HOME=D:\AndroidDev\gradle-home
TMP=D:\AndroidDev\tmp   TEMP=D:\AndroidDev\tmp
```

## 构建

版本号规范（versionName / versionCode 公式、发布流程）见 [VERSIONING.md](VERSIONING.md)；
改版本只跑 `cd app && dart run tool/bump_version.dart 1.0.22`（或 `dart run tool/bump_version.dart patch`）。

- **Android**：`flutter build apk --release --target-platform android-arm64`
  → `build\app\outputs\flutter-apk\app-release.apk`（约 23MB，单架构，versionCode = pubspec 里的值，无 ABI 偏移）
  安装到手机后：打开 App → 右上角设置 → 确认服务器地址与令牌（令牌在 `server/.sync-token`）→ 即自动同步
- **Windows**：先双击 `D:\AndroidDev\install-vs.bat` 装 VS Build Tools（唯一未完成的工具链，需点一次 UAC），
  然后 `flutter config --enable-windows-desktop`（默认已启用）+ `flutter run -d windows`

## 已知环境坑（本机实测，勿踩二次）

| 坑 | 解法 |
|---|---|
| ⚠️ **Flutter release 包在安卓上网络全断**（直连 EPERM errno=1 + DNS errno=7）：模板只在 debug/profile 清单带 INTERNET 权限，release 没有 | `main/AndroidManifest.xml` 自己加 `<uses-permission android:name="android.permission.INTERNET"/>`（已加，v1.0.3 起） |
| Flutter 3.41.2 钉 meta 1.17.0，新版 analyzer/drift_dev 要更高 | `pubspec.yaml` 的 `dependency_overrides: meta: ^1.19.0` |
| drift 2.35 列构建器改为 Table 实例方法 | `int()` → `integer()`；`text()`/`boolean()` 不变 |
| drift 对 TEXT 主键不生成 getTask | 自写 `getTaskById()`（database.dart） |
| 8787 等端口落在 Hyper-V 保留段 | 后端本地端口用 7777 |
| sqlite3 钩子从 GitHub 下载二进制，直连必超时 | 镜像 `ghfast.top/https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/<file>` 下载后按 sha256 前八位预置到 `.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/`（Windows: sqlite3.dll；Android 各 ABI: libsqlite3.so），哈希校验通过即跳过下载 |
| C 盘 100% 满，gradle daemon 被 OOM 干掉 | `GRADLE_USER_HOME`/`TMP` 已迁 D 盘；gradle 堆已降为 2G（android/gradle.properties） |
| Gradle 发行包下载慢 | wrapper 已指向 `mirrors.cloud.tencent.com/gradle` |
| Windows 构建需要 VS C++ 工具链 + 开发者模式 | 双击 `D:\AndroidDev\install-vs.bat`（JDK/SDK 已装好于 D:\AndroidDev） |

## 已知权衡与可选优化（复审记录）

- **APK 体积**：默认三架构通用包 55.7MB；日常用
  `flutter build apk --release --target-platform android-arm64`，单架构约 23MB
  且没有 ABI versionCode 偏移（不要用 `--split-per-abi`，见 VERSIONING.md）
- **软删除墓碑永久保留**：多端离线语义要求墓碑不丢（离线一年的设备回来也不能复活已删任务）。
  行体积极小，个人规模无碍；若将来做 GC 必须同时保证所有设备都已同步过该时间点
- **同步令牌明文存于本地 SQLite**：单机自用可接受；若担心 root 设备读取，可接
  `flutter_secure_storage`（Android Keystore / Windows DPAPI）
- **手机时钟快慢会影响 LWW 胜负**：字段级时间戳来自客户端时钟，钟快的设备赢得冲突。
  可选加固：服务器拒绝 `at > 服务器时间 + 5 分钟` 的写入
- **待办体验项**：Windows 托盘图标（关窗驻留）、窗口位置记忆、应用图标与签名、
  清单分类 UI、搜索

## 手机端耗电设计（重要约定，改动前先读）

| 项 | 策略 |
|---|---|
| 后台行为 | **零后台**：无定时同步、无常驻服务、无 wakelock。同步只发生在打开 App / 手动下拉 |
| 数据监听 | drift 流是 SQLite 事件驱动，不轮询 |
| 桌面卡片刷新 | 主路径 = 任务变化时数据驱动刷新；30 分钟周期刷新（`updatePeriodMillis`，Android 最低档）只做本地渲染，**不碰网络不碰同步** |
| 卡片写入 | 内容级去重（内容没变不写盘不广播）+ 800ms 防抖合并（一次同步只写一次）；同步回写多行导致的流连发不会放大成多次卡片更新 |
| 网络重试 | 失败最多 3 次指数退避后停止，绝不无限重试 |
| **连接提速（v1.0.4）** | ① ApiClient 常驻复用：TLS 连接跨同步保活，省去每次 1-3 秒握手；② 多候选 IP 并行竞速连接（直连 IP 与 DoH 解析并行，先连上的胜出），串行最坏 14 秒 → 并行最坏 5-7 秒；③ 失败才重建连接池。后续可选优化：合并 push/pull 为单往返协议 |
| **多端点回退** | 国内直连 CF 可达性按时段波动（实测晚高峰 443 劣化、非标端口存活）。客户端支持**备用地址自动回退**：设置里可填备用地址（默认预置 `:8443` 端口变体），主地址失败自动轮换尝试，成功端点持久化、下次优先用。CF 免费版备用 HTTPS 端口：2053/2083/2087/2096/8443 |
| **直连 IP（绕过 DNS）** | 设备 DNS 解析失败（模拟器/部分运营商常见）时的杀手锏：**默认启用**（配置层默认 `104.21.68.252`，无需进设置），TCP 直连该 IP、TLS 仍按域名做 SNI+证书校验；直连失败自动回退系统解析；清空设置里的值可禁用。实现用 `HttpClient.connectionFactory` + `SecureSocket.secure(socket, host: 域名)`（注意：connectionFactory 分支不做 TLS，必须手动 upgrade）。PC 验证脚本：`dart run tool/direct_ip_check.dart [IP]` |
| **DoH 兜底解析** | 直连 IP 也连不上时：用阿里 DNS 的**纯 IP DoH 端点** `https://223.5.5.5/resolve`（它本身无需 DNS，国内基本必通）解析出 CF IP 逐个尝试（证书不含 IP SAN 时自动切 SNI=dns.alidns.com 重握手）；结果缓存 10 分钟。三级连接链：直连 IP → DoH 解析 IP → 系统解析，全失败才报错 |
| 未来加后台同步时 | 必须用 WorkManager 且默认关闭、做成设置项，不要用 Timer 常驻 |

## 内存设计约定（改动前先读）

| 项 | 策略 |
|---|---|
| 悬浮窗（独立引擎） | 每个窗口一个 Flutter 引擎（约 60-100MB），悬浮窗数据库连接归其所有并在 dispose 显式关闭 |
| 悬浮窗刷新策略 | **不常驻轮询**：启动查库 + 10 分钟兜底轮询 + 手动刷新按钮（标题栏 ⟳）+ 主窗口任务变化时主动通知（800ms 防抖）+ 聚焦时刷新。轮询生命周期由调用点管理：创建/唤起→启动，隐藏→停止。window_manager 不广播 hide/show 事件，勿依赖监听器 |
| 悬浮窗刷新 | 数据签名去重（id+完成态+标题拼接比较），数据没变不 setState 不重建列表 |
| 跨窗口 handler | 主/浮窗口各自 `setWindowMethodHandler`，dispose 时必须置 null（否则闭包引用泄漏） |
| 卡片写入 | 同耗电设计：内容去重 + 防抖，无内存堆积（快照是单份覆盖写） |
| 列表渲染 | 全部 `ListView.builder` 惰性构建；任务量级（个人几百条）全内存无压力 |
| 实测基线 | Windows 主窗口工作集约 125MB（Flutter 桌面正常水平） |

## 进度

- [x] M2 后端：已上线 `todoapi.xinchengp.cn`，12 项冒烟 + 契约缺陷修复（at=0）重部署
- [x] M1 客户端：数据模型 + 本地 CRUD + 列表 UI
- [x] M3 同步层：ApiClient（重试/退避/401 识别）+ SyncEngine（推送覆盖收敛/增量合并/游标分页）+ 设置界面与自动同步；测试 24/24
- [x] 真实端到端：双"设备"经线上 API 完成新增/完成/删除三阶段跨端收敛（用后已清库）
- [x] Android APK：release 构建通过（55.7MB）
- [x] Windows 构建：release 通过（`build\windows\x64\runner\Release\todo_app.exe`），VS Build Tools 装于 `D:\VS2022BuildTools`
  - 坑：新版 VS 安装器不认 `--log` 参数（报"选项log未知"退出码 87）；`install-vs.bat` 已修正
- [x] 荣耀/MagicOS 桌面卡片：AppWidget，对照[荣耀官方接入指南](https://developer.honor.com/cn/doc/guideline/101669)适配——
  **两种卡片尺寸独立注册（2x2 与 4x2，各一个 Provider 变体，MagicOS 卡片选择器按 Provider 区分尺寸）**，
  按卡片实际高度自适应行数与头部显隐、
  深色模式走 values/values-night 原生方案自动换肤、
  任务变化即刷新（数据驱动 + 30 分钟兜底，双 Provider 同时刷新）、点击卡片打开应用（深链接已在 Manifest 声明）
  - 审计修复：颜色不再写死 Kotlin 常量（否则深浅色切换不换肤）、小尺寸卡不再溢出裁切
  - 坑：新增卡片尺寸需注册独立 Provider 子类（Kotlin 类默认 final，父类要标 open）；安装新尺寸后需重启手机刷新桌面卡片列表
- [x] Windows 悬浮窗：主窗右上角"画中画"按钮打开——**半透明无边框紧凑卡（270×380，Win11 圆角、始终置顶、默认停靠右上角）**，启动/10 分钟兜底/手动 ⟳/主窗口变化主动通知 四路刷新，点击任务即勾选完成、标题栏拖动、可关置顶
  - ⚠️ 架构事实：**desktop_multi_window 的子引擎不注册任何 Flutter 插件**（window_manager/path_provider 等全部不可用，连 drift 的默认路径解析都会静默失败）
  - 因此悬浮窗：数据库路径由主窗口经窗口参数传入，`NativeDatabase` 直连文件（原生资产无需插件）；无边框/半透明/置顶/拖动用 **FFI 直调 user32/dwmapi**（lib/win32_float_window.dart），不依赖任何插件
- [x] 复审优化：删除支持撤销（SnackBar）、推送自动分块（200 行/批，含测试）、同步重入保护、自动同步轻量重试（弱网启动不再空转一分钟）
- [x] Windows 开机自启（v1.0.8，FFI 写 HKCU Run 键，设置里可开关）
- [x] 接口文档 server/API.md（供其他自研产品接入）
- [x] 卡片交互增强（v1.0.8）：点任务左侧圆点即完成并静默同步；任务行显示截止日期（逾期红）/优先级
- [x] 应用图标（v1.0.13）：程序化生成 #66CCFF 渐变 + 白色对勾设计，flutter_launcher_icons 全平台应用（安卓自适应 + Windows ico）；源图与配置在 assets/icon/ 与 pubspec.yaml
- [ ] M4 补充：到点提醒的本地通知（需真机验证）、签名
- [ ] M5 打磨：清单分类 UI、搜索、主题
