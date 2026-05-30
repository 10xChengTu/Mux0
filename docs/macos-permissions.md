# macOS 权限继承（TCC / Responsible Process）

> 让从 mux0 终端里启动的子进程，能复用 mux0 自身被授予的麦克风 / 摄像头 / 屏幕录制权限——和 VS Code 集成终端的行为一致。

## 背景：macOS 怎么决定权限归属

macOS 的 TCC（Transparency, Consent, and Control）管理隐私权限（麦克风、摄像头、屏幕录制、Documents 文件夹等）。它**不是看「谁发起了调用」，而是沿进程树向上找「负责进程（responsible process）」**，把授权弹窗、授予结果都归到那个进程头上并持久化。

终端 app 的进程树通常是：

```
mux0.app  ──spawn──▶  zsh  ──exec──▶  npm / tauri dev / electron …  ──▶ 调用麦克风
```

子进程默认**不会**切断这条归属链，所以最底层那个真正调麦克风的程序，TCC 会一路向上认到 `mux0.app`。这意味着：

- 只要 **mux0 自己被授权**，dev 模式下从终端直接 exec 出来的子进程就**自动复用**这份授权，不会被单独拦。
- 反之，如果 mux0 自己没法被授权，子进程的请求就会被静默拒绝（弹窗都弹不出来）。

### 为什么 VS Code 能用而早期 mux0 不能

VS Code（Code.app）spawn 子进程时没有切断归属，所以子进程认到 Code.app；只要 Code 被授权，dev app 就继承。

早期 mux0 缺的**不是传递机制**，而是 mux0 自己**根本没法被授予**麦克风/摄像头：
- `Info.plist` 没有对应的 Usage Description → 系统无法以 mux0 名义弹出授权框；
- hardened runtime 没开音视频设备 entitlement。

结果就是子进程请求麦克风 → 系统要以 mux0 名义弹窗 → 找不到用途描述 / entitlement → 静默拒绝。

### 关于 disclaim（为什么不用动 libghostty）

macOS 提供 `responsibility_spawnattrs_setdisclaim(attrs, 1)`，可以让 spawn 出来的子进程「自立门户」、成为自己的负责进程（每个程序各自弹各自的权限框，Terminal.app / iTerm2 是这个行为）。

ghostty 把它列为[一个尚未落地的提案（#9263）](https://github.com/ghostty-org/ghostty/issues/9263)——因为 `posix_spawn` 没法同时做 `setsid` + `ioctl(TIOCSCTTY)`，实现起来有阻碍。**当前 libghostty 并没有 disclaim**，所以归属链天然认到 `mux0.app`，传递机制是现成的，mux0 侧不需要改 ghostty 引擎。

## mux0 的实现

让 mux0 成为「可被授权的负责进程」只需声明两类元数据，分散在两个文件：

### 1. `mux0/mux0.entitlements` — hardened runtime 资源访问

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.automation.apple-events</key>
<true/>
```

mux0 开了 hardened runtime（`ENABLE_HARDENED_RUNTIME: YES`），不声明这些 device entitlement 的话，进程访问对应资源会被运行时拦死。`automation.apple-events` 是 hardened runtime 下**发送** Apple Events 的必备项（仅有 `NSAppleEventsUsageDescription` 不够）。

> 这套声明刻意和 **VS Code** 完全一致：VS Code（`Visual Studio Code.app`）声明的就是 `device.audio-input` / `device.camera` / `automation.apple-events` + 对应 Usage Description，靠 responsible-process 被动继承让子进程拿到权限——**没有**任何自定义「权限面板 / 自动探测子进程缺权限」的逻辑（macOS 也没有这种 API）。
>
> **屏幕录制刻意不声明 entitlement / Usage Description**：macOS 的屏幕录制只能由用户在系统设置里手动给宿主 app 打勾，无法用 entitlement 或弹框授予。实测 VS Code 也未声明任何屏幕录制相关 key，里面跑的录屏项目照样能用——证明只要 mux0 自己被手动授予屏幕录制，子进程即可继承。所以这里不多此一举。

### 2. `project.yml` → `info.properties`（生成 `mux0/Info.plist`）— Usage Description

```yaml
NSMicrophoneUsageDescription: "..."     # 麦克风
NSCameraUsageDescription: "..."         # 摄像头
NSAudioCaptureUsageDescription: "..."   # 系统音频采集（ScreenCaptureKit）
NSAppleEventsUsageDescription: "..."    # Apple Events 自动化（控制其它 app）
```

没有这些 key，系统弹不出以 mux0 名义的授权框，子进程的请求被静默拒绝。

### 辅助功能（Accessibility）是特例

合成按键 / 监听全局快捷键（`CGEventTap`、`AXIsProcessTrustedWithOptions`、合成 keystroke）走的是 **Accessibility** 权限——它**既没有** Usage Description key，**也没有** entitlement，只能由用户手动把 **mux0** 加进「系统设置 › 隐私与安全性 › 辅助功能」。

这也是 responsible-process 继承里**最不可靠**的一项：Apple 对 Accessibility 收得很紧，子进程能否借用 mux0 的授权并不稳定。如果将来要让 mux0 可靠地为子进程托管 Accessibility，可能需要 mux0 自己主动调一次 `AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: true})` 弹出系统引导框，把 mux0 显式登记进列表。

## 仓库内已知会用到这些权限的子 app

| App | 形态 | 需要的权限 |
|-----|------|-----------|
| `repos/input0` | Tauri 语音输入 | 麦克风、Apple Events 自动化、**Accessibility**（全局快捷键 + 合成按键） |
| `repos/clip0` | Electron 录屏/剪辑 | 麦克风、摄像头、屏幕录制、系统音频采集、**Accessibility**（光标采样） |

把这两个 app 在 dev 模式下从 mux0 启动时，上面 mux0 声明的 entitlement/Usage Description 已覆盖除 Accessibility 外的全部；Accessibility 需用户手动给 mux0 开。

> ⚠️ Usage Description 的源头是 `project.yml`，不是手改 `Info.plist`。改完要 `xcodegen generate` 重新生成。`project.yml` 是受限文件，改动需人工确认。

### 验证签名后确实带上了 entitlements

```bash
APP="$(...)/Build/Products/Debug/mux0.app"
codesign -d --entitlements - "$APP" | grep -i "audio-input\|device.camera"
```

## 给最终用户的步骤（无法由代码自动完成）

1. **首次授权（弹窗类）**：在 mux0 终端里跑一个会用麦克风/摄像头/自动化的程序，系统会以 **Mux0** 名义弹窗 → 允许。
2. **屏幕录制 / 辅助功能（不弹窗类）**：去 **系统设置 › 隐私与安全性**，在「屏幕录制」和「辅助功能」里手动把 **Mux0** 打开。
3. 之后从 mux0 dev 模式启动的子进程就会继承这些授权（Accessibility 见上文「特例」的可靠性说明）。

## 限制

- **只对直接 exec 的子进程生效**。如果子进程是用 `open -a SomeApp.app` 启动的独立 `.app`，它会经 LaunchServices 拿到**自己**的身份，**不继承** mux0（VS Code 同样如此）。
- **授权绑定签名身份 + bundle id**。Debug 用的是临时开发签名；换成 Release 正式签名、或更换签名身份后，需要重新授权一次。
