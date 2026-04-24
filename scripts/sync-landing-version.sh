#!/usr/bin/env bash
#
# sync-landing-version.sh
#
# 把 project.yml 的 MARKETING_VERSION 同步到 landing-page/index.html。
# project.yml 是版本号唯一 source of truth（见 docs/build.md#release-流程），
# landing 里所有 "vX.Y.Z" 字样都应以它为准。
#
# 匹配规则：
#   用 perl 正则把 landing-page/index.html 中所有形如 "vMAJOR.MINOR.PATCH"
#   的字串替换成当前的 MARKETING_VERSION。只匹配前缀 v + 三段数字版本号，
#   其他内容（日期、macOS 14.4、uptime 等）都不会被误伤。
#
# 用法：
#   ./scripts/sync-landing-version.sh          # 原地改 landing-page/index.html
#   ./scripts/sync-landing-version.sh --check  # 只检查，不改（漂移时 exit 1）

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
project_yml="$root/project.yml"
landing_html="$root/landing-page/index.html"

if [[ ! -f "$project_yml" ]]; then
  echo "sync-landing-version: project.yml not found at $project_yml" >&2
  exit 2
fi
if [[ ! -f "$landing_html" ]]; then
  echo "sync-landing-version: landing-page/index.html not found at $landing_html" >&2
  exit 2
fi

version="$(grep -E '^ +MARKETING_VERSION:' "$project_yml" | awk '{print $2}' | tr -d '"')"
if [[ -z "$version" ]]; then
  echo "sync-landing-version: MARKETING_VERSION not found in project.yml" >&2
  exit 2
fi

mode="write"
if [[ "${1-}" == "--check" ]]; then
  mode="check"
fi

# Landing 里所有形如 vX.Y.Z 的版本号都应等于 $version。
stale="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$landing_html" | grep -vx "v$version" || true)"

if [[ -z "$stale" ]]; then
  # 全部已经是最新版本。
  echo "landing version already in sync: v$version"
  exit 0
fi

if [[ "$mode" == "check" ]]; then
  echo "::error::landing-page/index.html has stale version(s): $(echo "$stale" | sort -u | tr '\n' ' ')" >&2
  echo "::error::expected v$version (from project.yml MARKETING_VERSION); run ./scripts/sync-landing-version.sh" >&2
  exit 1
fi

# 原地替换：perl 比 sed 的 -i 更跨平台（macOS 与 GNU 行为一致）。
perl -i -pe "s/v[0-9]+\.[0-9]+\.[0-9]+/v$version/g" "$landing_html"
echo "synced landing-page/index.html -> v$version"
