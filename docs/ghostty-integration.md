# libghostty Integration

## Overview

mux0 通过 libghostty C API 实现终端渲染。libghostty 以静态库（`.a`）形式提供，链接到 mux0 target。

## 文件位置

```
Vendor/ghostty/
├── include/ghostty.h    — C API 头文件
└── lib/libghostty.a     — 静态库（gitignored，首次需手动构建）
mux0/Ghostty/
└── ghostty-bridging-header.h   — Swift bridging header，#import "ghostty.h"
```

## 首次构建

```bash
./scripts/build-vendor.sh
```

此脚本从源码编译 libghostty 并放到 `Vendor/` 目录。构建一次后无需重复（除非升级 ghostty 版本）。

## API 生命周期

```
ghostty_init(argc, argv)          — 全局初始化（只调用一次）
ghostty_config_new()              — 创建配置对象
ghostty_config_load_default_files — 加载 ~/.config/ghostty/config
ghostty_config_finalize()         — 配置生效
ghostty_app_new(rtConfig, cfg)    — 创建 app 实例
    ghostty_surface_new(app, surfCfg)  — 为每个终端窗口创建 surface
    ghostty_surface_free(surface)      — 关闭终端时释放
ghostty_app_free(app)             — app 退出时释放
ghostty_config_free(cfg)          — app 退出时释放
```

所有以上调用都在 `GhosttyBridge.swift` 中封装，外部不直接调用。

## Surface 配置

创建 surface 时需要传入：
- `scale_factor` — 屏幕 DPI 缩放（`nsView.window?.backingScaleFactor ?? 2.0`）
- `working_directory` — 可选，终端初始工作目录
- `platform.macos.nsview` — 持有 surface 的 NSView（unretained pointer，NSView 必须比 surface 活得更长）

## Metal 渲染

libghostty 内部管理 Metal CALayer，直接渲染到 NSView 的 layer。
GhosttyTerminalView 需要：
1. `wantsLayer = true`
2. `layer` 不要手动替换
3. 不要在 `draw(_:)` 里画任何东西

## 输入转发

| NSView 事件 | ghostty API |
|------------|-------------|
| `keyDown(_:)` | `ghostty_surface_key(surface, ...)` |
| `mouseDown(_:)` / `mouseUp(_:)` | `ghostty_surface_mouse_button(surface, ...)` |
| `mouseMoved(_:)` / `mouseDragged(_:)` | `ghostty_surface_mouse_pos(surface, ...)` |
| `scrollWheel(_:)` | `ghostty_surface_mouse_scroll(surface, ...)` |

## 颜色读取

从 ghostty config 读颜色用于主题：
```swift
GhosttyBridge.shared.readBackground()  // → ghostty_config_color_s?
GhosttyBridge.shared.readForeground()  // → ghostty_config_color_s?
GhosttyBridge.shared.readPalette()     // → ghostty_config_palette_s?
```

`ghostty_config_color_s` 包含 `.r`/`.g`/`.b` (UInt8)，用 `GhosttyConfigReader.swift` 转换为 `NSColor`。

## 运行时回调

`ghostty_runtime_config_s` 中的回调都是 `@convention(c)` 静态函数，在 GhosttyBridge 中定义：

| 回调 | 作用 |
|------|------|
| `wakeup_cb` | 在主线程调用 `ghostty_app_tick()`，驱动渲染循环 |
| `write_clipboard_cb` | 写入 NSPasteboard |
| `read_clipboard_cb` | 目前 no-op，v1 不实现剪贴板读取 |
| `close_surface_cb` | surface 请求关闭时通知 canvas |
| `action_cb` | ghostty 内部 action 分发（CONFIG_CHANGE / CELL_SIZE / SCROLLBAR / PWD / OPEN_URL / MOUSE_SHAPE）|

### 链接交互相关 action

终端里的 URL 由 libghostty 内部识别、Cmd 判定与下划线渲染，宿主只接三处：

- `GHOSTTY_ACTION_OPEN_URL` — Cmd+点击链接时触发；宿主经 `GhosttyBridge.resolveOpenURL`
  做 scheme 白名单（http / https / mailto / file）后用 `NSWorkspace.shared.open` 打开。
- `GHOSTTY_ACTION_MOUSE_SHAPE` — 悬停链接等场景下 ghostty 通知期望光标；映射到
  `NSCursor`（POINTER→pointingHand、TEXT→iBeam、其余→arrow），经
  `GhosttyTerminalView.applyMouseShape` 应用，配合 tracking area 的 `.cursorUpdate`
  与 `cursorUpdate(with:)` override。
- 下划线高亮由 ghostty 渲染器自绘，依赖 `GhosttyTerminalView.mouseMoved` 把带修饰键的
  hover 位置转发给 `ghostty_surface_mouse_pos`（仅焦点 pane）。
  `GHOSTTY_ACTION_MOUSE_OVER_LINK` 未接入（YAGNI）。

## 升级 ghostty 版本

1. 修改 `scripts/build-vendor.sh` 中的 commit/tag
2. 运行 `./scripts/build-vendor.sh`
3. 检查 `ghostty.h` API 变更，更新 GhosttyBridge
4. 更新本文档中变更的 API
