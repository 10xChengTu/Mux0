# Testing

## Test Strategy

| 类型 | 覆盖 | 工具 |
|------|------|------|
| 单元测试 | ThemeManager 解析、WorkspaceStore CRUD、frame 计算 | XCTest |
| 集成测试 | GhosttyBridge surface 创建/销毁（需 libghostty） | XCTest |
| UI 快照测试 | 侧边栏深色/浅色渲染 | XCTest + `XCTAttachment` |
| 手动验收 | 拖拽、workspace 切换、OSC 通知 | 人工 |

## Running Tests

```bash
# 所有测试
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests

# 单个测试文件
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
  -only-testing:mux0Tests/WorkspaceStoreTests

# 没有 GUI 的机器（CI / 无人值守 Mac）必须指定 destination
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -destination 'platform=macOS'

# agent-hooks 的 Python / bash / node 测试（不需要 Xcode）
# 一条命令跑完下面所有项（每个 shell 测试在 bash 与 zsh 下各跑一遍）
bash Resources/agent-hooks/tests/run-all.sh

python3 -m pytest Resources/agent-hooks/tests/ -q     # agent-hook.py + pi 扩展（node）
bash Resources/agent-hooks/tests/smoke.sh             # agent-hook.sh 全链路（真 Unix socket）
bash Resources/agent-hooks/tests/codex_wrapper_cleanup.sh
bash Resources/agent-hooks/tests/grok_wrapper_overlay.sh
bash Resources/agent-hooks/tests/grok_restore.sh
bash Resources/agent-hooks/tests/installer_backup_prune.sh   # scripts/install.sh 的备份/剪枝回归
bash Resources/agent-hooks/tests/installer_running_check.sh  # scripts/install.sh 的「在跑就拒装」回归
```

> **测试环境里强制 `CLICOLOR_FORCE=1`。** 这一层吃过两次同形态的亏：脚本把 `ls` 的输出
> 当路径用，而带颜色的 `ls` 会把目录名写成 `\033[34m…`，于是「找快照目录」「剪枝旧备份」
> 这类逻辑不报错、但什么都不做。审核者的 shell 导出了 `CLICOLOR_FORCE=1`，写报告的这台
> 没有，于是红的被报成绿的。`run-all.sh` 现在默认打开颜色（`MUX0_NO_COLOR=1` 可关），
> 具体写法见 `docs/conventions.md#shell-脚本规范`。

> **这些测试得用 bash 跑。** 它们都是 `#!/bin/bash`，但历史上直接用
> `${BASH_SOURCE[0]}` 定位被测脚本——该变量在 zsh 下是空的，路径会塌到 CWD，
> 于是「bash 下全绿」的测试在 macOS 默认登录 shell（zsh）里其实是红的。
> 现在脚本开头会在被非 bash 启动时 `exec bash` 重新拉起自己，`run-all.sh` 则强制
> bash + zsh 两个 shell 都要过，不要只跑一种就宣布通过。

上面全部**不调模型**。要验「接到真 CLI 上还能不能上报」，跑（需要登录、花模型额度，
所以它不在 `run-all.sh` 里，也不在 `tests/` 目录）：

```bash
bash Resources/agent-hooks/e2e-live.sh both          # pi + grok 各跑一次真模型
bash Resources/agent-hooks/e2e-live.sh grok --fail   # 失败路径：exitCode 必须非 0
```

它断言「带 `resumeCommand` 的 running」/「带 `toolDetail` 的 running」/「带 `exitCode` +
`summary` 的 finished」，并把 socket 收到的事件原文全部打出来（全过则 `E2E_OK`）。

## Test Files

