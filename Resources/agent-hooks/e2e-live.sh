#!/bin/bash
# e2e-live.sh — drive a REAL agent run through this bundle's wrapper and print
# every event the app would have received.
#
# Lives next to the wrappers (not in tests/) on purpose: it calls the model, so
# it needs a logged-in agent CLI and costs money/tokens. run-all.sh therefore
# never runs it; it is the manual half of the acceptance check — tests/ proves
# the plumbing, this proves the plumbing is attached to the real CLI.
#
# Run it from inside a built app to test what actually ships:
#   .../mux0.app/Contents/Resources/agent-hooks/e2e-live.sh pi
#   .../mux0.app/Contents/Resources/agent-hooks/e2e-live.sh grok --fail
#
# Usage: ./e2e-live.sh [pi|grok|both] [--fail] [--timeout SECONDS]
#
# What it asserts (exit 0 only if all hold, for the agent under test):
#   • at least one `running` event carrying `resumeCommand`
#     (`pi --session <id>` / `grok --resume <id>`)
#   • at least one `running` event carrying `toolDetail` (a tool really ran)
#   • a `finished` event with `exitCode` and `summary`
#   • exitCode 0 on the default prompt, non-zero with --fail
# The listener is a separate process bound to a throwaway socket, i.e. the same
# shape as the app's HookSocketListener — nothing here reads app internals.

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
AGENT="${1:-both}"; shift || true
FAIL=0
CASE_TIMEOUT=240
while [ $# -gt 0 ]; do
    case "$1" in
        --fail)    FAIL=1; shift ;;
        --timeout) CASE_TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
        *) echo "e2e-live: unknown argument: $1" >&2; exit 2 ;;
    esac
done

PROMPT='Use your shell/bash tool to list the files in the current directory, then reply DONE.'
PROMPT_FAIL='Run exactly this shell command and then tell me its exit code: ls /nonexistent-dir-xyz-mux0'
[ "$FAIL" = "1" ] && PROMPT="$PROMPT_FAIL"

fail() { echo "e2e-live: $*" >&2; FAILED=1; }

run_one() { # <pi|grok>
    local agent="$1" dir sock log srv rc failed_here=0
    dir="$(mktemp -d "${TMPDIR:-/tmp}/mux0-e2e-live.XXXXXX")"
    sock="$dir/hook.sock"
    log="$dir/events.jsonl"

    python3 - "$sock" "$log" "$CASE_TIMEOUT" > "$dir/server.log" 2>&1 <<'PY' &
import sys, socket, os, time
sp, lp, life = sys.argv[1], sys.argv[2], float(sys.argv[3]) + 60
try: os.unlink(sp)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sp); s.listen(8); s.settimeout(2)
deadline, log = time.time() + life, open(lp, "a")
while time.time() < deadline:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    data = b""
    while True:
        chunk = c.recv(65536)
        if not chunk: break
        data += chunk
    c.close()
    log.write(data.decode()); log.flush()
PY
    srv=$!
    sleep 0.5

    export MUX0_AGENT_HOOKS_DIR="$HERE"
    export MUX0_HOOK_SOCK="$sock"
    export MUX0_TERMINAL_ID="$(python3 -c 'import uuid;print(uuid.uuid4())')"

    echo "$agent" > "$dir/marker"      # cwd marker so the tool call has real output
    echo "===== $agent: $PROMPT"
    ( cd "$dir" && timeout "$CASE_TIMEOUT" "$HERE/$agent-wrapper.sh" \
        -p "$PROMPT" $([ "$agent" = grok ] && echo --max-turns 4) ) \
        > "$dir/stdout.txt" 2>&1
    rc=$?
    sleep 2
    kill "$srv" 2>/dev/null
    pkill -f -- "$sock" 2>/dev/null

    echo "--- stdout (tail) ---"
    tail -4 "$dir/stdout.txt"
    echo "--- events on \$MUX0_HOOK_SOCK ---"
    cat "$log" 2>/dev/null || echo "(no events)"

    if [ ! -s "$log" ]; then
        fail "$agent: no events reached the socket (wrapper or extension broken)"
    else
        local want_resume
        case "$agent" in
            pi)   want_resume='pi --session ' ;;
            grok) want_resume='grok --resume ' ;;
        esac
        grep -q "\"resumeCommand\":\"$want_resume\|\"resumeCommand\": \"$want_resume" "$log" \
            || fail "$agent: no running event with resumeCommand '$want_resume…'"
        grep -q 'toolDetail' "$log" \
            || fail "$agent: no running event with toolDetail (did a tool really run?)"
        grep -q '"event": *"finished"' "$log" \
            || fail "$agent: no finished event"
        grep -q '"summary"' "$log" \
            || fail "$agent: finished event carries no summary"
        if [ "$FAIL" = "1" ]; then
            grep -Eq '"exitCode": *[^0]' "$log" \
                || fail "$agent: failing command reported exitCode 0"
        else
            grep -Eq '"exitCode": *0' "$log" \
                || fail "$agent: clean run did not report exitCode 0"
        fi
    fi
    echo "--- artifacts kept in $dir"
    return $failed_here
}

FAILED=0
case "$AGENT" in
    pi)   run_one pi ;;
    grok) run_one grok ;;
    both) run_one pi; run_one grok ;;
    *)    echo "e2e-live: agent must be pi, grok or both" >&2; exit 2 ;;
esac

if [ "$FAILED" = "1" ]; then
    echo "e2e-live: FAILED"
    exit 1
fi
echo "e2e-live: E2E_OK"
