<div align="right">
  <a href="README.md">English</a> | <strong>简体中文</strong>
</div>

<div align="center">
  <img src="mux0/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Mux0 Logo" width="120" />
  <h1>Mux0</h1>
</div>

macOS 终端应用，标签页 + 分割窗格，侧边栏实时展示 AI Agent 的运行状态。按项目组织终端、自由切分窗格，一眼看清 Claude Code / OpenCode / Codex / pi / Grok 是在跑、空闲、还是等你输入。

由 [ghostty](https://ghostty.org) 引擎驱动，Metal GPU 渲染。中英双语 UI。

## 功能特性

- **Workspace → Tab → Split 三层结构** — 按项目组织终端。每个 workspace 有自己的 tab 集合，每个 tab 是一棵分割树，可横切、竖切、拖动分隔线、用键盘切换焦点窗格。
- **AI Agent 状态实时显示** — 侧边栏和 tab 图标实时反映 Claude Code / OpenCode / Codex / pi / Grok 的 `running` / `idle` / `等待输入` / `结束` 状态。每个 turn 会根据工具级报错自动标记成功或失败。悬停图标可以看到当前正在跑的工具、以及 agent 的最后一句回复摘要（Claude / Codex / pi / Grok）。
- **Workspace 侧边栏元信息** — 每个 workspace 行展示当前 git 分支、打开的 PR 状态、未读通知。每 5 秒后台刷新，并通过 shell 的 OSC 钩子实时更新。
- **精致的主题** — 内置 ghostty 全部主题。可调背景透明度、窗口模糊（毛玻璃）、光标形状与闪烁、非聚焦窗格变暗。Mux0 自身的侧边栏和标签栏会随当前终端主题同步染色 —— 不会有突兀的"外壳"颜色。
- **中英双语 UI** — 完整的英文与简体中文本地化。在 **设置 → 外观 → 语言** 中即时切换，无需重启。
- **布局持久化** — workspace 列表、tab 列表、分割布局、每个终端的工作目录都会跨重启保留。
- **自动更新** — 由 Sparkle 驱动的应用内升级。有新版本时侧边栏底部会出现小红点，更新日志内嵌显示，可延后或跳过某个版本。

![Mux0 截图占位](images/screenshot.png)

## 系统要求

- macOS 14.0 及以上
- 强烈推荐 Apple Silicon（以获得 Metal GPU 渲染效果）

## 新手上路

### 1. 安装

1. 从 [GitHub Releases](https://github.com/10xChengTu/mux0/releases) 下载最新的 `mux0.dmg`。
2. 打开 DMG，将 **Mux0** 拖入「应用程序」文件夹。
3. 启动 Mux0。首次运行时 macOS 可能会弹出安全提示 —— 前往 **系统设置 → 隐私与安全性**，点击 **仍要打开** 即可。

之后 Mux0 每天会自动检查一次更新，有新版本时侧边栏底部会出现小红点。

### 2. 新建第一个 Workspace

1. 点击侧边栏的 **＋** 按钮。
2. 选择一个项目文件夹 —— 这会成为该 workspace 的工作目录。
3. 侧边栏会立刻开始跟踪这个目录的 git 分支、PR 状态与通知。

小贴士：可以建任意多个 workspace，每个都独立持有自己的 tab 和分割布局。

### 3. 打开标签页与分割窗格

- **新建 tab** — `⌘T`，或标签栏上的 **＋** 按钮。
- **关闭 tab** — `⌘W`，或 tab 上的 ✕ 按钮。
- **横向分割** — `⌘D`。
- **纵向分割** — `⌘⇧D`。
- **切换焦点窗格** — `⌘⌥` + 方向键。
- **调整窗格大小** — 用鼠标拖动分隔线。
- **重命名 tab / workspace** — 双击标题。
- **重新排序** — 拖拽 tab 或 workspace 行。

### 4. 挑选主题

按 `⌘,` 打开 **设置**，然后：

- **外观 → 主题** — 选择任意 ghostty 主题。侧边栏和标签栏会随之染色。
- **外观 → 背景透明度** — 低于 1.0 可得到半透明窗口。
- **外观 → 背景模糊** — 配合透明度可做出毛玻璃效果。
- **字体 → 字体族 / 字号** — 挑选系统里任意等宽字体。

全部设置项的说明见 [`docs/settings-reference.md`](docs/settings-reference.md)。

### 5. 切换语言（可选）

**设置 → 外观 → 语言**：*跟随系统*、*English*、或 *简体中文*。切换后整个界面立刻生效。

## 在 Mux0 中使用 AI Agent

Mux0 会自动钩接 Claude Code / OpenCode / Codex / pi / Grok，让它们的运行状态实时显示在侧边栏与 tab 图标上。你不需要做任何额外配置 —— 照常运行 agent 即可。注入都是按进程生效的（wrapper 加一个参数，或把 CLI 指向一个私有配置目录），你自己的全局 agent 配置不会被改。

### 状态图标

| 图标颜色 | 含义 |
|---|---|
| 绿色（闪动） | Agent 正在运行 —— turn 进行中 |
| 琥珀色 | Agent 在等你输入（权限请求、澄清问题） |
| ✓（绿色对勾） | 上一个 turn 干净结束 |
| ✕（红色叉） | 上一个 turn 里有至少一个工具报错 |
| 灰色 | 空闲 / 没有 agent 在跑 |

悬停状态图标可以看到当前正在跑的工具（例如 *"Edit Models/Foo.swift"*、*"Bash: ls"*），以及 agent 最后一句回复摘要（Claude / Codex / pi / Grok）。

### 支持的 Agent

| Agent | 启动命令 | 说明 |
|---|---|---|
| **Claude Code** | `claude` | 状态 + turn 摘要 + 工具详情，功能最全 |
| **OpenCode** | `opencode` | 状态 + 工具详情。摘要暂未实现 |
| **Codex** | `codex` | 状态是实验性的，响应可能略慢 |
| **pi** | `pi` | 状态 + turn 摘要 + 工具详情。以 `pi -e` 扩展的形式按进程加载，不写 `~/.pi`。pi 自身没有权限确认弹窗，所以只有当某个扩展向你提问时才会出现「等待输入」 |
| **Grok** | `grok` | 状态 + turn 摘要 + 工具详情 + 会话恢复。通过私有 `GROK_HOME` 目录注入，不动 `~/.grok`；会话照样能被 mux0 外面的 `grok --resume` 列出 |

如果状态图标不更新，见下面的 [常见问题](#常见问题)。

## 常见问题

### Agent 状态图标不更新

- 确认 **设置 → Shell → Shell Integration** 已启用（默认 *detect*）。
- 关掉并重新打开那个终端 tab。钩子是在新 shell 启动时激活的，所以升级 Mux0 之前就打开的老终端不会被注入。
- 如果你手动改过 shell rc 文件（`~/.zshrc`、`~/.bashrc` 等）并关闭了 ghostty 的 shell 集成，需要重新启用。

### 主题或字体保存后没有变化

设置写入有约 200 ms 防抖。如果一两秒后还是没生效，把该设置关掉再打开，或退出重启 Mux0。

### 窗口模糊 / 透明效果看起来不对

模糊只有在 **背景透明度** 低于 1.0 时才有可视效果。想要毛玻璃效果，先降低透明度，再调整模糊半径。

### 首次打开提示「无法打开 Mux0」

这是 macOS 的 Gatekeeper 警告。前往 **系统设置 → 隐私与安全性**，滚到底部，点击 Mux0 那一条旁边的 **仍要打开**。只需要做一次。

### 自动更新没检测到新版本

自动更新每天最多检查一次。想立刻检查，打开 **设置 → 更新**，点击 **检查更新**。

## 从源码构建

```bash
./scripts/build-vendor.sh   # 首次构建 libghostty
xcodegen generate
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
```

完整的依赖、vendor 布局、发版流程见 [`docs/build.md`](docs/build.md)。

### 让本地授权不反复丢失（可选）

默认情况下 Debug 构建走 **ad-hoc 签名**，每次 `xcodebuild` 生成的 `cdhash` 都不同。macOS TCC（Files & Folders、Full Disk Access 等权限系统）把它当成"换了一个 app"，之前授予的权限直接作废 —— 所以每次 rebuild 都要重新点允许。

用稳定的 Apple Development cert 签名可以根治：

1. 确认 **Xcode → Settings → Accounts** 里登录了你的 Apple ID。
2. 复制模板并填入 10 位 Team ID：
   ```bash
   cp Local.xcconfig.example Local.xcconfig
   # 然后编辑 Local.xcconfig：
   # DEVELOPMENT_TEAM = XXXXXXXXXX
   ```
3. `xcodegen generate && xcodebuild ... build`，用下面命令验证：
   ```bash
   codesign -dv ~/Library/Developer/Xcode/DerivedData/mux0-*/Build/Products/Debug/mux0.app 2>&1 | grep Authority
   ```
   应看到 `Authority=Apple Development: <你的名字> (...)`，而不是 `adhoc`。

`Local.xcconfig` 已在 `.gitignore` 里，不会入库。不想配也没关系 —— 构建照常能跑，只是 TCC 弹窗循环仍在。

## 文档

- [设置项参考](docs/settings-reference.md) —— 每个设置项的详细说明
- [Agent 钩子参考](docs/agent-hooks.md) —— 状态图标的工作原理
- [构建与 vendor](docs/build.md) —— libghostty、签名、发版流程
- [国际化](docs/i18n.md) —— 支持语言与切换行为

## 许可证

Mux0 采用 **Source-Available License**（源码可见许可证）发布 —— 详见 [`LICENSE`](LICENSE)。说人话：

- **✅ 免费使用，商用也没问题。** 个人用、公司里用、拿它写并发布你的商业产品 —— 都可以，和你用任何一款终端软件一样。你在 Mux0 里创作的东西都归你。
- **✅ 欢迎 fork 来贡献代码。** 在 GitHub 上 fork、改代码、提 PR —— 非常欢迎。
- **🚫 不允许把 Mux0 本身再分发。** 不能转售、不能把 Mux0 打包进你销售的产品、不能托管成 SaaS 对外服务、也不能把 fork 长期维护成和上游并行的独立发行版。源码公开是为了透明度和接受贡献，而不是让你再次作为产品分发。

这不是 OSI 认可的开源许可证。如果你想做许可范围之外的使用（再分发、产品打包、SaaS 托管、维护非贡献用途的 fork 等），请联系版权持有人。

**关于贡献。** 提交 PR 即视为你同意 [LICENSE 第 9 条](LICENSE) 的条款 —— 简单说就是你授权项目使用、修改、并以 Mux0 的名义（含将来的任何许可证版本）分发你的贡献。
