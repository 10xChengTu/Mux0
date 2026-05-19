#!/bin/bash
# claude-wrapper.sh — launch Claude Code with mux0 lifecycle hooks injected
# via an overlay CLAUDE_CONFIG_DIR (same pattern as codex-wrapper.sh).
#
# Why overlay instead of --settings <json>? Claude Code subcommands
# (mcp, doctor, install, --remote-control, etc.) inherit commander.js's
# parser, which doesn't always recognize --settings, so injecting that flag
# broke `claude remote-control` and similar invocations (GH #26). The
# overlay strategy works transparently for every current AND future
# subcommand because CLAUDE_CONFIG_DIR is honored at the settings-load
# layer, before any command-specific argument parsing.
#
# Reads MUX0_AGENT_HOOKS_DIR, MUX0_HOOK_SOCK, MUX0_TERMINAL_ID from env.

set -e

# DEBUG: sentinel to confirm wrapper actually gets invoked.
{
    echo "[$(date +%s)] [claude-wrapper] invoked: args=$*  MUX0_AGENT_HOOKS_DIR=${MUX0_AGENT_HOOKS_DIR:+set}  MUX0_HOOK_SOCK=${MUX0_HOOK_SOCK:+set}  MUX0_TERMINAL_ID=${MUX0_TERMINAL_ID:+set}"
} >> "$HOME/Library/Caches/mux0/hook-emit.log" 2>/dev/null || true

# Find the real claude binary: skip any shell function / wrapper and the mux0 wrapper itself.
# Strategy: try MUX0_REAL_CLAUDE env override first; else walk PATH.
REAL_CLAUDE=""
if [ -n "$MUX0_REAL_CLAUDE" ] && [ -x "$MUX0_REAL_CLAUDE" ]; then
    REAL_CLAUDE="$MUX0_REAL_CLAUDE"
else
    for candidate in $(which -a claude 2>/dev/null); do
        # Resolve symlinks and skip our own wrapper path
        resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        case "$resolved" in
            *mux0*agent-hooks*claude-wrapper*) continue ;;
        esac
        REAL_CLAUDE="$candidate"
        break
    done
fi

if [ -z "$REAL_CLAUDE" ]; then
    echo "mux0 claude-wrapper: real 'claude' binary not found in PATH" >&2
    echo "  hint: install Claude Code, or set MUX0_REAL_CLAUDE to its path" >&2
    exit 127
fi

# If mux0 env is missing (e.g. user ran this wrapper outside mux0), passthrough.
if [ -z "$MUX0_AGENT_HOOKS_DIR" ] || [ -z "$MUX0_HOOK_SOCK" ] || [ -z "$MUX0_TERMINAL_ID" ]; then
    exec "$REAL_CLAUDE" "$@"
fi

EMIT="$MUX0_AGENT_HOOKS_DIR/hook-emit.sh"
AGENT_HOOK="$MUX0_AGENT_HOOKS_DIR/agent-hook.sh"

# Resolve the user's real config dir BEFORE we override CLAUDE_CONFIG_DIR.
USER_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
USER_SETTINGS="$USER_CLAUDE_DIR/settings.json"

# Build overlay: symlink every entry in USER_CLAUDE_DIR except settings.json,
# then write a merged settings.json into the overlay.
OVERLAY=$(mktemp -d -t mux0-claude.XXXXXX)

# Record whether the user already had a settings.json so cleanup knows
# whether to (re-)create it (we don't want to leak an empty {} file into a
# fresh ~/.claude that never had one).
HAD_USER_SETTINGS=0
USER_SETTINGS_VALID=0
if [ -f "$USER_SETTINGS" ]; then
    HAD_USER_SETTINGS=1
    if python3 -c "import json,sys; json.loads(open(sys.argv[1]).read())" "$USER_SETTINGS" 2>/dev/null; then
        USER_SETTINGS_VALID=1
    fi
fi

