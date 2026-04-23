#!/bin/bash
# Build libghostty static library from ghostty source.
# Must be run once before opening the Xcode project.
#
# Requires: zig 0.15.2（严格要求）。
#   - ghostty build.zig 的 requireZig 固定 v0.15.2
#   - zig 0.16 的 Dir.readFileAlloc 参数签名变化会直接让上游 build.zig 编译失败
#   - Homebrew 的 `brew install zig` 目前拉的是 0.16.0，不能用
# 建议装法：mise / asdf / https://ziglang.org/download/ 下 0.15.2。
#
# TODO(zig-unpin): 上游 ghostty 适配 zig 0.16+ 后，同步放宽这里与
# .github/workflows/release.yml、docs/build.md 里的版本锁。
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_SRC="/tmp/ghostty-src"

if [ ! -d "$GHOSTTY_SRC" ]; then
  git clone https://github.com/ghostty-org/ghostty "$GHOSTTY_SRC"
fi

cd "$GHOSTTY_SRC"
# -Demit-macos-app=false skips building Ghostty.app (we only need libghostty),
# avoiding unrelated x86_64 Swift compile failures in upstream ghostty.
zig build -Doptimize=ReleaseFast -Demit-macos-app=false

mkdir -p "$PROJECT_DIR/Vendor/ghostty/include"
mkdir -p "$PROJECT_DIR/Vendor/ghostty/lib"

# Modern ghostty places the universal (arm64+x86_64) static lib and headers
# inside GhosttyKit.xcframework rather than zig-out/lib.
XCFW="$GHOSTTY_SRC/macos/GhosttyKit.xcframework/macos-arm64_x86_64"
if [ -f "$XCFW/ghostty-internal.a" ]; then
  cp "$XCFW/Headers/ghostty.h" "$PROJECT_DIR/Vendor/ghostty/include/"
  cp "$XCFW/ghostty-internal.a" "$PROJECT_DIR/Vendor/ghostty/lib/libghostty.a"
elif [ -f "$GHOSTTY_SRC/zig-out/lib/libghostty.a" ]; then
  # Legacy ghostty layout fallback
  cp "$GHOSTTY_SRC/zig-out/include/ghostty.h" "$PROJECT_DIR/Vendor/ghostty/include/"
  cp "$GHOSTTY_SRC/zig-out/lib/libghostty.a" "$PROJECT_DIR/Vendor/ghostty/lib/"
elif [ -f "$GHOSTTY_SRC/zig-out/lib/libghostty.dylib" ]; then
  cp "$GHOSTTY_SRC/zig-out/include/ghostty.h" "$PROJECT_DIR/Vendor/ghostty/include/"
  cp "$GHOSTTY_SRC/zig-out/lib/libghostty.dylib" "$PROJECT_DIR/Vendor/ghostty/lib/"
else
  echo "ERROR: libghostty not found in either GhosttyKit.xcframework or $GHOSTTY_SRC/zig-out/lib/" >&2
  exit 1
fi

# Shell integration scripts (OSC 133 injection for zsh/bash/fish).
# Ghostty builds its "share/" dir via a separate step; run it and copy the tree.
# NOTE: intentionally NOT using rsync --delete here — upstream layout changes
# between ghostty versions must not wipe our injected themes (see below).
mkdir -p "$PROJECT_DIR/Vendor/ghostty/share"
if [ -d "$GHOSTTY_SRC/zig-out/share/ghostty" ]; then
  rsync -a "$GHOSTTY_SRC/zig-out/share/ghostty/" "$PROJECT_DIR/Vendor/ghostty/share/ghostty/"
elif [ -d "$GHOSTTY_SRC/src/shell-integration" ]; then
  # Copy source tree directly (same content, unprocessed)
  mkdir -p "$PROJECT_DIR/Vendor/ghostty/share/ghostty"
  rsync -a "$GHOSTTY_SRC/src/shell-integration/" "$PROJECT_DIR/Vendor/ghostty/share/ghostty/shell-integration/"
else
  echo "WARN: no shell-integration dir found in $GHOSTTY_SRC" >&2
fi

# Inject themes: ghostty theme .conf files are static config the Settings UI
# depends on. They must always exist in Vendor/share/ghostty/themes even when
# upstream's zig-out/share does not ship them (e.g. under -Demit-macos-app=false).
THEMES_DST="$PROJECT_DIR/Vendor/ghostty/share/ghostty/themes"
if [ ! -d "$THEMES_DST" ] || [ -z "$(ls -A "$THEMES_DST" 2>/dev/null)" ]; then
  for candidate in \
    "$GHOSTTY_SRC/zig-out/share/ghostty/themes" \
    "$GHOSTTY_SRC/vendor/iTerm2-Color-Schemes/ghostty" \
    "$GHOSTTY_SRC/third_party/iterm2-color-schemes/ghostty"; do
    if [ -d "$candidate" ] && [ -n "$(ls -A "$candidate" 2>/dev/null)" ]; then
      mkdir -p "$THEMES_DST"
      rsync -a "$candidate/" "$THEMES_DST/"
      echo "Injected themes from $candidate"
      break
    fi
  done
  if [ ! -d "$THEMES_DST" ] || [ -z "$(ls -A "$THEMES_DST" 2>/dev/null)" ]; then
    echo "WARN: no themes found in $GHOSTTY_SRC; Vendor/ghostty/share/ghostty/themes is empty" >&2
  fi
fi

echo "Done. Vendor/ghostty populated."
