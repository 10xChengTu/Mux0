#!/bin/bash
# grok-wrapper.sh — launch Grok CLI (xAI) with mux0 lifecycle hooks injected
# through a private GROK_HOME overlay, mirroring codex-wrapper.sh.
#
# Why a GROK_HOME overlay instead of a CLI flag or env overlay?
# Grok has no `--settings`-style flag, and its per-process config overlay
# (`GROK_CONFIG` / `GROK_CONFIG_PATH`) is deliberately fail-closed: the merged
# overlay only reaches an allowlist of soft settings (`models`, `features`, a
# narrowed `toolset`, filter fields of `shell_environment_policy`) and every
# other table — `hooks` included — is dropped at the choke point, so hooks
# cannot be injected that way. `GROK_HOME` (docs 05-configuration.md) relocates
# the whole config directory, which is exactly the CODEX_HOME trick: we build a
# directory of symlinks back to the user's real ~/.grok plus ONE file of our
# own, `hooks/mux0.json`.
#
# Why global scope rather than `<repo>/.grok/hooks`?
# Project-scoped hooks are gated by folder trust and are silently skipped until
# the user runs `/hooks-trust` — plus they write into the user's repository.
# Hooks under `$GROK_HOME/hooks/*.json` are "Always trusted" (docs 10-hooks.md,
# Hook Locations), so the mux0 hook works in every directory with zero setup.
#
# Why symlink the user's files instead of copying?
# So login state (agent_id), config.toml, trusted_folders.toml and — critically —
# `sessions/` stay the user's real ones: a session started inside mux0 is
# listed by `grok --resume` outside mux0, and the generated session title
# (`sessions/**/summary.json`, which agent-hook.py reads) lands in the user's
# real session store. Grok persists some of these via `tempfile + rename(2)`,
# which replaces the symlink with a regular file, so the wrapper syncs regular
# files back to the real home before re-linking (startup) and again on exit —
# the same dance codex-wrapper.sh does for `~/.codex/config.toml`.
#
# Known limitation: with `--sandbox <profile>` grok refuses a symlinked
# $GROK_HOME (docs 18-sandbox.md). Sandbox mode is opt-in; in that mode the
# status hooks are skipped by grok, not broken by us.
#
# Reads MUX0_AGENT_HOOKS_DIR, MUX0_HOOK_SOCK, MUX0_TERMINAL_ID from env.

set -e

{
    echo "[$(date +%s)] [grok-wrapper] invoked: args=$*  MUX0_AGENT_HOOKS_DIR=${MUX0_AGENT_HOOKS_DIR:+set}  MUX0_HOOK_SOCK=${MUX0_HOOK_SOCK:+set}  MUX0_TERMINAL_ID=${MUX0_TERMINAL_ID:+set}"
} >> "$HOME/Library/Caches/mux0/hook-emit.log" 2>/dev/null || true

REAL_GROK=""
if [ -n "$MUX0_REAL_GROK" ] && [ -x "$MUX0_REAL_GROK" ]; then
    REAL_GROK="$MUX0_REAL_GROK"
else
    for candidate in $(which -a grok 2>/dev/null); do
        resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        case "$resolved" in
            *mux0*agent-hooks*grok-wrapper*) continue ;;
        esac
        case "$candidate" in
            *mux0*agent-hooks*grok-wrapper*) continue ;;
        esac
        REAL_GROK="$candidate"
        break
    done
fi

if [ -z "$REAL_GROK" ]; then
    echo "mux0 grok-wrapper: real 'grok' binary not found in PATH" >&2
    echo "  hint: install Grok CLI, or set MUX0_REAL_GROK to its path" >&2
    exit 127
fi

# Passthrough when mux0's env is missing (wrapper reached from another terminal).
if [ -z "$MUX0_AGENT_HOOKS_DIR" ] || [ -z "$MUX0_HOOK_SOCK" ] || [ -z "$MUX0_TERMINAL_ID" ]; then
    exec "$REAL_GROK" "$@"
fi

# Subcommand / management passthrough. These subcommands never run an agent
# turn (`models`, `mcp`, `plugin`, …) or manage the real ~/.grok themselves
# (`login`, `setup`, `update`), where a relocated GROK_HOME would be at best
# pointless and at worst write credentials into the overlay.
#
# Session entry points deliberately fall THROUGH to injection: bare `grok`,
# `grok "<prompt>"`, `grok -p …`, `grok --resume …`, `grok --continue`.
# A prompt is a single argv string, so an exact-match `case` can never trip on
# prose like `grok "please update the tests"`.
PRINT_MODE=0
for arg in "$@"; do
    case "$arg" in
        -p|--single|--prompt-file|--prompt-json|-r|--resume|-c|--continue|--session-id|-s|--worktree|-w)
            PRINT_MODE=1; break ;;
    esac
done

if [ "$PRINT_MODE" = "0" ]; then
    for arg in "$@"; do
        case "$arg" in
            agent|clone|completions|cursor-worker|dashboard|doctor|du|disk-usage|export|help|--help|-h|--version|-v|version|inspect|leader|login|logout|mcp|memory|models|plugin|plugins|sessions|setup|trace|update|upgrade|usage|worktree|wrap)
                exec "$REAL_GROK" "$@"
                ;;
        esac
    done