```
mux0Tests/                       — 30+ 个 XCTestCase 文件（列全部太长，按名字自解释）
├── ThemeManagerTests.swift       — 主题解析、降级逻辑
├── WorkspaceStoreTests.swift     — CRUD、持久化、selectedId 状态、pendingPrefills
├── MetadataRefresherTests.swift  — git/port 解析逻辑
├── HookMessageTests.swift        — socket JSON 解码、agent 枚举、fromResumeCommand 前缀
├── HookDispatcherTests.swift     — per-agent 门控、needsInput 门控、resume 双门控
├── AgentPreferencesTests.swift   — 新增 agent（pi / grok）的通知开关迁移
├── QuickActionTests.swift        — 内置 action 定义、图标 asset 是否真的存在
├── QuickActionsStoreTests.swift  — 排序 / 启用集合 / 新 builtin 自动启用迁移
├── StartupCommandResolverTests.swift — 启动命令优先级（quick action / resume / default）
└── StatusIndicatorGateTests.swift — 状态图标列是否出现的总开关

Resources/agent-hooks/tests/
├── test_agent_hook.py         — agent-hook.py 单测（pytest；claude/codex/grok envelope、
│                                resume 命令、错误聚合、标题与 summary 读取）
├── pi_extension_test.py       — 在 node 里加载 pi-extension/mux0-status.js，用假 pi 对象
│                                回放真实事件序列，断言 socket 收到的 JSON（无 node 时自动 skip）
├── smoke.sh                   — agent-hook.sh 端到端：起 Unix socket，跑 claude 与 grok 的
│                                完整事件序列（含 grok 的 idle_prompt 兜底去重），再跑 pi wrapper，
│                                最后用 bash + zsh 各驱动一次 agent-hook.sh 本体 —— 这是唯一
│                                覆盖“真正被 hook 配置 exec 的入口”的地方
├── codex_wrapper_cleanup.sh   — codex wrapper 的 overlay 回写（exec 吃掉 EXIT trap 的回归）
├── grok_wrapper_overlay.sh    — grok wrapper 的 GROK_HOME overlay：注入点、用户 hooks 保留、
                                 rename 后的文件回写、sessions 仍指回真实目录、子命令 passthrough
├── grok_restore.sh            — grok-restore.sh：A 方案只删 overlay；B 方案按
│                                .mux0-backup/CHANGES.log 倒序回放（同一路径取最早那份快照），
│                                用户的 hooks 与 sessions 断言不许动
├── installer_backup_prune.sh  — scripts/install.sh（拿临时 --dest 真跑一轮）：优光 Mux0-*.zip、
│                                旧 app 备份成 mux0-<旧版本>-backup.app、只留 3 份备份且真的删掉
│                                （颜色开着时 `ls` 会把 .app 目录名写成带 ANSI 的串，rm 会空跑）
├── installer_running_check.sh — scripts/install.sh 的「mux0 在跑就拒绝安装」：用假 app 进程
│                                （`ln -s /bin/sleep` 到 mux0.app/Contents/MacOS/mux0）验它按
│                                **可执行文件路径**认进程；假进程 argv[0] 被改写成裸 `mux0` 时
│                                也要认出来（lsof 查映射的镜像）；PATH 上的 `pgrep` 装死（返回空）
│                                时仍要拒绝，`--force` 仍能装，进程退出后恢复正常
│                                —— 用户本机就是 pgrep 认不出、脚本照样往下装，见 docs/build.md
└── run-all.sh                 — 上面全部 + pytest 的一次性入口：每个 shell 测试在 bash 和 zsh 下
                                 各跑一次，必须看到 OK 哨兵（不只看退出码），自带逐项超时
                                 （macOS 没有 `timeout`，看门狗自己长）
```

## WorkspaceStore 隔离

每个测试用独立 persistenceKey，避免测试间互相污染：

```swift
let store = WorkspaceStore(persistenceKey: "test.\(UUID())")
```

**不要**用 `.testable` import 加 `@testable`，WorkspaceStore 已是 internal，直接测试公开接口。

## libghostty 集成测试

需要 libghostty 存在（`Vendor/ghostty/lib/libghostty.a`）。
标注方式：

```swift
// Integration: requires libghostty
func test_surfaceCreation_succeedsWhenBridgeInitialized() { ... }
```

CI 中可用环境变量跳过：
```swift
try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_GHOSTTY_INTEGRATION"] == "1")
```

## What to Test

**ThemeManager:**
- ghostty config 包含有效颜色时，tokens 正确映射
- ghostty config 缺失/解析失败时，降级到系统模式
- `applyScheme(.dark/.light/.system)` 后 `currentTheme` 正确更新

**WorkspaceStore:**
- `createWorkspace` 后 `workspaces` 包含新项
- `deleteWorkspace` 后 `selectedId` 切换到下一个可用 workspace
- `updateTerminalFrame` 正确更新嵌套 frame
- 持久化：编码再解码后数据一致
- 空列表时自动创建 Default workspace（仅默认 key）

**MetadataRefresher:**
- git branch 解析：`refs/heads/main` → `"main"`
- `onRefresh` 回调在主线程触发（async 路径）

> 端口列表 (`listeningPorts`) 与 OSC 通知文本 (`latestNotification`) 字段在
> 2026-04-16 sidebar 重构后从 row 视觉中移除：前者整个删除，后者保留在
> `WorkspaceMetadata` 但当前 `WorkspaceRowItemView` 不渲染——后续若决定恢复
> 显示，需要扩展 row 高度并补回测试。

## 手动 QA：自动更新

依赖已经发布到 GitHub Releases 的 v0.1.0 + 一个本地构建的"伪低版本"。

1. 把 `project.yml` 里 `MARKETING_VERSION` 临时改成 `0.0.9`，`xcodegen generate`，构建 Release：
   ```bash
   xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Release build
   ```
2. 启动产物。~3 s 内 sidebar 左下角红点应亮起。
3. 点版本号，Settings 应直接定位到 Update section，显示 `Version 0.1.0 is available` + release notes。
4. 点 `Download & Install`：进度 0-100%，app 退出并重启。重启后版本显示 `v0.1.0`，红点消失。
5. 重复 1-3。点 `Skip This Version`：红点立刻消失，关闭 app 再开不再提醒 0.1.0。发布一个 0.1.1（测试用）后红点重新出现。
6. 断网，点 `Check for Updates`：显示红色错误卡 + Retry 按钮。
7. Debug 构建：启动后无论如何不应发 appcast 请求；Update section 的 button 为 disabled，hint 行可见。

完事把 `MARKETING_VERSION` 改回。