# Symlink top-level entries (regular and hidden) from the real config dir.
# dotglob picks up things like .credentials.json; nullglob avoids the
# literal pattern leaking through if the dir is empty.
if [ -d "$USER_CLAUDE_DIR" ]; then
    shopt -s nullglob dotglob
    for item in "$USER_CLAUDE_DIR"/*; do
        name=$(basename "$item")
        case "$name" in
            settings.json) continue ;;   # we write a merged version below
        esac
        ln -sfn "$item" "$OVERLAY/$name"
    done
    shopt -u dotglob nullglob
fi

# Merge mux0 hooks into the user's settings.json. Each mux0 entry is a
# matcher-group keyed under hooks.<event>; user's existing groups (if any)
# stay at the front of the array. We identify mux0-managed groups on
# cleanup by command-path prefix, so adding a sentinel key (which would
# trip serde's deny_unknown_fields in stricter parsers) is unnecessary.
if ! EMIT_PATH="$EMIT" AGENT_HOOK_PATH="$AGENT_HOOK" \
     USER_SETTINGS="$USER_SETTINGS" MERGED="$OVERLAY/settings.json" \
     USER_SETTINGS_VALID="$USER_SETTINGS_VALID" \
     python3 - <<'PY'
import json, os, pathlib
emit = os.environ["EMIT_PATH"]
agent_hook = os.environ["AGENT_HOOK_PATH"]
user_path = pathlib.Path(os.environ["USER_SETTINGS"])
merged_path = pathlib.Path(os.environ["MERGED"])
user_valid = os.environ.get("USER_SETTINGS_VALID") == "1"

data = {}
if user_valid:
    try:
        data = json.loads(user_path.read_text())
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
    data["hooks"] = hooks

mux0_hooks = {
    "SessionStart":     {"matcher": "", "hooks": [{"type": "command", "command": f"{emit} idle claude"}]},
    "UserPromptSubmit": {"matcher": "", "hooks": [{"type": "command", "command": f"{agent_hook} prompt claude"}]},
    "PreToolUse":       {"matcher": "", "hooks": [{"type": "command", "command": f"{agent_hook} pretool claude"}]},
    "PostToolUse":      {"matcher": "", "hooks": [{"type": "command", "command": f"{agent_hook} posttool claude"}]},
    "Stop":             {"matcher": "", "hooks": [{"type": "command", "command": f"{agent_hook} stop claude"}]},
    "Notification":     {"matcher": "", "hooks": [{"type": "command", "command": f"{emit} needsInput claude"}]},
    "SessionEnd":       {"matcher": "", "hooks": [{"type": "command", "command": f"{emit} idle claude"}]},
}

for event, group in mux0_hooks.items():
    existing = hooks.get(event)
    if not isinstance(existing, list):
        existing = []
    hooks[event] = existing + [group]

merged_path.write_text(json.dumps(data, indent=2))
PY
then
    echo "mux0 claude-wrapper: failed to build merged settings.json; running without hooks" >&2
    rm -rf "$OVERLAY" 2>/dev/null || true
    exec "$REAL_CLAUDE" "$@"
fi

# Stamp the overlay settings.json right after we wrote it. Cleanup uses this
# to detect "did claude actually rewrite settings.json during the session" —
# if mtime+size are unchanged, claude never touched it, and writing our
# stale snapshot back to the user's real ~/.claude/settings.json would
# clobber any /config change made by a concurrent mux0-launched session.
# BSD stat (macOS); the wrapper is macOS-only.
OVERLAY_SETTINGS_STAMP=$(stat -f "%m:%z" "$OVERLAY/settings.json" 2>/dev/null || echo "")

export CLAUDE_CONFIG_DIR="$OVERLAY"

# Cleanup: claude may have rewritten top-level entries in $OVERLAY via
# tempfile + rename(2) (e.g. user did /config). Those rewrites replace our
# symlinks with regular files. For settings.json we strip the mux0-managed
# hook groups and write the result back to the user's real settings.json
# (so /config changes persist without leaking mux0 paths). Other top-level
# regular files we copy back verbatim. Symlinks left alone — writes through
# them already hit the user's real ~/.claude paths.
cleanup() {
    set +e
    # Mark idle on exit (matches codex-wrapper). Shell preexec may not fire
    # if the user closed the window mid-session.
    "$EMIT" idle claude 2>/dev/null || true

    OVERLAY_DIR="$OVERLAY" \
    USER_SETTINGS="$USER_SETTINGS" \
    USER_DIR="$USER_CLAUDE_DIR" \
    HOOKS_DIR="$MUX0_AGENT_HOOKS_DIR" \
    HAD_USER_SETTINGS="$HAD_USER_SETTINGS" \
    USER_SETTINGS_VALID="$USER_SETTINGS_VALID" \
    OVERLAY_SETTINGS_STAMP="$OVERLAY_SETTINGS_STAMP" \
    python3 - <<'PY' 2>/dev/null || true
import json, os, pathlib, shutil
overlay = pathlib.Path(os.environ["OVERLAY_DIR"])
user_settings = pathlib.Path(os.environ["USER_SETTINGS"])
user_dir = pathlib.Path(os.environ["USER_DIR"])
hooks_dir = os.environ["HOOKS_DIR"].rstrip("/") + "/"
had_user_settings = os.environ.get("HAD_USER_SETTINGS") == "1"
user_settings_valid = os.environ.get("USER_SETTINGS_VALID") == "1"
orig_stamp = os.environ.get("OVERLAY_SETTINGS_STAMP", "")

settings_path = overlay / "settings.json"

# Did claude actually rewrite settings.json this session? rename(2) updates
# mtime; even an unlikely byte-identical rewrite would change at least the
# inode, but checking mtime+size is sufficient (and avoids hashing). If the
# stamp is unchanged we leave the user's real settings.json alone — a
# concurrent mux0 session that DID change /config has already written its
# own version, and we must not clobber it with our stale snapshot.
current_stamp = ""
try:
    st = settings_path.stat()
    current_stamp = f"{int(st.st_mtime)}:{st.st_size}"
except OSError:
    pass
claude_rewrote_settings = bool(current_stamp) and bool(orig_stamp) and current_stamp != orig_stamp

if (settings_path.is_file() and not settings_path.is_symlink()
        and claude_rewrote_settings):
    try:
        data = json.loads(settings_path.read_text())
    except Exception:
        data = None
    if isinstance(data, dict):
        hooks = data.get("hooks") if isinstance(data.get("hooks"), dict) else None
        if hooks:
            for event, groups in list(hooks.items()):
                if not isinstance(groups, list):
                    continue
                kept = []
                for group in groups:
                    inner = group.get("hooks") if isinstance(group, dict) else None
                    if isinstance(inner, list) and any(
                        isinstance(h, dict)
                        and isinstance(h.get("command"), str)
                        and h["command"].startswith(hooks_dir)
                        for h in inner
                    ):
                        continue  # mux0-managed group; drop
                    kept.append(group)
                if kept:
                    hooks[event] = kept
                else:
                    hooks.pop(event, None)
            if not hooks:
                data.pop("hooks", None)
        # Only write back when there's meaningful content OR the user
        # already had a (valid) settings.json. Refuse to materialize an
        # empty {} file in a previously-empty ~/.claude, and never
        # overwrite a previously-malformed settings.json (preserves
        # user-recoverable state).
        if data or (had_user_settings and user_settings_valid):
            user_settings.parent.mkdir(parents=True, exist_ok=True)
            user_settings.write_text(json.dumps(data, indent=2))

# Copy back other top-level entries claude created/rewrote in the overlay.
# Symlinks are left alone (writes through them already hit the user's real
# ~/.claude). Regular files get copy2'd. Directories are copytree'd with
# dirs_exist_ok=True so a brand-new top-level dir (e.g. `projects/` on
# first-run when ~/.claude didn't exist, or claude replacing a symlinked
# dir entry via rename) is preserved instead of being deleted with $OVERLAY.
user_dir_created = False
for item in overlay.iterdir():
    if item.name == "settings.json":
        continue
    if item.is_symlink():
        continue
    if not user_dir_created:
        user_dir.mkdir(parents=True, exist_ok=True)
        user_dir_created = True
    target = user_dir / item.name
    try:
        if item.is_dir():
            shutil.copytree(item, target, symlinks=True, dirs_exist_ok=True)
        elif item.is_file():
            shutil.copy2(item, target)
    except OSError:
        pass
PY

    rm -rf "$OVERLAY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Run claude as a subprocess so EXIT/INT/TERM traps fire. `exec` would
# replace this shell entirely and skip cleanup — meaning user's /config
# changes wouldn't get copied back to ~/.claude. `|| EXIT_CODE=$?` keeps
# `set -e` from short-circuiting before we forward the code.
EXIT_CODE=0
"$REAL_CLAUDE" "$@" || EXIT_CODE=$?
exit "$EXIT_CODE"
