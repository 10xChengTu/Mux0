#!/bin/bash
# smoke.sh — end-to-end bash smoke test of agent-hook.sh.
# Sets up a fake Unix socket with Python, fires all 4 subcommands with
# handcrafted JSON payloads, asserts socket received the right messages
# and session file is in the expected state.

# This test needs bash (see shebang). Under zsh `${BASH_SOURCE[0]}` is empty, so
# `zsh smoke.sh` used to resolve the scripts under test relative to the CWD and
# die with a confusing "no such file". Re-exec under bash when another shell
# started us. The eval'd `${(%):-%x}` covers `zsh -c 'source smoke.sh'`, where
# $0 is the shell rather than the script (eval keeps that zsh-only expansion out
# of bash's parser).
if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_DIR="$HERE/.."
AGENT_HOOK="$SCRIPT_DIR/agent-hook.sh"

TMPDIR_LOCAL=$(mktemp -d -t mux0-smoke.XXXXXX)
SOCK="$TMPDIR_LOCAL/hook.sock"
SESSION_FILE_OVERRIDE="$TMPDIR_LOCAL/sessions.json"
TRANSCRIPT="$TMPDIR_LOCAL/transcript.jsonl"
RECEIVED="$TMPDIR_LOCAL/received.log"

SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
    # Belt and braces: an aborted run used to leave the server alive (PPID 1),
    # holding this temp dir and — because it inherits stdout — whatever pipe the
    # caller had set up. The socket path is unique per run, so it identifies our
    # own stragglers and nothing else.
    if [ -n "$SOCK" ]; then
        pkill -f -- "$SOCK" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT INT TERM

# Seed transcript
cat > "$TRANSCRIPT" <<'EOF'
{"role":"user","content":"refactor foo"}
{"role":"assistant","content":"I refactored Foo.swift."}
EOF

