#!/bin/bash
# pi-wrapper.sh — launch pi (pi-coding-agent) with the mux0 status extension
# injected per-process via `pi -e <extension>`.
#
# Why `-e` instead of writing to ~/.pi?
# pi discovers extensions from `~/.pi/agent/extensions/` and from the
# `extensions` list in its settings.json. Both are global: dropping a file there
# would make every pi session on the machine (including the user's own Terminal
# sessions) call back into mux0, and a SIGKILL'd wrapper would leave it behind.
# `--extension/-e` loads a file for this process only and "still works" even
# with `--no-extensions`, so the injection is invisible to the user's config and
# disappears with the process. Same trick claude-wrapper.sh plays with
# `claude --settings <json>`.
#
# Why a passthrough blocklist?
# pi's one-shot subcommands (`install`, `remove`, `list`, `config`, `auth`, …)
# manage extension settings and exit; they never start an agent turn, so hooks
# are meaningless there and `config` even opens a TUI that owns stdin. When any
# arg matches a known subcommand / help / version flag we exec untouched.
#
# Reads MUX0_AGENT_HOOKS_DIR, MUX0_HOOK_SOCK, MUX0_TERMINAL_ID from env.

set -e

{
    echo "[$(date +%s)] [pi-wrapper] invoked: args=$*  MUX0_AGENT_HOOKS_DIR=${MUX0_AGENT_HOOKS_DIR:+set}  MUX0_HOOK_SOCK=${MUX0_HOOK_SOCK:+set}  MUX0_TERMINAL_ID=${MUX0_TERMINAL_ID:+set}"
} >> "$HOME/Library/Caches/mux0/hook-emit.log" 2>/dev/null || true

# Find the real pi binary: skip shell functions, PATH entries that point back at
# this wrapper, and honour an explicit override.
REAL_PI=""
if [ -n "$MUX0_REAL_PI" ] && [ -x "$MUX0_REAL_PI" ]; then
    REAL_PI="$MUX0_REAL_PI"
else
    for candidate in $(which -a pi 2>/dev/null); do
        resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        case "$resolved" in
            *mux0*agent-hooks*pi-wrapper*) continue ;;
        esac
        case "$candidate" in
            *mux0*agent-hooks*pi-wrapper*) continue ;;
        esac
        REAL_PI="$candidate"
        break
    done
fi

if [ -z "$REAL_PI" ]; then
    echo "mux0 pi-wrapper: real 'pi' binary not found in PATH" >&2
    echo "  hint: install pi-coding-agent, or set MUX0_REAL_PI to its path" >&2
    exit 127
fi

# Without mux0's env there is nobody to report to — passthrough.
if [ -z "$MUX0_AGENT_HOOKS_DIR" ] || [ -z "$MUX0_HOOK_SOCK" ] || [ -z "$MUX0_TERMINAL_ID" ]; then
    exec "$REAL_PI" "$@"
fi

# Subcommand / help / version passthrough. `pi <subcommand>` never mixes with a
# prompt, and print mode (`-p`) is not a subcommand, so a bare scan of args is
# the same rule claude-wrapper.sh uses.
for arg in "$@"; do
    case "$arg" in
        install|remove|uninstall|update|list|config|auth|completions|export|help|--help|-h|--version|-v|--list-models)
            exec "$REAL_PI" "$@"
            ;;
    esac
done

EMIT="$MUX0_AGENT_HOOKS_DIR/hook-emit.sh"
EXTENSION="$MUX0_AGENT_HOOKS_DIR/pi-extension/mux0-status.js"

if [ ! -f "$EXTENSION" ]; then
    # Broken bundle layout (postBuildScript didn't copy resources): run pi
    # without status reporting rather than failing to start the user's agent.
    { echo "[$(date +%s)] [pi-wrapper] extension missing: $EXTENSION"; } \
        >> "$HOME/Library/Caches/mux0/hook-emit.log" 2>/dev/null || true
    exec "$REAL_PI" "$@"
fi

# Mark the terminal idle BEFORE handing off: shell preexec already flipped it to
# running when the user typed `pi`, and pi's own session_start may not have
# fired yet by the time the icon is drawn (and never fires at all if the
# extension fails to load).
"$EMIT" idle pi 2>/dev/null || true

{
    echo "[$(date +%s)] [pi-wrapper] execing: $REAL_PI -e $EXTENSION $*"
} >> "$HOME/Library/Caches/mux0/hook-emit.log" 2>/dev/null || true

# `session_shutdown` → idle covers the normal quit path, and pi's extension is
# loaded in-process, so `exec` is safe here (no overlay state to flush, unlike
# codex-wrapper.sh / grok-wrapper.sh which need their EXIT traps).
exec "$REAL_PI" -e "$EXTENSION" "$@"
