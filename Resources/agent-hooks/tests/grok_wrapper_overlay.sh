#!/bin/bash
# grok_wrapper_overlay.sh — end-to-end checks for grok-wrapper.sh's GROK_HOME
# overlay, without spending a model call.
#
# Guards three things that are easy to regress:
#   1. Injection point — grok must run with GROK_HOME pointed at the stable
#      mux0 overlay containing hooks/mux0.json (the ONLY per-process,
#      non-polluting hook injection grok allows: the GROK_CONFIG overlay
#      allowlist drops the `hooks` table, and project hooks need folder trust).
#   2. No pollution + no data loss — the user's real ~/.grok must not gain a
#      mux0 hook file, the user's own global hooks must still load, `sessions/`
#      must stay the user's real directory (so `grok --resume` outside mux0
#      lists mux0 sessions), and files grok rewrites through a symlink
#      (`tempfile + rename(2)`) must be synced back on exit — same contract as
#      codex_wrapper_cleanup.sh guards for CODEX_HOME.
#   3. Subcommand passthrough — `grok doctor` etc. must run untouched, with no
#      GROK_HOME override at all.
#
# A fake grok replaces the real binary (found through PATH, exactly like the
# shell-function injection would) and records what it saw.

# This test needs bash (see shebang). Under zsh `${BASH_SOURCE[0]}` is empty, so
# `zsh grok_wrapper_overlay.sh` used to resolve grok-wrapper.sh relative to the
# CWD and die with "no such file or directory". Re-exec under bash when another
# shell started us. The eval'd `${(%):-%x}` covers `zsh -c 'source …'`, where $0
# is the shell rather than the script (eval keeps that zsh-only expansion out of
# bash's parser).
if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

set -e

# Colours on, always: the fake grok used to list the overlay with `ls | sort`,
# and under CLICOLOR_FORCE=1 the symlink `user-hook.json` came back magenta,
# which sorted before `mux0.json` and broke the assertion. Listing must not go
# through `ls` at all — see the same guard in tests/grok_restore.sh.
export CLICOLOR_FORCE=1 CLICOLOR=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_DIR="$HERE/.."
WRAPPER="$SCRIPT_DIR/grok-wrapper.sh"

FAKE_HOME=$(mktemp -d -t mux0-grok-home.XXXXXX)
FAKE_BIN=$(mktemp -d -t mux0-grok-bin.XXXXXX)
USER_GROK="$FAKE_HOME/.grok"
EVIDENCE="$FAKE_HOME/evidence"
mkdir -p "$USER_GROK/hooks" "$FAKE_BIN" "$FAKE_HOME/Library/Caches/mux0"

cleanup() { rm -rf "$FAKE_HOME" "$FAKE_BIN"; }
trap cleanup EXIT INT TERM

# --- user's real ~/.grok, with one hook file of their own -------------------
cat > "$USER_GROK/config.toml" <<'EOF'
[models]
default = "user-chosen-model"
EOF
cat > "$USER_GROK/hooks"'/user-hook.json' <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user"}]}]}}
EOF
mkdir -p "$USER_GROK/sessions/%2Fprivate%2Ftmp"
echo "pre-existing" > "$USER_GROK/.metadata_version"

# --- fake grok --------------------------------------------------------------
cat > "$FAKE_BIN/grok" <<EOF
#!/bin/bash
{
  echo "GROK_HOME=\${GROK_HOME:-}"
  echo "ARGS=\$*"
  case " \$* " in
    *" --no-overlay-check "*) exit 0 ;;
  esac
  OVERLAY="\${GROK_HOME:-}"
  if [ -n "\$OVERLAY" ] && [ -d "\$OVERLAY" ]; then
    echo "HOOK_FILES=\$(cd "\$OVERLAY/hooks" && for f in *; do [ -e "\$f" ] || continue; printf '%s\n' "\$f"; done | sort | tr '\n' ',')"
    echo "MUX0_HOOK_JSON=\$(cat "\$OVERLAY/hooks/mux0.json" 2>/dev/null | tr -d '\n')"
    echo "CONFIG_VISIBLE=\$([ -f "\$OVERLAY/config.toml" ] && echo yes || echo no)"
    echo "SESSIONS_IS_SYMLINK=\$([ -L "\$OVERLAY/sessions" ] && echo yes || echo no)"
    # grok persists dotfiles/state via tempfile + rename(2), which replaces the
    # symlink with a regular file in the overlay.
    echo "written-by-grok" > "\$OVERLAY/.metadata_version"
    echo "new" > "\$OVERLAY/config.toml"
    # and writes a session through the sessions/ symlink
    mkdir -p "\$OVERLAY/sessions/%2Fprivate%2Ftmp/sess-fake"
    echo '{"generated_title":"From mux0 session"}' > "\$OVERLAY/sessions/%2Fprivate%2Ftmp/sess-fake/summary.json"
  fi
  echo "hello from fake grok"
} | tee -a "$EVIDENCE"
exit 0
EOF
chmod +x "$FAKE_BIN/grok"

