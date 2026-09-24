# Build & Vendor

## Prerequisites

- macOS 14+
- Xcode 15+
- `xcodegen` (`brew install xcodegen`)
- Zig（构建 libghostty 需要，`brew install zig`）

## First-time Setup

```bash
# 1. 构建 libghostty 静态库（只需一次）
./scripts/build-vendor.sh

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 验证构建
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
```

## project.yml

`project.yml` 是 xcodegen 配置，定义 target、依赖、编译选项。
**修改后必须重新运行 `xcodegen generate`**，否则 Xcode 工程不更新。

修改场景：
- 添加新的 Swift 文件目录
- 添加系统 framework 依赖
- 修改 deployment target

修改 `project.yml` 需要人工确认（见 AGENTS.md Agent Permissions）。

## Vendor 目录

```
Vendor/
└── ghostty/
    ├── include/ghostty.h    — C API 头文件
    └── lib/libghostty.a     — 静态库（gitignored）
```

`libghostty.a` 已加入 `.gitignore`，每台机器首次使用需运行 `scripts/build-vendor.sh` 构建。

## Build Settings (project.yml)

| 设置 | 值 | 原因 |
|------|-----|------|
| `LIBRARY_SEARCH_PATHS` | `$(PROJECT_DIR)/Vendor/ghostty/lib` | 链接 libghostty.a |
| `HEADER_SEARCH_PATHS` | `$(PROJECT_DIR)/Vendor/ghostty/include` | 找到 ghostty.h |
| `OTHER_LDFLAGS` | `-lghostty -lc++ -framework Carbon` | ghostty 依赖 |
| `SWIFT_OBJC_BRIDGING_HEADER` | `mux0/Ghostty/ghostty-bridging-header.h` | Swift ↔ C 桥接 |
| `LD_RUNPATH_SEARCH_PATHS` | `""` | 静态库不需要 rpath |

## CI 注意事项

- CI 环境需要预置 Vendor/ghostty（或在 CI 里运行 build-vendor.sh）
- 在 release workflow 里 libghostty 单独跑在一个 `macos-15` job 上构建，再以
  artifact 传给主 `macos-26` build job —— 因为 zig 0.15.2 自带的 darwin libc
  tubs 与 macOS 26 SDK 的 libSystem.tbd 不兼容（compiler_rt 引用的
  `__availability_version_check` 等符号在新 SDK 上找不到），而 macos-26
  runner 又只装了 macOS 26.x SDK 没有老 SDK 兜底。等 ghostty 上游适配
  zig 0.16+ 后可以删掉这个分离 job
- 设置 `SKIP_GHOSTTY_INTEGRATION=1` 可跳过需要 libghostty 的集成测试
- `xcodebuild` 需要 `-destination 'platform=macOS'` 在非 GUI 环境下运行

## Release 流程

人工 tag → GitHub Actions 自动构建 + 签名 + 发布。

### 首次发布一次性准备

```bash
# Sparkle 的 generate_keys 在 SPM fetched 的 Sparkle 里
cd ~/Library/Developer/Xcode/DerivedData/mux0-*/SourcePackages/artifacts/sparkle/Sparkle/bin
./generate_keys
# 输出两件：私钥（写入 Keychain）+ 公钥（打印到 stdout）
```

- 把 stdout 的公钥替换 `project.yml` 中 `info.properties.SUPublicEDKey` 的占位符 `REPLACE_WITH_SPARKLE_ED_PUBKEY`（Sparkle 在 Info.plist 里的公钥键直接叫 `SUPublicEDKey`，不带 `INFOPLIST_KEY_` 前缀——那是 Xcode 对 Apple 白名单键的 synth 语法，第三方键不适用，所以 mux0 用 XcodeGen 的 `info:` 块直接注入）。然后 `xcodegen generate`、`git add project.yml mux0/Info.plist`、提交。
- 把私钥 export 到文本（`./generate_keys -x ed25519.priv`），塞进 GitHub repo secret `SPARKLE_ED_PRIVATE_KEY`，然后删本地文件（Keychain 仍留一份）。
- CI workflow（`.github/workflows/release.yml`）会在 tag push 时 grep `project.yml` 查找占位符字符串，未替换就直接失败——不用担心忘记填。

### 常规发布（默认：commit-driven）

改 `project.yml` 的 `MARKETING_VERSION` 就会自动发版：

