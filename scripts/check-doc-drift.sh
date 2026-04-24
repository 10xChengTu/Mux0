#!/usr/bin/env bash
#
# check-doc-drift.sh
#
# 对比 CLAUDE.md 的 `Directory Structure` 代码块中列出的 Swift 文件名集合，与
# 真实 mux0/ 下深度 ≤ 2 的 Swift 文件集合。发现差异时退出非零并打印 diff，
# 目的是强制"结构变化必须同步文档"这条约定（见 docs/conventions.md）。
#
# 限制：
#   1. 只对比 basename，不校验目录归属。mux0/ 内目前没有同名 Swift 文件，
#      所以足够用；如将来引入同名文件请升级成 path 对比。
#   2. 跳过深度 > 2 的子目录（当前只有 Settings/Components/, Settings/Sections/）
#      —— 它们在 CLAUDE.md 中刻意按"目录级总结"的形式记录而非逐文件列。
#
# 用法：
#   ./scripts/check-doc-drift.sh        # 有漂移时退出 1
#   ./scripts/check-doc-drift.sh --ci   # 同上，但输出更机读

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
claude_md="$root/CLAUDE.md"
mux_dir="$root/mux0"

if [[ ! -f "$claude_md" ]]; then
  echo "check-doc-drift: CLAUDE.md not found at $claude_md" >&2
  exit 2
fi
if [[ ! -d "$mux_dir" ]]; then
  echo "check-doc-drift: mux0/ not found at $mux_dir" >&2
  exit 2
fi

# Extract Swift basenames from the fenced ``` block that follows the
# "## Directory Structure" heading in CLAUDE.md. We can't just take the first
# block because Quick Start also uses a ``` fence.
doc_files="$(
  awk '
    /^## Directory Structure[[:space:]]*$/ { in_section = 1; next }
    in_section && /^```/ {
      if (capturing) { exit }
      capturing = 1
      next
    }
    capturing { print }
  ' "$claude_md" \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*\.swift' \
  | sort -u
)"

if [[ -z "$doc_files" ]]; then
  echo "check-doc-drift: could not locate Directory Structure block in CLAUDE.md" >&2
  exit 2
fi

# Actual Swift basenames at depth ≤ 2 under mux0/.
real_files="$(
  find "$mux_dir" -maxdepth 2 -name '*.swift' -type f -exec basename {} \; \
  | sort -u
)"

missing_from_docs="$(comm -13 <(printf '%s\n' "$doc_files") <(printf '%s\n' "$real_files"))"
stale_in_docs="$(comm -23 <(printf '%s\n' "$doc_files") <(printf '%s\n' "$real_files"))"

status=0

if [[ -n "$missing_from_docs" ]]; then
  echo "Swift files on disk but NOT in CLAUDE.md Directory Structure:"
  printf '  + %s\n' $missing_from_docs
  status=1
fi

if [[ -n "$stale_in_docs" ]]; then
  echo "CLAUDE.md Directory Structure lists Swift files that NO LONGER exist:"
  printf '  - %s\n' $stale_in_docs
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "CLAUDE.md Directory Structure matches mux0/ Swift files (depth ≤ 2)."
fi

# Landing-page 版本号必须与 project.yml 的 MARKETING_VERSION 一致。
# 同步脚本见 scripts/sync-landing-version.sh。
if ! "$here/sync-landing-version.sh" --check; then
  status=1
fi

exit $status