fi

EMIT="$MUX0_AGENT_HOOKS_DIR/hook-emit.sh"
AGENT_HOOK="$MUX0_AGENT_HOOKS_DIR/agent-hook.sh"

USER_HOME="${GROK_HOME:-$HOME/.grok}"
# STABLE path (not per-launch, not per-tab): the hook file's absolute path is
# what shows up in grok's `/hooks` panel, and a stable path keeps the overlay
# out of `grok du` noise and lets several mux0 grok tabs share one directory.
OVERLAY="$HOME/Library/Caches/mux0/grok-overlay"
mkdir -p "$OVERLAY"
mkdir -p "$USER_HOME"

# --- sync: any regular file in the overlay is something a previous grok run
# wrote through a renamed symlink (`.metadata_version`, `config.toml` after
# `grok login`, …). Copy it back BEFORE re-linking so the write isn't lost.
sync_overlay_back() {
    [ -d "$OVERLAY" ] || return 0
    for item in "$OVERLAY"/* "$OVERLAY"/.[!.]* "$OVERLAY"/..?*; do
        [ -e "$item" ] || continue
        [ -L "$item" ] && continue
        [ -f "$item" ] || continue          # dirs / sockets stay out
        name=$(basename "$item")
        case "$name" in
            hooks|hooks.json|mux0.json) continue ;;
            *.sock) continue ;;
        esac
        mkdir -p "$USER_HOME"
        cp -f "$item" "$USER_HOME/$name" 2>/dev/null || true
    done
}

sync_overlay_back

# --- (re)build the symlink mirror of the user's real ~/.grok.
if [ -d "$USER_HOME" ]; then
    for item in "$USER_HOME"/* "$USER_HOME"/.[!.]* "$USER_HOME"/..?*; do
        [ -e "$item" ] || continue
        name=$(basename "$item")
        case "$name" in
            hooks) continue ;;               # we own hooks/ (see below)
            .|..) continue ;;
        esac
        ln -sfn "$item" "$OVERLAY/$name"
    done
fi

# --- hooks/: our own directory, containing the user's global hooks (symlinked
# one by one so user-authored hooks keep firing inside mux0) plus mux0.json.
mkdir -p "$OVERLAY/hooks"
if [ -d "$USER_HOME/hooks" ]; then
    for hook in "$USER_HOME"/hooks/*.json; do
        [ -e "$hook" ] || continue
        ln -sfn "$hook" "$OVERLAY/hooks/$(basename "$hook")"
    done
fi

# Hook commands. Grok's stdin envelope is Claude-compatible — it emits BOTH the
# camelCase originals and snake_case aliases (`session_id`, `tool_name`,
# `tool_input`, `tool_response`, `transcript_path`, `hook_event_name`), so
# agent-hook.py consumes it unchanged apart from the grok-only events below.
# `timeout` is explicit because grok defaults observe hooks to 5s and Stop
# gates to 600s; a socket write is a local syscall, 10s is generous.
cat > "$OVERLAY/hooks/mux0.json" <<EOF
{
  "hooks": {
    "SessionStart":       [{"hooks":[{"type":"command","command":"$EMIT idle grok","timeout":10}]}],
    "UserPromptSubmit":   [{"hooks":[{"type":"command","command":"$AGENT_HOOK prompt grok","timeout":10}]}],
    "PreToolUse":         [{"hooks":[{"type":"command","command":"$AGENT_HOOK pretool grok","timeout":10}]}],
    "PostToolUse":        [{"hooks":[{"type":"command","command":"$AGENT_HOOK posttool grok","timeout":10}]}],
    "PostToolUseFailure": [{"hooks":[{"type":"command","command":"$AGENT_HOOK posttoolfailure grok","timeout":10}]}],
    "PermissionDenied":   [{"hooks":[{"type":"command","command":"$AGENT_HOOK permissiondenied grok","timeout":10}]}],
    "Notification":       [{"hooks":[{"type":"command","command":"$AGENT_HOOK notification grok","timeout":10}]}],
    "Stop":               [{"hooks":[{"type":"command","command":"$AGENT_HOOK stop grok","timeout":10}]}],
    "StopFailure":        [{"hooks":[{"type":"command","command":"$AGENT_HOOK stopfailure grok","timeout":10}]}],
    "StopCancelled":      [{"hooks":[{"type":"command","command":"$AGENT_HOOK stopcancelled grok","timeout":10}]}],
    "SessionEnd":         [{"hooks":[{"type":"command","command":"$AGENT_HOOK sessionend grok","timeout":10}]}]
  }
}
EOF

# Point grok at the overlay for THIS process only.
export GROK_HOME="$OVERLAY"

cleanup() {
    sync_overlay_back
    "$EMIT" idle grok 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# See codex-wrapper.sh: grok sits idle at its prompt on launch, and shell
# preexec already put the terminal in "running".
"$EMIT" idle grok 2>/dev/null || true

# Subprocess + wait (NOT exec): bash's EXIT trap is dead code after exec, and
# the cleanup above is what returns overlay-written files to ~/.grok.
EXIT_CODE=0
"$REAL_GROK" "$@" || EXIT_CODE=$?
exit "$EXIT_CODE"
