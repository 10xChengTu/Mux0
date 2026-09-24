#!/bin/bash
# run-all.sh — run every test under Resources/agent-hooks and print one table.
#
# Why this exists: `bash x.sh` passing proves nothing on its own. Every shell
# test here is a bash script that has to locate the scripts it tests, and
# `${BASH_SOURCE[0]}` is empty under zsh — so a test could be green under bash
# and red for anyone who runs it with their login shell (macOS default is zsh).
# That is exactly how a "all green" report met a failing reviewer. So each shell
# test is executed under bash AND under zsh when zsh exists; both must pass.
#
# Usage:
#   bash Resources/agent-hooks/tests/run-all.sh              # summary per test
#   bash Resources/agent-hooks/tests/run-all.sh --verbose    # full output
#
# Exit status: 0 only if everything passed. Skips (no pytest / no zsh / no node)
# are reported but do not fail the run — a missing interpreter is an environment
# gap, not a regression.

# Re-exec under bash when started by another shell (same trick the tests use).
if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1
# Per-case ceiling. No `timeout` on stock macOS, so the runner grows its own.
CASE_TIMEOUT="${MUX0_TEST_TIMEOUT:-300}"
# Test with colours forced on. `ls` writes ANSI escapes into its output under
# CLICOLOR_FORCE=1, and any script that treated that output as data (snapshot
# directories, backup names, the release zip) silently started comparing
# "\033[34mfoo" to "foo". A reviewer's shell had this exported; ours did not,
# which is how a red suite got reported as green. MUX0_NO_COLOR=1 opts out.
if [ "${MUX0_NO_COLOR:-0}" != "1" ]; then
    export CLICOLOR_FORCE=1 CLICOLOR=1
fi

RESULTS=""
FAILED=0
PASSED=0
SKIPPED=0

record() { # status name detail
    local status="$1" name="$2" detail="$3"
    RESULTS="${RESULTS}$(printf '  %-6s %-46s %s' "$status" "$name" "$detail")
"
    case "$status" in
        PASS) PASSED=$((PASSED + 1)) ;;
        SKIP) SKIPPED=$((SKIPPED + 1)) ;;
        *)    FAILED=$((FAILED + 1)) ;;
    esac
}

# run_case <label> <stdout-marker> <cmd...>
# A case passes when the command exits 0. When a marker is given it must also
# appear in the output, so a test that quietly stops asserting cannot go green.
# Output goes to a FILE, not into $( ): a test that dies mid-way can orphan a
# backgrounded socket server, and that orphan holds an inherited stdout pipe
# open — command substitution then blocks forever and the run never finishes.
run_case() {
    local label="$1" marker="$2"; shift 2
    local log rc watchdog n
    log="$(mktemp "${TMPDIR:-/tmp}/mux0-runall.XXXXXX")"

    "$@" >"$log" 2>&1 &
    local pid=$!
    (
        n=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            n=$((n + 1))
            if [ "$n" -ge "$CASE_TIMEOUT" ]; then
                pkill -TERM -P "$pid" 2>/dev/null
                kill -TERM "$pid" 2>/dev/null
                exit 0
            fi
        done
    ) &
    watchdog=$!
    wait "$pid"; rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null

    if [ "$VERBOSE" = "1" ]; then
        printf '\n===== %s =====\n%s\n' "$label" "$(cat "$log")"
    fi
    # A case may declare itself unrunnable here (missing interpreter, running
    # from inside a bundle without scripts/). That is an environment gap, not a
    # regression — say SKIP, but say it in the same breath as the reason.
    if grep -q 'TESTSKIP' "$log"; then
        record SKIP "$label" "$(grep -m1 'TESTSKIP' "$log" | sed 's/.*TESTSKIP[: ]*//')"
        rm -f "$log"
        return 0
    fi
    if [ "$rc" -eq 0 ] && { [ -z "$marker" ] || grep -qF "$marker" "$log"; }; then
        record PASS "$label" "$(grep -E 'passed|OK' "$log" | tail -1)"
        rm -f "$log"
        return 0
    fi
    record FAIL "$label" "exit=$rc"
    printf '\n----- %s: output (last 30 lines) -----\n%s\n' "$label" "$(tail -30 "$log")"
    rm -f "$log"
    return 1
}

echo "run-all: $(cd "$HERE/.." && pwd)"

# --- Python / node tests -------------------------------------------------
if python3 -c 'import pytest' >/dev/null 2>&1; then
    # -q keeps the noise down; test_agent_hook.py covers agent-hook.py and
    # pi_extension_test.py loads the real pi extension under node (self-skips
    # without node).
    run_case "pytest Resources/agent-hooks/tests" "passed" \
        python3 -m pytest "$HERE" -q
else
    record SKIP "pytest Resources/agent-hooks/tests" "python3 -m pytest unavailable"
fi

# --- shell tests, under every shell available ----------------------------
SHELLS=(bash)
command -v zsh >/dev/null 2>&1 && SHELLS+=(zsh)

for script in "$HERE"/*.sh; do
    name="$(basename "$script")"
    [ "$name" = "run-all.sh" ] && continue
    for sh in "${SHELLS[@]}"; do
        # Each test prints a distinct *OK sentinel on success.
        marker=""
        case "$name" in
            smoke.sh)                    marker="SMOKE OK" ;;
            codex_wrapper_cleanup.sh)    marker="WRAPPER_CLEANUP_OK" ;;
            grok_wrapper_overlay.sh)     marker="GROK_WRAPPER_OK" ;;
            grok_restore.sh)             marker="GROK_RESTORE_OK" ;;
            installer_backup_prune.sh)   marker="INSTALLER_OK" ;;
            installer_running_check.sh)  marker="INSTALLER_RUNNING_OK" ;;
        esac
        run_case "$sh tests/$name" "$marker" "$sh" "$script"
    done
done

echo
echo "run-all: results"
printf '%s' "$RESULTS"
echo "run-all: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