```bash
# 1. 本地自测
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests

# 2. 只改 MARKETING_VERSION（不要手动改 CURRENT_PROJECT_VERSION，CI 管）
#    示例：把 "0.1.0" 改成 "0.2.0"
$EDITOR project.yml

# 3. Commit + push 到 master
git commit -am "chore(release): bump version to 0.2.0"
git push origin master

# → .github/workflows/auto-tag.yml 检测到 MARKETING_VERSION 变化：
#     a. 自动把 CURRENT_PROJECT_VERSION +1
#     b. 以 github-actions[bot] 身份 commit 并打 v0.2.0 tag
#     c. push master + tag
# → tag push 触发 release.yml，~10 分钟后 Release 出现在 GitHub Releases 页面
```

注意事项：

- **不要手动改 `CURRENT_PROJECT_VERSION`** —— 由 CI 自动 bump。Sparkle 靠这个字段判断是否是新版本。
- Commit message 必须符合 `type(scope): description` 规范（见 `docs/conventions.md`），否则 `cliff.toml` 的 `filter_unconventional = true` 会把该 commit 从 release note 里丢掉（不影响发版本身，但更新弹窗看不到该改动）。
- CI 生成的 `chore(release): bump build to N for v<version> [skip auto-tag]` 属于 `chore`，被 `cliff.toml` skip，不出现在用户可见的更新日志里。

### 退路：手动 tag（紧急发版）

auto-tag.yml 失效、或者需要补发一个特殊版本时：

```bash
# 手动 bump 两个字段（MARKETING_VERSION + CURRENT_PROJECT_VERSION）
$EDITOR project.yml
git commit -am "chore(release): bump to v0.2.1"

# 手动打 annotated tag 并推到远端
git tag -a v0.2.1 -m "Release v0.2.1"
git push origin master v0.2.1
```

auto-tag.yml 在 master push 时会启动但发现 `MARKETING_VERSION` 相对 `HEAD^` 未变就 exit 0，不会干扰手动 tag。

---

## 本地发版（fork / 无 CI / 无 Developer ID）

上游那条链路依赖 GitHub Runner + Developer ID + notarytool。在拿不到 GitHub、
也没有开发者证书的机器上（比如内网构建机），用：

```bash
./scripts/package-release.sh          # 构建 Release + 打包到 dist/
SKIP_BUILD=1 ./scripts/package-release.sh   # 只重新打包上一次构建
```

产物（`dist/`，已在 `.gitignore` 里）：

| 文件 | 说明 |
|---|---|
| `Mux0-<version>.zip` | `ditto -c -k --keepParent`，zip 根只有一个 `mux0.app`。用户解压后 `./install.sh` 即可。 |
| `Mux0-<version>.dmg` | 与上游 dmg 同结构（app + `/Applications` 软链），用 `hdiutil -format UDZO` 造，不需要 `create-dmg`。名字不带 `-universal`（里面确实是 universal 二进制），fork 的产物不去撞上游资产名。 |
| `install.sh` | 从 `scripts/install.sh` 复制过来。**先检查 mux0 是否在运行**（在跑就拒绝安装，`--force` 才继续，判据见下）→ 解压 → 去 quarantine → 备份旧 app（`mux0-<旧版本号>-backup.app`，最多留 3 份）→ `ditto` 安装 → 打印装后的版本号与签名校验 → `open`。`/Applications` 不可写自动退到 `~/Applications`。只看这一条不改动盘：`./install.sh --dry-run`；只问“在不在跑”：`./install.sh --running-check`（在跑打印 pid 退 0，没跑打印 `not-running` 退 10）。 |
| `SHA256SUMS` / `RELEASE-NOTES-<version>.md` | 校验与说明。 |

与上游产物的差别，只有两处，且都是签名而非格式：

- **ad-hoc 签名**（`CODE_SIGN_IDENTITY="-"`）+ Hardened Runtime，不公证。
  所以首次运行 Gatekeeper 会拦：`install.sh` 通过 `xattr -dr com.apple.quarantine`
  绕过；手工解压的用户需要右键 → 打开一次。
- **没有 appcast**。`project.yml` 里 `SUEnableAutomaticChecks = NO` + `SUFeedURL=""`，
  Release 还带 `MUX0_UPDATES_DISABLED` 编译条件（见 `mux0/Update/SparkleBridge.swift`）。
  说准确点：这个条件把 **每一个 Sparkle 调用点**编掉了 —— 没有任何文件 `import Sparkle`，
  产物里 undefined 的 Sparkle 符号数为 0（`nm -u mux0.app/Contents/MacOS/mux0 | grep -ci Sparkle`）。
  但 **framework 仍然被链接与嵌入**（`otool -L` 仍有 `@rpath/Sparkle.framework`，
  `Contents/Frameworks/Sparkle.framework` 仍在包里，dyld 启动时会映射）—— xcodegen
  无法把 package product 只绑到某一个 configuration。所以上面那两把 plist 开关是
  运行时的兼底；“不会去检查”靠的是没人构造 `SPUUpdater`（实测 `lsof -p <pid> -i` 全程为空）。
  原因：Info.plist 里的 appcast 指向**上游**仓库，
  fork 若继续检查更新，下一个上游版本会静默覆盖 fork 的安装。
  因此 `CURRENT_PROJECT_VERSION` 在这条链路上**手动 +1**（CI 的 auto-tag 不参与）。

