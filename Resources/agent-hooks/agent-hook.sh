#!/bin/bash
# agent-hook.sh — thin bash entry for agent-hook.py.
# Usage: agent-hook.sh <subcommand> <agent>
#   subcommand: prompt | pretool | posttool | stop
#   agent:      claude | codex
#
# Reads the hook's JSON payload from stdin and forwards it to the Python
# script via an env var, along with the subcommand / agent / session file
# path. All dispatch logic lives in agent-hook.py so it can be unit-tested.

set -e

[ -z "$MUX0_HOOK_SOCK" ] && exit 0
[ -z "$MUX0_TERMINAL_ID" ] && exit 0

subcmd="${1:-stop}"
agent="${2:-claude}"
# Locate agent-hook.py next to this script. `${BASH_SOURCE[0]}` is empty when a
# non-bash shell starts us (`zsh agent-hook.sh …`), which used to resolve to "."
# and make python3 fail on ./agent-hook.py — a hook that silently stops
# reporting. Fall back to $0 and absolutize so relative invocations work too.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

export _MUX0_SUBCMD="$subcmd"
export _MUX0_AGENT="$agent"
export _MUX0_SESSION_FILE="${HOME}/Library/Caches/mux0/agent-sessions.json"

# Forward the full stdin JSON as an env var. Payloads are small (<4k).
export _MUX0_PAYLOAD
_MUX0_PAYLOAD=$(cat)

exec python3 "$script_dir/agent-hook.py"
