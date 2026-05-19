#!/bin/bash
# codex-wrapper.sh — launch OpenAI Codex CLI with mux0 notify + experimental hooks.
# Written from scratch for mux0.

set -e

REAL_CODEX=""
if [ -n "$MUX0_REAL_CODEX" ] && [ -x "$MUX0_REAL_CODEX" ]; then
    REAL_CODEX="$MUX0_REAL_CODEX"
else
    for candidate in $(which -a codex 2>/dev/null); do
        resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        case "$resolved" in
            *mux0*agent-hooks*codex-wrapper*) continue ;;
        esac
        REAL_CODEX="$candidate"
        break
    done
fi

if [ -z "$REAL_CODEX" ]; then
    echo "mux0 codex-wrapper: real 'codex' binary not found in PATH" >&2
    echo "  hint: install OpenAI Codex CLI, or set MUX0_REAL_CODEX" >&2
    exit 127
fi

# Passthrough when mux0 env is missing.
if [ -z "$MUX0_AGENT_HOOKS_DIR" ] || [ -z "$MUX0_HOOK_SOCK" ] || [ -z "$MUX0_TERMINAL_ID" ]; then
    exec "$REAL_CODEX" "$@"
fi

EMIT="$MUX0_AGENT_HOOKS_DIR/hook-emit.sh"
AGENT_HOOK="$MUX0_AGENT_HOOKS_DIR/agent-hook.sh"

# Create an overlay CODEX_HOME so we don't mutate the user's real config.
OVERLAY=$(mktemp -d -t mux0-codex.XXXXXX)

# Symlink user's real CODEX_HOME contents into the overlay so reads see the
# user's data. Note: Codex persists config.toml via `tempfile + rename(2)`,
# which atomically REPLACES the directory entry — symlinks get clobbered
# instead of followed. So a symlink alone isn't enough to make writes persist;
# the cleanup trap below detects when the symlink got replaced by a regular
# file (= codex rewrote it) and copies it back to the real CODEX_HOME.
# Notify is injected per-process via codex's `-c key=value` CLI override
# (see exec line below) so we never need to touch config.toml ourselves.
USER_HOME="${CODEX_HOME:-$HOME/.codex}"
if [ -d "$USER_HOME" ]; then
    for item in "$USER_HOME"/*; do
        [ -e "$item" ] || continue
        name=$(basename "$item")
        case "$name" in
            hooks.json) continue ;;   # we override this below
        esac
        ln -sfn "$item" "$OVERLAY/$name"
    done
fi
# If the user has no config.toml yet, create a dangling symlink. If codex
# writes via rename, the cleanup trap below will sync the resulting file back.
if [ ! -e "$OVERLAY/config.toml" ] && [ ! -L "$OVERLAY/config.toml" ]; then
    mkdir -p "$USER_HOME"
    ln -sfn "$USER_HOME/config.toml" "$OVERLAY/config.toml"
fi

# Write experimental hooks.json. If the user hasn't enabled features.codex_hooks,
# this file is silently ignored by Codex — no harm done.
#
# Schema: Codex uses the same nested shape as Claude Code. Each event maps to
# an array of matcher-groups; each group has a `hooks` array of {type, command}.
# The parser uses serde's deny_unknown_fields, so any stray key (or the flat
# {"command": "..."} shape) causes Codex to silently skip the entire file.
# Source: codex-rs/hooks/src/engine/config.rs.
cat > "$OVERLAY/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart":     [{"hooks": [{"type": "command", "command": "$EMIT idle codex"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$AGENT_HOOK prompt codex"}]}],
    "PreToolUse":       [{"hooks": [{"type": "command", "command": "$AGENT_HOOK pretool codex"}]}],
    "PostToolUse":      [{"hooks": [{"type": "command", "command": "$AGENT_HOOK posttool codex"}]}],
    "Stop":             [{"hooks": [{"type": "command", "command": "$AGENT_HOOK stop codex"}]}]
  }
}
EOF

# Point Codex at the overlay.
export CODEX_HOME="$OVERLAY"

# Clean up on exit (normal, interrupt, or crash).
# Also mark the terminal idle on exit — otherwise the precmd hook has to fire
# before the icon updates, which can lag if the user closes the window.
cleanup() {
    # Codex persists state files (config.toml, hooks.state, possibly others)
    # via `tempfile + rename(2)`, which atomically REPLACES the symlink we
    # placed in the overlay with a regular file. Any top-level entry that's
    # now a regular file (not a symlink) is something codex wrote during this
    # session; copy it back to the user's real CODEX_HOME so it survives the
    # `rm -rf` below. This is what lets `codex features enable`, `codex
    # login`, and — most importantly — hook trust approvals from `/hooks`
    # persist across mux0-launched codex sessions.
    #
    # hooks.json is excluded because we wrote it ourselves into the overlay
    # and the user's real CODEX_HOME shouldn't grow a mux0-managed file.
    if [ -d "$OVERLAY" ]; then
        for item in "$OVERLAY"/*; do
            [ -f "$item" ] || continue
            [ -L "$item" ] && continue
            name=$(basename "$item")
            case "$name" in
                hooks.json) continue ;;
            esac
            mkdir -p "$USER_HOME"
            cp -f "$item" "$USER_HOME/$name" 2>/dev/null || true
        done
    fi
    rm -rf "$OVERLAY" 2>/dev/null || true
    "$EMIT" idle codex 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Emit idle BEFORE handing off to codex: shell preexec already marked us
# running when the user typed `codex`, but codex's own `notify` only fires
# on turn completion. Without this, the UI sits on "running" from launch
# until the first turn completes — wrong, since codex is actually idle at
# its input prompt.
"$EMIT" idle codex 2>/dev/null || true

# Run codex as a subprocess instead of `exec`ing it. `exec` would replace
# this bash process entirely, and bash does NOT fire EXIT/INT/TERM traps
# after a successful exec — the overlay below would leak in $TMPDIR and,
# more importantly, the cleanup trap would never copy codex's persisted
# state files (hooks.state for `/hooks` trust approvals, config.toml for
# `codex login` / `codex features enable`) back to the user's real
# CODEX_HOME. The next mux0-launched codex session would then see a fresh
# untrusted state and silently never run any hook.
#
# `notify` is injected via -c so we don't have to mutate the user's
# config.toml. Codex's `-c key=value` parses value as TOML; arrays work
# (see `codex --help`).
#
# `|| EXIT_CODE=$?` consumes a non-zero exit so `set -e` (top of file) does
# not short-circuit before we forward the code via the final `exit`.
EXIT_CODE=0
"$REAL_CODEX" -c "notify=[\"$EMIT\", \"idle\", \"codex\"]" "$@" || EXIT_CODE=$?
exit "$EXIT_CODE"
