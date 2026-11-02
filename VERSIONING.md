# 版本号规范

三端（Android / Windows / 服务端）各有一套版本号，但 Android 的 `versionCode`
必须严格单调递增，所以单独定规则。

## 发布节奏（重要）

**本地开发不为每个小版本推送或发布。**

- 日常改动用 `dart run tool/bump_version.dart patch` 递增**本地**版本号，只为构建验证
- 提交（`git commit`）留在本地累积，**不 push、不打 tag、不建 Release**
- 只有明确说「发布」时，才执行 `git push` + `git tag` + `gh release create`
  （发布前会先把本地攒的若干提交一次性推上去，按 MINOR 归并成一条 Release）
- 建议：PATCH 累积在本地，凑够一批功能或修完一批问题再发；真正对外发布时
  用 `dart run tool/bump_version.dart minor` 收一个 MINOR 版本
- 例外：同步/数据类线上故障（例如"拉取漏数据"）需要客户端尽快拿到修复时，
  可以只发一个 PATCH Hotfix —— 但也要先说一声再发

## 客户端（Flutter，Android + Windows 共用）

| 项 | 规则 |
|---|---|
| `versionName` | `MAJOR.MINOR.PATCH`，语义化 |
| `versionCode` | `MAJOR*10000 + MINOR*100 + PATCH`，写在 `pubspec.yaml` 的 `+` 后面 |

示例：

| versionName | versionCode | 说明 |
|---|---|---|
| `1.0.21` | `10021` | 当前 |
| `1.0.22` | `10022` | 修 bug |
| `1.1.0` | `10100` | 加功能 |
| `2.0.0` | `20000` | 破坏性变更（需要数据迁移） |

- `MAJOR`：破坏性变更（数据格式 / 同步协议不兼容，需要迁移）
- `MINOR`：新增功能，向后兼容
- `PATCH`：修 bug、UI 微调、性能优化
- `MINOR` 和 `PATCH` **必须 < 100**，否则公式会撞车（测试会拦住）

### 只改版本号的正确姿势

```bash
cd app
dart run tool/bump_version.dart 1.0.22   # 指定版本
dart run tool/bump_version.dart patch    # 或按当前版本 +1（patch/minor/major）
```

脚本会同时改 `pubspec.yaml` 的 `version:` 和 `lib/ui/settings_dialog.dart` 的
`kAppVersion`（界面里"同步设置 vX.Y.Z"显示的那份），两处不一致会被
`test/version_test.dart` 拦下来。

### 构建命令（重要）

```bash
# Android：单架构单包，约 20MB，versionCode 就是 pubspec 里的值
flutter build apk --release --target-platform android-arm64

# 32 位老设备（按需）
flutter build apk --release --target-platform android-armeabi-v7a

# Windows
flutter build windows --release
```

**不要再用 `--split-per-abi`**：AGP 会给每个 ABI 包额外加
`+1000`/`+2000` 的 versionCode 偏移（arm64 = 基础号 +2000，v7a = +1000），
于是同一个版本会出现 `10022 / 11022 / 12022` 三个号，且**通用包
（10022）比已经装上的拆分包（12022）小**，覆盖安装会被判成降级而失败。
`--target-platform` 只过滤架构、不产生 split，versionCode 干净可控。

### 发布流程

```bash
cd app
dart run tool/bump_version.dart patch     # 1) 定版本
flutter analyze && flutter test           # 2) 校验（含 version_test）
flutter build apk --release --target-platform android-arm64
flutter build windows --release
# 3) 打包产物、git commit + tag、gh release create
```

Git tag 用 `v` + versionName（如 `v1.0.22`），与 Release 标题一致。

## 服务端（Cloudflare Worker）

独立版本，**跟客户端解耦**（服务端可以先上，客户端自动回退/前进）：

- 版本号写在 `server/src/index.ts` 的 `SERVER_VERSION`，随 `/health` 返回
- 规则：`/health` 是公开探针，改动只增字段、不改已有字段语义
- 每次 `wrangler deploy` 前先 bump，部署后用
  `curl https://todoapi.xinchengp.cn/health` 确认线上版本号，
  避免"以为部署了其实没上"（这个坑真踩过）
- 协议不兼容时进 `MAJOR`，并在 `server/schema.sql` 里写迁移

## 数据/协议版本

- 本地库 `schemaVersion`（`app/lib/db/database.dart`）：drift 迁移用，
  每次改表结构 +1，并写 `MigrationStrategy`
- 同步协议：只有增字段/加端点视为兼容；删除或改变字段语义必须进服务端 MAJOR