# --- run the wrapper the way the shell function does ------------------------
export PATH="$FAKE_BIN:$PATH"
unset MUX0_REAL_GROK
export HOME="$FAKE_HOME"
export GROK_HOME="$USER_GROK"
export MUX0_AGENT_HOOKS_DIR="$SCRIPT_DIR"
export MUX0_HOOK_SOCK="$FAKE_HOME/no-such.sock"   # no listener: emits are no-ops
export MUX0_TERMINAL_ID="11111111-1111-1111-1111-111111111111"

OVERLAY="$FAKE_HOME/Library/Caches/mux0/grok-overlay"
rm -rf "$OVERLAY"

echo "grok --resume abc" | "$WRAPPER" --resume abc >/dev/null

fail() { echo "FAIL: $*" >&2; echo "--- evidence ---" >&2; cat "$EVIDENCE" >&2; exit 1; }

# 1. grok saw the overlay as GROK_HOME, not the user's ~/.grok
grep -q "^GROK_HOME=$OVERLAY\$" "$EVIDENCE" || fail "GROK_HOME not pointed at the mux0 overlay"

# 2. overlay exposes the user's config and a symlinked sessions dir
grep -q "^CONFIG_VISIBLE=yes\$" "$EVIDENCE" || fail "user config.toml not visible through overlay"
grep -q "^SESSIONS_IS_SYMLINK=yes\$" "$EVIDENCE" || fail "sessions/ must stay a symlink to the user's dir"

# 3. hook dir holds BOTH the user's hook and ours
grep -q "^HOOK_FILES=mux0.json,user-hook.json,\$" "$EVIDENCE" \
  || fail "overlay hooks/ should contain mux0.json + the user's own hook"

# 4. our hook JSON wires every lifecycle event we care about, with the right routing
python3 - "$EVIDENCE" <<'PY'
import json, re, sys
raw = open(sys.argv[1]).read()
line = [l for l in raw.splitlines() if l.startswith("MUX0_HOOK_JSON=")][0]
cfg = json.loads(line[len("MUX0_HOOK_JSON="):])["hooks"]
required = {
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionDenied", "Notification", "Stop",
    "StopFailure", "StopCancelled", "SessionEnd",
}
missing = required - set(cfg)
assert not missing, f"missing events in mux0.json: {sorted(missing)}"
for event, sub in (("UserPromptSubmit", "prompt"), ("PreToolUse", "pretool"),
                   ("PostToolUse", "posttool"), ("Stop", "stop"),
                   ("Notification", "notification"), ("StopCancelled", "stopcancelled"),
                   ("SessionEnd", "sessionend")):
    cmd = cfg[event][0]["hooks"][0]["command"]
    assert f"agent-hook.sh {sub} grok" in cmd, (event, cmd)
    assert "grok" in cmd
for event in ("SessionStart",):
    cmd = cfg[event][0]["hooks"][0]["command"]
    assert "hook-emit.sh idle grok" in cmd, (event, cmd)
# nested {type: command} shape — a flat {"command": ...} is silently skipped
for groups in cfg.values():
    for group in groups:
        assert isinstance(group.get("hooks"), list) and group["hooks"][0]["type"] == "command"
print("HOOK_JSON_OK")
PY

# 5. nothing leaked into the user's real ~/.grok
[ -e "$USER_GROK/hooks/mux0.json" ] && fail "wrapper wrote mux0.json into the user's ~/.grok"
[ -e "$USER_GROK/mux0.json" ] && fail "wrapper wrote into the wrong place in ~/.grok"

# 6. cleanup copied the rename-written files back to the real home
grep -q "^new$" "$USER_GROK/config.toml" || fail "config.toml written through a symlink was not synced back"
grep -q "^written-by-grok$" "$USER_GROK/.metadata_version" || fail ".metadata_version was not synced back"

# 7. the session landed in the user's real session store (so `grok --resume`
#    works outside mux0 and agent-hook.py can read summary.json)
[ -f "$USER_GROK/sessions/%2Fprivate%2Ftmp/sess-fake/summary.json" ] \
  || fail "session written inside mux0 is not visible in the user's sessions dir"

# 8. subcommand passthrough: no GROK_HOME override, args untouched
: > "$EVIDENCE"
"$WRAPPER" doctor --json >/dev/null
grep -q "^GROK_HOME=$USER_GROK\$" "$EVIDENCE" || fail "subcommand should run with the user's GROK_HOME"
grep -q "^ARGS=doctor --json\$" "$EVIDENCE" || fail "subcommand args were modified"

# 9. stable overlay path across launches (trust / /hooks listing stays put)
rm -rf "$OVERLAY"; rm -f "$EVIDENCE"
"$WRAPPER" -p "hi" >/dev/null
[ -d "$OVERLAY" ] || fail "overlay path is not stable across launches"

echo "GROK_WRAPPER_OK"