### Sparkle 离线解析

`xcodebuild` 解析 SPM 依赖要访问 GitHub。把 Sparkle 预置成本地镜像 + 二进制产物目录，
再让 git 把上游 URL 重定向到镜像：

```bash
# 一次性：bare mirror（含 tag 2.9.1）+ 二进制 zip 放到 checksum 命名的位置
# （镜像路径以本仓库构建机为准：$HOME/worker/cache/spm/Sparkle.git，
#   与 scripts/package-release.sh 里 GIT_CONFIG_KEY_0 的默认值一致）
SPM_MIRROR="$HOME/worker/cache/spm/Sparkle.git"
cp "$HOME/worker/cache/spm/Sparkle-for-Swift-Package-Manager.zip" \
   /tmp/mux0-spm/artifacts/downloads/<Package.swift 里的 checksum>.zip

# 每次构建
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.$SPM_MIRROR.insteadOf"
export GIT_CONFIG_VALUE_0='https://github.com/sparkle-project/Sparkle'
xcodebuild ... -clonedSourcePackagesDirPath /tmp/mux0-spm -scmProvider system -skipPackageUpdates
```

`scripts/package-release.sh` 在检测到 `MUX0_SPM_DIR`（默认 `/tmp/mux0-spm`）存在时自动加这三个
参数；目录不存在就退回正常联网解析。`-scmProvider system` 是必需的——只有 git 认
`url.*.insteadOf`，Xcode 内置的 SCM 实现不认。

### “mux0 在跑”到底怎么判的

最早的写法是 `pgrep -x mux0` + 按路径过滤。用户的 MacBook（macOS 26.6）上它**整块失效**：
app 确定在跑（`ps -o comm= -p <pid>` 给出 `/Applications/mux0.app/Contents/MacOS/mux0`），
但 `pgrep -x mux0` / `-ix` / `-l` 全部返回空（同一个 `pgrep -x Finder` 正常），
结果 `install.sh` 不加 `--force` 也照样往下装，把 bundle 从一个活进程底下换掉了。

现在的判据是**可执行文件路径**，主通道不依赖 pgrep：

```bash
ps -ax -ww -o pid=,comm=      # 取后缀 /mux0.app/Contents/MacOS/mux0 的那几行
```

- `-ww`：不把行裁到终端宽度，多级安装目录不会把要匹配的后缀裁掉。
- 按路径后缀而不是按名字：兼容任意安装位置（`/Applications`、`~/Applications`、临时目录），
  也不误伤另一个也叫 `mux0` 的程序（仓库里的测试二进制）。
- `ps -o comm=` 其实是 **argv[0]**（不是内核解析后的路径）。万一谁把 argv[0] 改写成裸 `mux0`，
  还有一条兼底：用 `pgrep -x mux0` 拿到候选 pid，再用 `lsof -p <pid> -a -d txt` 问内核
  到底映射了哪个镜像。它只是**额外一路**，验不过路径就不计 —— 宁可不拦，不可误拦。
  注意 `ps -ax -o comm= -p <pid>` 是陷阱：带上 `-ax` 后 BSD ps 会忽略 `-p` 把所有进程都列出来。
- 回归测试：`Resources/agent-hooks/tests/installer_running_check.sh`（含一个“PATH 上
  的 `pgrep` 返回空”的代用环境，就是用户本机那个现场）。

### 装机冒烟

打完整跑一遍（构建机无 GUI 会话时，`open` 会把 app 起在当前用户的 Aqua 会话里）：

```bash
./dist/install.sh --dry-run && ./dist/install.sh --no-open
# 看活着的进程一律用路径，不用 pgrep/pkill 的名字匹配（上面说过它在某些机器上会漏）
MUX0_EXE='/mux0.app/Contents/MacOS/mux0'
open -n /Applications/mux0.app && sleep 15
ps -ax -o pid=,comm= | grep -F "$MUX0_EXE"                     # 还活着才算过
ls -l ~/Library/Caches/mux0/hooks-*.sock                        # hook socket 已建立
pkill -f "$MUX0_EXE"
```

### Appcast 格式

单 `<item>` 格式，由 `.github/scripts/render-appcast.sh` 从 release notes + `sign_update` 输出填模板生成。详见工作流文件。
