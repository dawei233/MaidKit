# MaidKit 二开：WebDAV 同步改造说明

> 改造目标：移除 Solarpass 付费工作区依赖，改用标准 WebDAV 同步（坚果云、Nextcloud、Seafile、自建 NAS 均可）。

## 已完成改动

### 1. 新增 WebDAV 同步服务

**文件：`lib/servers/webdav_sync_service.dart`（新增）**

- `WebDavSyncConfiguration`：同步配置（baseUrl、用户名、密码、远程目录、blobId、revision、同步指纹）
- `WebDavSyncService`：核心同步服务，接口对齐原 `CloudSyncService`
- `RemoteVaultInfo`：远程保险库信息（用于"从云端下载"流程）

远程文件布局（任何标准 WebDAV 目录下）：
```
{远程目录}/{blobId}.mkb   — 客户端加密的 vault 归档
{远程目录}/{blobId}.meta  — JSON 同步元数据（revision、时间戳、指纹）
```

**关键设计：**
- 认证：HTTP Basic（用户名 + 密码），密码存 `flutter_secure_storage`（OS keychain）
- 归档加密：完全复用 `DatabaseBackupService.exportArchive()`（用户 vault 密码 AES 加密），WebDAV 服务器只见密文
- 冲突处理：沿用原版 revision 对比 + 用户选择弹窗（`showMaidKitCloudSyncConflictAlert`）
- 增量优化：`contentFingerprint` 指纹相同则跳过上传
- 服务端零知识：与 Solarpass 版一致，服务器无法解密

### 2. 新增 WebDAV 配置表单

**文件：`lib/shared/presentation/webdav_configuration_sheet.dart`（新增）**

`showWebDavConfigurationSheet()` 弹窗表单：WebDAV URL / 用户名 / 密码 / 远程目录。

### 3. Provider 层

**文件：`lib/servers/server_providers.dart`**

新增：
- `webDavSyncServiceForVaultProvider`（family）
- `webDavSyncServiceProvider`
- `webDavSyncConfigurationProvider`
- `webDavSyncConfigurationForVaultProvider`

保留 `cloudSyncServiceProvider`（Agent 的 AI 人格 / 计费功能仍依赖其 `accessToken()`，与同步无关）。

### 4. 设置页改造

**文件：`lib/servers/settings_page.dart`**

- `_syncVault()`：手动同步改用 `WebDavSyncService`
- `_VaultCloudBindingTile`：绑定状态显示 WebDAV 端点（替代 workspace）
- `_bindWorkspace()` → `_configureWebDav()`：配置表单改为 WebDAV 凭据
- `_downloadCloudVault()`：从 WebDAV 列出并下载远程 vault
- 删除废弃的 `_chooseCloudWorkspace` / `_chooseCloudVault` 方法

### 5. 保险库门禁自动同步

**文件：`lib/servers/vault_gate.dart`**

- `_autoSync()`：每 5 分钟自动同步 + 应用恢复前台时同步，改用 WebDAV
- `_submit()`：解锁后 pendingDownload 下载流程改用 WebDAV

### 6. 新建保险库页

**文件：`lib/servers/vault_create_page.dart`**

- "从云端下载"流程改用 WebDAV：配置凭据 → 列出远程 vault → 选择 → 绑定下载

### 7. 备份范围扩展

**文件：`lib/servers/database_backup_service.dart`**

- `_formatVersion` 3 → 4
- 新增导出/导入：`agentProviders`（API key 解密后随归档迁移）、`agentProviderModels`、`mcpServers`、`agentSkills`
- 向后兼容 v3 备份（缺失新集合时按空处理）

### 8. 多语言

**文件：`assets/translations/en-US.json`、`zh-CN.json`**

同步相关文案从 "cloud workspace / Solarpass" 改为 "WebDAV"，新增配置表单相关 key。

## 命令历史同步（2026-08-05 已实现）

### 数据层

**文件：`lib/data/local/app_database.dart`**

- 新增 `TerminalHistory` 表（schema v18）：`id` / `serverId` / `command` / `exitCode` / `executedAt`
- `watchTerminalHistory()`：最近执行的命令流（可按服务器过滤，默认 200 条）
- `recordTerminalCommand()`：写入 + 自动清理（只保留最近 1000 条，控制同步体积）
- 迁移：`if (from < 18) createTable(terminalHistory)`

### 命令记录

**文件：`lib/servers/terminal_command_recorder.dart`（新增）**

从终端输入字节流解析完整命令：
- 处理 Enter/LF 提交、退格编辑、Ctrl+U 清行、Ctrl+C/D 提交部分命令
- 跳过 CSI 转义序列（方向键等）和 OSC 序列（窗口标题等）
- 支持括号粘贴模式
- 12 项单元测试全部通过（`test/terminal_command_recorder_test.dart`）

**接入点：**
- `terminal_session_adapter.dart`：`TerminalSessionBinding` 新增 `onCommand` 回调，在用户输入发送前解析（应用注入的 `export TERM_PROGRAM` / `cd xxx` 不走此路径，不会被记录）
- `ssh_connection_manager.dart`：`openTerminal()` 把命令回调传到 binding，携带 `server.id`
- `server_providers.dart`：`connectionManagerProvider` 注入数据库写入，best-effort 不阻塞 shell

### 同步范围

`database_backup_service.dart`：`terminalHistory` 加入导出/导入，随 WebDAV 加密归档跨设备同步。

### 验证结果（2026-08-05 实测）

- `flutter analyze`：**0 error / 0 warning**（仅剩 xterm 包固有 info）
- 命令记录器 12 项逻辑测试全部通过
- 说明：本机无 Visual Studio（无法本地编 Windows 包）+ WorkBuddy 沙箱拦截 flutter 删除 ephemeral 文件（`flutter test` 受影响），故完整测试和编译走 GitHub Actions CI 完成

## 构建验证结果（2026-08-05 已实测）

使用临时 Flutter SDK 3.44.8（Dart 3.12.2，与 pubspec `sdk: ^3.12.2` 完全匹配）实测：

```bash
flutter pub get   # 通过：依赖全部解析（含 island_ui_foundation git 源）
flutter analyze   # 通过：本项目代码 0 error / 0 warning
flutter test      # 144 通过，1 失败（见下）
```

- `flutter analyze` 仅剩 6 条 info，全部来自 `packages/xterm`（项目 vendored 的第三方包，原项目固有）
- `widget_test.dart` 的 `shows vault setup on first run` 在**原始未修改代码上同样失败**（已用 pristine 克隆对比验证），属原项目测试环境问题，与本次改动无关
- 验证期间修复了 1 个编译 error：Dio `request()` 的 `method` 参数需放进 `Options` 而非命名参数

## 构建验证清单（有 Flutter 环境时）

```bash
flutter pub get
dart run build_runner build    # 仅当改动 Drift schema / auto_route 后需要
flutter analyze
flutter test
flutter run                    # 桌面端验证同步流程
```

## 已知注意事项

- `island_ui_foundation` 从 `src.solsynth.dev` git 拉取，`window_manager` 是 fork 固定 commit，`flutter pub get` 需要网络能访问这两个源
- `packages/xterm` 是 vendored 4.0.0（作者修过 Flutter 3.44 终端输入 bug），不要替换
- WebDAV 服务未引入第三方包（`webdav_client` 等），全部用项目已有的 `dio` 手写 PROPFIND/PUT/GET，减少依赖风险
- 坚果云 WebDAV 地址：`https://dav.jianguoyun.com/dav/`，应用密码（非登录密码）
- Nextcloud：`https://{域名}/remote.php/dav/files/{用户名}/`
