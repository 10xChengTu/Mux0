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

# Overlay CODEX_HOME path is STABLE per-user (not per-launch, not per-tab) so
# codex's `/hooks` trust state — keyed by `<hooks.json absolute path>:event:i:j`
# in ~/.codex/config.toml — survives mux0 restarts and is shared across every
# codex tab. This aligns with native codex semantics (trust ~/.codex/hooks.json
# once per user). We can't reuse the user's real CODEX_HOME directly because
# we'd clobber any user-authored hooks.json (and leave it behind on SIGKILL).
USER_HOME="${CODEX_HOME:-$HOME/.codex}"
OVERLAY="$HOME/Library/Caches/mux0/codex-overlay"
mkdir -p "$OVERLAY"

# Sync any regular files left in OVERLAY back to USER_HOME before re-symlinking.
# These come from either: (a) a previous codex session whose EXIT trap didn't
# run (SIGKILL), or (b) another mux0-launched codex still running that wrote
# config.toml via `tempfile + rename(2)` since starting. Doing this BEFORE the
# `ln -sfn` below means we don't lose those writes when we force-replace the
# regular file with a symlink. (Tiny residual race: a write that lands between
# our cp and our ln gets clobbered, but that writer's own EXIT trap will cp it
# back when it eventually exits.)
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

# (Re)build symlinks so reads see the user's data. `ln -sfn` atomically replaces
# any existing entry (symlink or regular file) — safe because we just synced
# regular files back above. Codex persists config.toml via `tempfile + rename(2)`,
# which atomically REPLACES the directory entry; the cleanup trap below detects
# symlink→regular promotion and copies the result back to USER_HOME. Notify is
# injected per-process via codex's `-c key=value` CLI override (see exec line
# below) so we never need to touch config.toml ourselves.
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
    # Codex persists state files (config.toml, possibly others) via
    # `tempfile + rename(2)`, which atomically REPLACES the symlink we placed
    # in the overlay with a regular file. Any top-level entry that's now a
    # regular file (not a symlink) is something codex wrote during this
    # session; copy it back to the user's real CODEX_HOME. This is what lets
    # `codex features enable`, `codex login`, and (notably) hook trust
    # approvals from `/hooks` persist — though with the stable OVERLAY path,
    # trust approvals also persist by virtue of the path itself not changing.
    #
    # hooks.json is excluded because we wrote it ourselves into the overlay
    # and the user's real CODEX_HOME shouldn't grow a mux0-managed file.
    #
    # The overlay directory itself is NOT deleted: it's shared across every
    # mux0-launched codex process (so trust keys stay stable). Regular files
    # are left in place too — the next launch's pre-symlink sync (above) will
    # cp them back to USER_HOME and then `ln -sfn` will atomically replace
    # them with symlinks.
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