# Start a Python Unix-socket echo server that appends each line to RECEIVED
# Output goes to a file, never to our stdout: a backgrounded server must not be
# able to keep the caller's pipe open.
# The deadline is the second line of defence against orphans — even if the kill
# in cleanup() never runs, the server gives up on its own.
python3 - "$SOCK" "$RECEIVED" <<'PY' > "$TMPDIR_LOCAL/server.log" 2>&1 &
import sys, socket, os, time
sock_path, log_path = sys.argv[1], sys.argv[2]
deadline = time.time() + 180
try: os.unlink(sock_path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(8)
s.settimeout(5)
with open(log_path, "w") as log:
    while time.time() < deadline:
        try:
            conn, _ = s.accept()
        except socket.timeout:
            continue
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        conn.close()
        log.write(data.decode())
        log.flush()
PY
SERVER_PID=$!
sleep 0.3   # let server bind before first client connect

export MUX0_HOOK_SOCK="$SOCK"
export MUX0_TERMINAL_ID="00000000-0000-0000-0000-000000000001"

# Redirect agent-hook.py's session file to our temp copy.
# agent-hook.sh hardcodes the path, so we override the env var _after_ it
# would have been set by sourcing — simplest: patch the path by running
# the python directly for the session-file path, or temporarily edit.
# Here we just use a wrapper that sets _MUX0_SESSION_FILE manually:
run_hook() {
    local sub="$1"; shift
    local agt="$1"; shift
    local payload="$1"; shift
    _MUX0_SUBCMD="$sub" _MUX0_AGENT="$agt" \
      _MUX0_SESSION_FILE="$SESSION_FILE_OVERRIDE" \
      _MUX0_PAYLOAD="$payload" \
      python3 "$SCRIPT_DIR/agent-hook.py"
}

# Scenario: prompt → pretool(Edit) → posttool(is_error=true) → stop
run_hook prompt   claude '{"session_id":"s1","transcript_path":"'"$TRANSCRIPT"'"}'
run_hook pretool  claude '{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"/foo/bar/baz.swift"}}'
run_hook posttool claude '{"session_id":"s1","tool_name":"Edit","tool_response":{"is_error":true}}'
run_hook stop     claude '{"session_id":"s1"}'

sleep 0.3   # server flushes

# Assertions
if ! grep -q '"event": "running"' "$RECEIVED"; then
    echo "FAIL: no running event in received log" >&2; exit 1
fi
if ! grep -q '"toolDetail": "Edit foo/bar/baz.swift"' "$RECEIVED"; then
    echo "FAIL: no toolDetail in received log" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"exitCode": 1' "$RECEIVED"; then
    echo "FAIL: stop did not emit exitCode 1 (turn had error)" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"summary": "I refactored Foo.swift."' "$RECEIVED"; then
    echo "FAIL: summary not in stop payload" >&2; cat "$RECEIVED" >&2; exit 1
fi

# Session entry should be removed
if grep -q '"s1"' "$SESSION_FILE_OVERRIDE"; then
    echo "FAIL: session entry s1 still present" >&2
    cat "$SESSION_FILE_OVERRIDE" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Grok: full lifecycle through the real socket, using grok's actual envelope
# (camelCase fields + snake_case aliases, `reason`, `lastAssistantMessage`).
# ---------------------------------------------------------------------------
GROK_SID="01a0d1d8-4252-7992-a65b-4ee8d890878f"
GROK_HOME="$TMPDIR_LOCAL/.grok"
mkdir -p "$GROK_HOME/sessions/%2Fprivate%2Ftmp%2Fproj/$GROK_SID"
cat > "$GROK_HOME/sessions/%2Fprivate%2Ftmp%2Fproj/$GROK_SID/summary.json" <<EOF
{"generated_title":"List Files Then Say Done","session_kind":"interactive"}
EOF
cat > "$GROK_HOME/sessions/%2Fprivate%2Ftmp%2Fproj/$GROK_SID/chat_history.jsonl" <<'EOF'
{"type":"user","content":[{"type":"text","text":"<user_query>\nls please\n</user_query>"}]}
{"type":"assistant","content":"Files: a.txt DONE"}
EOF
export GROK_HOME

MARK_GROK=$(( $(wc -l < "$RECEIVED") ))

run_hook prompt  grok "{\"session_id\":\"$GROK_SID\",\"sessionId\":\"$GROK_SID\",\"promptId\":\"p1\",\"hook_event_name\":\"UserPromptSubmit\"}"
run_hook pretool grok "{\"session_id\":\"$GROK_SID\",\"tool_name\":\"list_dir\",\"tool_input\":{\"target_directory\":\"/tmp/proj\"},\"transcript_path\":\"/tmp/updates.jsonl\"}"
run_hook posttool grok "{\"session_id\":\"$GROK_SID\",\"tool_name\":\"list_dir\",\"tool_response\":{\"type\":\"ListDir\",\"Content\":{\"is_error\":true,\"content\":\"EACCES\"}}}"
run_hook notification grok "{\"session_id\":\"$GROK_SID\",\"notificationType\":\"permission_prompt\",\"message\":\"Allow?\"}"
run_hook stop    grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"end_turn\",\"lastAssistantMessage\":\"Files: a.txt DONE\"}"
# teardown duplicate: grok fires an observe-only Stop with reason=shutdown,
# then SessionEnd. Neither may emit a second `finished`.
run_hook stop    grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"shutdown\"}"
run_hook sessionend grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"shutdown\"}"

sleep 0.4
GROK_OUT="$TMPDIR_LOCAL/grok.out"
tail -n +$(( MARK_GROK + 1 )) "$RECEIVED" > "$GROK_OUT"

assert_grok() {
    if ! grep -q "$1" "$GROK_OUT"; then
        echo "FAIL(grok): missing $1" >&2; cat "$GROK_OUT" >&2; exit 1
    fi
}
assert_grok '"agent": "grok"'
assert_grok '"resumeCommand": "grok --resume 01a0d1d8-4252-7992-a65b-4ee8d890878f"'
assert_grok '"sessionTitle": "List Files Then Say Done"'
assert_grok '"toolDetail": "List tmp/proj"'
assert_grok '"event": "needsInput"'
assert_grok '"exitCode": 1'          # the failing list_dir must poison the turn
assert_grok '"summary": "Files: a.txt DONE"'
# exactly one `finished` for the turn (the reason=shutdown Stop must not add one)
FINISHED_COUNT=$(grep -c '"event": "finished"' "$GROK_OUT")
if [ "$FINISHED_COUNT" != "1" ]; then
    echo "FAIL(grok): expected exactly 1 finished, got $FINISHED_COUNT" >&2
    cat "$GROK_OUT" >&2; exit 1
fi
if ! grep -q '"event": "idle"' "$GROK_OUT"; then
    echo "FAIL(grok): SessionEnd did not emit idle" >&2; cat "$GROK_OUT" >&2; exit 1
fi

# idle_prompt backstop: settles a turn that never reported Stop, and stays
# silent once the turn already settled.
MARK_BACKSTOP=$(( $(wc -l < "$RECEIVED") ))
run_hook prompt grok "{\"session_id\":\"$GROK_SID\",\"sessionId\":\"$GROK_SID\"}"
run_hook notification grok "{\"session_id\":\"$GROK_SID\",\"notificationType\":\"idle_prompt\"}"
run_hook notification grok "{\"session_id\":\"$GROK_SID\",\"notificationType\":\"idle_prompt\"}"
sleep 0.4
BACKSTOP_OUT="$TMPDIR_LOCAL/grok-backstop.out"
tail -n +$(( MARK_BACKSTOP + 1 )) "$RECEIVED" > "$BACKSTOP_OUT"
BACKSTOP_FINISHED=$(grep -c '"event": "finished"' "$BACKSTOP_OUT")
if [ "$BACKSTOP_FINISHED" != "1" ]; then
    echo "FAIL(grok): idle_prompt backstop emitted $BACKSTOP_FINISHED finished (want 1)" >&2
    cat "$BACKSTOP_OUT" >&2; exit 1
fi
if ! grep -q '"summary": "Files: a.txt DONE"' "$BACKSTOP_OUT"; then
    echo "FAIL(grok): backstop summary not read from chat_history.jsonl" >&2
    cat "$BACKSTOP_OUT" >&2; exit 1
fi

# Real grok failure shape (captured from grok 1.0.41 running `ls /nope`):
# PostToolUse — NOT PostToolUseFailure — with the result under the top-level
# `toolResult` key and no is_error field at all. The turn ends with
# Stop reason=end_turn, so without reading exit_code the tab would go green.
MARK_BASHERR=$(( $(wc -l < "$RECEIVED") ))
run_hook prompt   grok "{\"session_id\":\"$GROK_SID\",\"sessionId\":\"$GROK_SID\"}"
run_hook posttool grok "{\"session_id\":\"$GROK_SID\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls /nope\"},\"toolResult\":{\"type\":\"Bash\",\"exit_code\":1,\"command\":\"ls /nope\",\"signal\":null,\"timed_out\":false}}"
run_hook stop     grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"end_turn\",\"lastAssistantMessage\":\"Exit status 1\"}"
sleep 0.4
BASHERR_OUT="$TMPDIR_LOCAL/grok-basherr.out"
tail -n +$(( MARK_BASHERR + 1 )) "$RECEIVED" > "$BASHERR_OUT"
if ! grep -q '"exitCode": 1' "$BASHERR_OUT"; then
    echo "FAIL(grok): non-zero toolResult.exit_code did not fail the turn" >&2
    cat "$BASHERR_OUT" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# pi: shell layer (wrapper) — the extension itself is covered by
# tests/pi_extension_test.py, which drives it in Node against a real socket.
# ---------------------------------------------------------------------------
FAKE_BIN="$TMPDIR_LOCAL/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/pi" <<EOF
#!/bin/bash
echo "PI_ARGS=\$*" >> "$RECEIVED"
echo "pi (fake) ran"
EOF
chmod +x "$FAKE_BIN/pi"
OLD_PATH="$PATH"
export PATH="$FAKE_BIN:$PATH"
unset MUX0_REAL_PI
# smoke.sh drives agent-hook.py directly (run_hook), so the hooks dir is not
# exported by default — the wrapper needs it to locate the extension.
export MUX0_AGENT_HOOKS_DIR="$SCRIPT_DIR"

"$SCRIPT_DIR/pi-wrapper.sh" "hello" >/dev/null
"$SCRIPT_DIR/pi-wrapper.sh" --version >/dev/null

if ! grep -q '^PI_ARGS=-e .*pi-extension/mux0-status.js hello$' "$RECEIVED"; then
    echo "FAIL(pi): wrapper did not inject -e <extension>" >&2
    grep '^PI_ARGS=' "$RECEIVED" >&2; exit 1
fi
if grep -q '^PI_ARGS=-e .*--version$' "$RECEIVED"; then
    echo "FAIL(pi): --version must pass through without injection" >&2; exit 1
fi
if ! grep -q '"event":"idle","agent":"pi"\|"event": "idle", "agent": "pi"' "$RECEIVED"; then
    # hook-emit.sh writes compact JSON — accept either spacing.
    if ! grep -q 'agent=pi' "$HOME/Library/Caches/mux0/hook-emit.log"; then
        echo "FAIL(pi): wrapper emitted no idle event" >&2; exit 1
    fi
fi
export PATH="$OLD_PATH"

# ---------------------------------------------------------------------------
# agent-hook.sh — the entry point the shipped hook configs exec (claude
# --settings, codex hooks.json, grok hooks/mux0.json). Everything above calls
# agent-hook.py directly, so nothing covered this file — which is exactly how a
# `dirname "${BASH_SOURCE[0]}"` bug hid: that variable is empty under zsh, so
# agent-hook.py was looked for in the CWD and the hook died quietly. Both shells
# must deliver events over the socket.
# ---------------------------------------------------------------------------
HOOK_HOME="$TMPDIR_LOCAL/home"
mkdir -p "$HOOK_HOME/Library/Caches/mux0"
# Count *occurrences*, not lines: hook-emit.sh (pi) writes compact JSON without a
# trailing newline, so events can share a line in the log the server appends.
count_events()   { grep -oE '"terminalId"' "$1"      | wc -l | tr -d ' '; }
count_finished() { grep -oE '"event": ?"finished"' "$1" | wc -l | tr -d ' '; }
ENTRY_SH="bash"
command -v zsh >/dev/null 2>&1 && ENTRY_SH="bash zsh"
before_lines=$(count_events "$RECEIVED")
before_finished=$(count_finished "$RECEIVED")
ENTRY_TRIED=0
for sh in $ENTRY_SH; do
    ENTRY_TRIED=$((ENTRY_TRIED + 1))
    # HOME points into the temp dir: agent-hook.sh hardcodes the session file to
    # $HOME/Library/Caches/mux0/, and a test must not touch the real one.
    if ! printf '%s' "{\"session_id\":\"s-entry\",\"transcript_path\":\"$TRANSCRIPT\"}" \
            | env HOME="$HOOK_HOME" "$sh" "$AGENT_HOOK" prompt claude \
            > "$TMPDIR_LOCAL/entrypoint.$sh.log" 2>&1; then
        echo "FAIL(entrypoint): $sh agent-hook.sh prompt exited non-zero" >&2
        cat "$TMPDIR_LOCAL/entrypoint.$sh.log" >&2; exit 1
    fi
    if ! printf '%s' "{\"session_id\":\"s-entry\"}" \
            | env HOME="$HOOK_HOME" "$sh" "$AGENT_HOOK" stop claude \
            >> "$TMPDIR_LOCAL/entrypoint.$sh.log" 2>&1; then
        echo "FAIL(entrypoint): $sh agent-hook.sh stop exited non-zero" >&2
        cat "$TMPDIR_LOCAL/entrypoint.$sh.log" >&2; exit 1
    fi
    # A wrong script_dir surfaces as a python message, not a bad exit code
    # (agent-hook.sh ends in `exec python3`).
    if grep -qi "can't open file\|No such file" "$TMPDIR_LOCAL/entrypoint.$sh.log"; then
        echo "FAIL(entrypoint): $sh agent-hook.sh did not find agent-hook.py" >&2
        cat "$TMPDIR_LOCAL/entrypoint.$sh.log" >&2; exit 1
    fi
done
sleep 0.4
after_lines=$(count_events "$RECEIVED")
after_finished=$(count_finished "$RECEIVED")
if [ "$((after_lines - before_lines))" -lt "$((ENTRY_TRIED * 2))" ]; then
    echo "FAIL(entrypoint): $ENTRY_TRIED agent-hook.sh runs produced $((after_lines - before_lines)) events (want >= $((ENTRY_TRIED * 2)))" >&2
    tail -5 "$RECEIVED" >&2; exit 1
fi
if [ "$((after_finished - before_finished))" -lt "$ENTRY_TRIED" ]; then
    echo "FAIL(entrypoint): only $((after_finished - before_finished)) finished events for $ENTRY_TRIED shells" >&2; exit 1
fi
# The session file has to land under the HOME we exported — proof the shim's own
# path plumbing (not just agent-hook.py) works.
if [ ! -f "$HOOK_HOME/Library/Caches/mux0/agent-sessions.json" ]; then
    echo "FAIL(entrypoint): agent-hook.sh wrote no session file under \$HOME/Library/Caches/mux0" >&2; exit 1
fi

echo "SMOKE OK"
