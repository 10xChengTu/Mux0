#!/bin/bash
# codex_wrapper_cleanup.sh — end-to-end smoke that proves codex-wrapper.sh
# actually runs its cleanup trap after codex exits. The wrapper used to
# `exec "$REAL_CODEX" ...`, which silently nuked the EXIT trap — so the
# overlay's hooks.state (where codex persists /hooks trust approvals) and
# config.toml writes never got copied back to the user's real CODEX_HOME,
# leaving every mux0-launched codex session untrusted again. This test
# guards against that regression by faking codex with a script that writes
# a recognisable hooks.state into $CODEX_HOME and asserting the file ends
# up in the user's CODEX_HOME after the wrapper returns.

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$HERE/.."
WRAPPER="$SCRIPT_DIR/codex-wrapper.sh"

FAKE_HOME=$(mktemp -d -t mux0-codex-home.XXXXXX)
FAKE_BIN_DIR=$(mktemp -d -t mux0-codex-bin.XXXXXX)
USER_CODEX_HOME="$FAKE_HOME/.codex"
mkdir -p "$USER_CODEX_HOME"

cleanup_test() {
    rm -rf "$FAKE_HOME" "$FAKE_BIN_DIR"
}
trap cleanup_test EXIT INT TERM

# Fake codex: simulate a /hooks approve by writing hooks.state via the same
# `tempfile + rename(2)` dance the real codex uses, then exit cleanly.
FAKE_CODEX="$FAKE_BIN_DIR/codex"
cat > "$FAKE_CODEX" <<'FAKE'
#!/bin/bash
set -e
NEW_STATE="$CODEX_HOME/.hooks.state.tmp.$$"
cat > "$NEW_STATE" <<TOML
[hook.UserPromptSubmit]
trusted = true
trusted_hash = "smoke-test-hash"
TOML
mv "$NEW_STATE" "$CODEX_HOME/hooks.state"

# Also touch config.toml the same way to cover the original writeback path.
NEW_CFG="$CODEX_HOME/.config.toml.tmp.$$"
echo "smoke = true" > "$NEW_CFG"
mv "$NEW_CFG" "$CODEX_HOME/config.toml"
FAKE
chmod +x "$FAKE_CODEX"

# Drive the wrapper. We can't use a real Unix-domain socket here without
# spinning one up; pointing $MUX0_HOOK_SOCK at /dev/null is fine because the
# wrapper's hook-emit.sh invocations are all guarded with `|| true`.
HOME="$FAKE_HOME" \
CODEX_HOME="$USER_CODEX_HOME" \
MUX0_REAL_CODEX="$FAKE_CODEX" \
MUX0_AGENT_HOOKS_DIR="$SCRIPT_DIR" \
MUX0_HOOK_SOCK="/dev/null" \
MUX0_TERMINAL_ID="WRAPPERSMOKE" \
bash "$WRAPPER" >/dev/null 2>&1

# Assertions
if [ ! -f "$USER_CODEX_HOME/hooks.state" ]; then
    echo "FAIL: cleanup did not copy hooks.state back to $USER_CODEX_HOME"
    echo "(this means the EXIT trap never fired — typical sign that the"
    echo " wrapper used 'exec \$REAL_CODEX' again instead of subprocess+wait)"
    exit 1
fi

if ! grep -q "smoke-test-hash" "$USER_CODEX_HOME/hooks.state"; then
    echo "FAIL: hooks.state contents were not preserved"
    cat "$USER_CODEX_HOME/hooks.state"
    exit 1
fi

if [ ! -f "$USER_CODEX_HOME/config.toml" ]; then
    echo "FAIL: cleanup did not copy config.toml back (regression of a2ca37d)"
    exit 1
fi

if ! grep -q "smoke = true" "$USER_CODEX_HOME/config.toml"; then
    echo "FAIL: config.toml contents were not preserved"
    cat "$USER_CODEX_HOME/config.toml"
    exit 1
fi

echo "WRAPPER_CLEANUP_OK"
