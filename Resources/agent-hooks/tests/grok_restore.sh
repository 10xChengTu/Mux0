#!/bin/bash
# grok_restore.sh (test) — checks Resources/agent-hooks/grok-restore.sh.
#
# Two install strategies must both be reversible with one command:
#   A (current): GROK_HOME overlay, nothing under ~/.grok is edited by mux0.
#   B (fallback, documented in docs/agent-hooks.md): mux0 writes into ~/.grok
#     and must leave a .mux0-backup/<ts>/<relpath> snapshot + CHANGES.log entry.
# The test fabricates a B-style mutation by hand (the same layout a B writer
# produces), runs the restore, and asserts the user's own files are untouched.

# This test needs bash (see shebang). Under zsh `${BASH_SOURCE[0]}` is empty, so
# `zsh grok_restore.sh` used to look for grok-restore.sh next to the CWD and
# report RESTORE_FAIL. Re-exec under bash when another shell started us. The
# eval'd `${(%):-%x}` covers `zsh -c 'source …'`, where $0 is the shell rather
# than the script (eval keeps that zsh-only expansion out of bash's parser).
if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

set -e

# Run this test with colours forced ON, even in a clean environment. The restore
# used to enumerate snapshots with `ls`, and with CLICOLOR_FORCE=1 (set by CI
# runners and plenty of dotfiles) the ANSI-wrapped directory name stopped being
# a path: no backup was found and mux0's edit stayed in the user's config.toml.
# The suite passed for weeks only because nobody had that variable exported.
export CLICOLOR_FORCE=1 CLICOLOR=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_DIR="$HERE/.."
RESTORE="$SCRIPT_DIR/grok-restore.sh"

ROOT=$(mktemp -d -t mux0-restore.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

FAKE_HOME="$ROOT/home"
# grok-restore.sh resolves both ~/.grok and ~/Library/Caches/mux0 from $HOME, so
# the whole test runs against a fake HOME (same trick grok_wrapper_overlay.sh uses).
export HOME="$FAKE_HOME"
unset GROK_HOME MUX0_GROK_RESTORE_HOME
GROK="$FAKE_HOME/.grok"
OVERLAY_ROOT="$FAKE_HOME/Library/Caches/mux0"
OVERLAY="$OVERLAY_ROOT/grok-overlay"

fail() { echo "RESTORE_FAIL: $*" >&2; exit 1; }
[ -x "$RESTORE" ] || [ -f "$RESTORE" ] || fail "missing $RESTORE"

mkdir -p "$GROK/hooks" "$GROK/sessions/proj" "$OVERLAY/hooks"
printf 'model = "team-grok"\n' > "$GROK/config.toml"
printf '{"hooks":{"Stop":[]}}\n' > "$GROK/hooks/user.json"          # the user's own
printf 'session-body\n' > "$GROK/sessions/proj/s1.jsonl"
printf '{"mux0":true}\n' > "$OVERLAY/hooks/mux0.json"               # ours, overlay copy

# --- B-style mutation of the user's real ~/.grok --------------------------
SNAP="$GROK/.mux0-backup/20260101T000000Z"
mkdir -p "$SNAP"
cp -p "$GROK/config.toml" "$SNAP/config.toml"                        # original content
printf 'model = "team-grok"\n[[hooks]]\ncommand = "agent-hook"\n' > "$GROK/config.toml"
printf '{"hooks":{"mux0":["agent-hook"]}}\n' > "$GROK/hooks/mux0.json"  # created by mux0
printf 'gone\n' > "$GROK/stale.json"
printf 'original stale\n' > "$SNAP/stale.json"
{
    printf '%s\tmodify\tconfig.toml\tdoc mux0 hooks\n' "2026-01-01T00:00:00Z"
    printf '%s\tnew\thooks/mux0.json\tinstall mux0 hook\n' "2026-01-01T00:00:01Z"
    printf '%s\tdelete\tstale.json\tremoved by mux0\n' "2026-01-01T00:00:02Z"
} > "$GROK/.mux0-backup/CHANGES.log"
# a second, later snapshot must not win over the original one
mkdir -p "$GROK/.mux0-backup/20260201T000000Z"
printf 'intermediate\n' > "$GROK/.mux0-backup/20260201T000000Z/config.toml"

# --- dry run changes nothing ---------------------------------------------
HOME="$FAKE_HOME" "$RESTORE" --keep-overlay --dry-run > "$ROOT/dry.out" 2>&1 \
    || fail "dry run exited non-zero"
grep -q "would:" "$ROOT/dry.out" || fail "dry run did not report pending changes"
grep -q 'agent-hook' "$GROK/config.toml" || fail "dry run modified config.toml"
[ -f "$GROK/hooks/mux0.json" ] || fail "dry run deleted our hook file"

# --- real restore ---------------------------------------------------------
out=$("$RESTORE" 2>&1) || fail "restore exited non-zero: $out"
echo "--- restore output ---" >&2; echo "$out" >&2

grep -q 'model = "team-grok"' "$GROK/config.toml" || fail "config.toml not restored to original"
grep -q 'agent-hook' "$GROK/config.toml" && fail "mux0's injected hook line survived the restore"
grep -q "intermediate" "$GROK/config.toml" && fail "newest snapshot won over the original"
[ ! -f "$GROK/hooks/mux0.json" ] || fail "mux0-created hooks/mux0.json was not removed"
[ -f "$GROK/hooks/user.json" ] || fail "the user's own hooks/user.json was removed"
[ -f "$GROK/stale.json" ] || fail "file mux0 deleted was not restored"
grep -q "original stale" "$GROK/stale.json" || fail "restored content wrong (want the pre-delete content)"
grep -q "session-body" "$GROK/sessions/proj/s1.jsonl" || fail "sessions/ must be untouched"
grep -q $'\trestore\t' "$GROK/.mux0-backup/CHANGES.log" || fail "restore was not logged"
[ ! -d "$OVERLAY" ] || fail "overlay should have been removed"

# --- A-only machine: nothing to undo, must be a clean no-op --------------
rm -rf "$GROK"
mkdir -p "$GROK/hooks" "$OVERLAY/hooks"
printf '{"hooks":{"Stop":[]}}\n' > "$GROK/hooks/user.json"
printf '{"mux0":true}\n' > "$OVERLAY/hooks/mux0.json"
out=$(HOME="$FAKE_HOME" "$RESTORE" 2>&1) || fail "A-style restore failed: $out"
[ -f "$GROK/hooks/user.json" ] || fail "A-style restore touched user files"
[ ! -e "$OVERLAY" ] || fail "A-style restore left the overlay behind"
echo "$out" | grep -q "never edited" || fail "A-style restore should say ~/.grok was never edited"

# --- refuse to restore into an overlay -----------------------------------
mkdir -p "$OVERLAY"
"$RESTORE" --home "$OVERLAY_ROOT/grok-overlay" > "$ROOT/refuse.out" 2>&1 \
    && fail "should refuse --home pointing at an overlay"
grep -q "refusing" "$ROOT/refuse.out" || fail "refusal message missing"

echo "GROK_RESTORE_OK"
