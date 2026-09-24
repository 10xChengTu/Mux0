#!/bin/bash
# installer_running_check.sh — drive scripts/install.sh's "mux0 is running"
# guard against fake processes and check what it actually sees.
#
# Why this exists: the guard used to be `pgrep -x mux0` plus a path filter. On a
# user's MacBook the app was demonstrably running — `ps -o comm=` reported
# /Applications/mux0.app/Contents/MacOS/mux0 — while `pgrep -x mux0`,
# `pgrep -ix mux0` and `pgrep -l mux0` all returned nothing, so install.sh
# installed straight over a live process and the guard was decoration. The check
# is now a path-suffix match over `ps -ax -ww -o pid=,comm=` (pgrep only as an
# extra hint, always verified by path).
#
# What is asserted, with a fake app bundle process and a decoy binary that is
# also called mux0 but lives outside a bundle:
#
#   1. detection finds the fake app by its executable path, and does not count
#      the decoy (an unrelated program named mux0 must never block an install);
#   2. while it runs, install.sh exits non-zero and says so — plain and --dry-run
#      both refuse, --force still installs — including with a `pgrep` on PATH
#      that reports nothing, which is the field failure this guards against;
#   3. once it is gone, install.sh installs normally.
#
# Nothing here touches /Applications, launches the real app, or depends on
# whether the machine running the test happens to have mux0 open: the guard is
# pointed at the throwaway bundle through MUX0_INSTALL_EXE_SUFFIX, so a real
# mux0 on the developer's machine cannot turn these rounds red or green.

if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

set -e

export CLICOLOR_FORCE=1 CLICOLOR=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALLER="$HERE/../../../scripts/install.sh"
if [ ! -f "$INSTALLER" ]; then
    # Running from inside a built .app: tests/ ships, scripts/ does not.
    echo "TESTSKIP scripts/install.sh not next to this bundle — run this test from a source tree"
    exit 0
fi

ROOT=$(mktemp -d -t mux0-running.XXXXXX)
FAKE_PIDS=""
FAKE_PID=""
cleanup() {
    for p in $FAKE_PIDS; do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true   # reap quietly, no "Terminated" job notice
    done
    rm -rf "$ROOT"
}
trap cleanup EXIT
fail() { echo "RUNNING_CHECK_FAIL: $*" >&2; exit 1; }

# --- fake processes ----------------------------------------------------------
# `ps -o comm=` reports the path that was exec'd, so a symlink into the bundle
# is enough to make a process look like the app; copying a platform binary
# instead (cp /bin/sleep) gets it SIGKILLed by the code-signing check.
# Sets FAKE_PID. Not $(mkfake …): a background process started inside a command
# substitution is not tracked by the parent's trap and would outlive the test.
mkfake() { # <path>
    mkdir -p "$(dirname "$1")"
    ln -s /bin/sleep "$1"
    "$1" 600 &
    FAKE_PID=$!
    FAKE_PIDS="$FAKE_PIDS $FAKE_PID"
}

# the app: <somewhere>/mux0.app/Contents/MacOS/mux0
APP_DIR="$ROOT/installs"
mkdir -p "$APP_DIR"
APP_EXE="$APP_DIR/mux0.app/Contents/MacOS/mux0"
mkfake "$APP_EXE"; APP_PID="$FAKE_PID"
# the decoy: a binary named mux0 that is not the app
mkfake "$ROOT/tools/mux0"; DECOY_PID="$FAKE_PID"
sleep 1
kill -0 "$APP_PID" 2>/dev/null || fail "fake app process died immediately"
kill -0 "$DECOY_PID" 2>/dev/null || fail "fake decoy died immediately"
ps -o comm= -p "$APP_PID" 2>/dev/null | grep -qF "$APP_EXE" \
    || fail "ps does not report the fake app path (test harness problem): $(ps -o comm= -p "$APP_PID" 2>/dev/null)"

# --- 1. what the guard sees --------------------------------------------------
OUT="$ROOT/check-default.log"
set +e
"$INSTALLER" --running-check > "$OUT" 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || { cat "$OUT" >&2; fail "--running-check exited $rc, want 0 (fake app is running)"; }
grep -qw "$APP_PID" "$OUT" \
    || { cat "$OUT" >&2; fail "--running-check did not report the running app pid $APP_PID (this is the pgrep-style blind spot)"; }
if grep -qw "$DECOY_PID" "$OUT"; then
    cat "$OUT" >&2
    fail "--running-check counted $DECOY_PID, which is a program named mux0 outside any mux0.app bundle"
fi

# 1b. a process that reports a bare `mux0` as its name. `ps -o comm=` prints
# argv[0], which a launcher (or the app itself) can rewrite, so the path scan
# above cannot see it — the mapped image has to be asked for. Needs a real
# Mach-O inside the bundle: `cp /bin/sleep` gets SIGKILLed by the signature
# check and a symlink resolves out of the bundle, so compile one (88 ms).
CC=""
for c in cc clang; do
    command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
done
if [ -n "$CC" ]; then
    REAL_APP="$ROOT/real/mux0.app/Contents/MacOS/mux0"
    mkdir -p "$(dirname "$REAL_APP")"
    printf '#include <unistd.h>\nint main(void){for(;;)sleep(1);return 0;}\n' > "$ROOT/real/m.c"
    "$CC" -o "$REAL_APP" "$ROOT/real/m.c" || fail "could not compile the fake app binary"
    bash -c 'exec -a mux0 "$1" 600' _ "$REAL_APP" &
    REAL_PID=$!
    FAKE_PIDS="$FAKE_PIDS $REAL_PID"
    sleep 1
    [ "$(ps -ww -o comm= -p "$REAL_PID" 2>/dev/null)" = "mux0" ] \
        || { kill "$REAL_PID" 2>/dev/null; fail "harness: argv[0] rewrite did not take"; }
    set +e
    MUX0_INSTALL_EXE_SUFFIX="$REAL_APP" "$INSTALLER" --running-check > "$ROOT/check-barename.log" 2>&1
    rc=$?
    set -e
    [ "$rc" = "0" ] || { cat "$ROOT/check-barename.log" >&2; fail "a running mux0 that reports a bare argv[0] was missed (exit $rc)"; }
    grep -qw "$REAL_PID" "$ROOT/check-barename.log" \
        || fail "bare-argv[0] mux0 not reported: $(cat "$ROOT/check-barename.log")"
else
    echo "note: no C compiler on PATH, skipped the bare-argv[0] round"
fi

# Deterministic baseline for the rounds below: point the guard at this bundle.
export MUX0_INSTALL_EXE_SUFFIX="$APP_EXE"

# --- a throwaway package to install -----------------------------------------
make_app() { # <dir> <version> <build>
    mkdir -p "$1/Contents/MacOS"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key><string>com.mux0.app</string>\n\t<key>CFBundleName</key><string>mux0</string>\n\t<key>CFBundleExecutable</key><string>mux0</string>\n\t<key>CFBundleShortVersionString</key><string>%s</string>\n\t<key>CFBundleVersion</key><string>%s</string>\n</dict>\n</plist>\n' "$2" "$3" > "$1/Contents/Info.plist"
    printf '#!/bin/sh\necho mux0 %s\n' "$2" > "$1/Contents/MacOS/mux0"
    chmod +x "$1/Contents/MacOS/mux0"
}
make_app "$ROOT/stage/mux0.app" 9.9.9 900
mkdir -p "$ROOT/pkg"
( cd "$ROOT/stage" && zip -qr "$ROOT/pkg/Mux0-9.9.9.zip" mux0.app )
cp "$INSTALLER" "$ROOT/pkg/install.sh"
chmod +x "$ROOT/pkg/install.sh"

# --- 2. while it runs, an install refuses ------------------------------------
D1="$ROOT/apps1"; mkdir -p "$D1"
set +e
"$ROOT/pkg/install.sh" --dest "$D1" --no-open > "$ROOT/out-refuse.log" 2>&1
rc=$?
set -e
[ "$rc" != "0" ] || fail "install.sh returned 0 while mux0 (pid $APP_PID) was running"
grep -q 'mux0 is running' "$ROOT/out-refuse.log" \
    || { cat "$ROOT/out-refuse.log" >&2; fail "install.sh exited $rc but did not say why"; }
grep -qw "$APP_PID" "$ROOT/out-refuse.log" \
    || fail "refusal message does not name the running pid: $(cat "$ROOT/out-refuse.log")"
[ ! -e "$D1/mux0.app" ] || fail "install.sh touched the destination while refusing"

# 2b. the exact field failure: a pgrep that reports nothing while the app runs
# (what the user's MacBook did). The guard must not depend on it. Under the old
# `pgrep -x mux0`-based check this round is red — the install goes ahead.
mkdir -p "$ROOT/shim"
cat > "$ROOT/shim/pgrep" <<'SHIM'
#!/bin/bash
# a pgrep that behaves like the one on that MacBook: the app runs, it says no
exit 1
SHIM
chmod +x "$ROOT/shim/pgrep"
D1B="$ROOT/apps1b"; mkdir -p "$D1B"
set +e
PATH="$ROOT/shim:$PATH" "$ROOT/pkg/install.sh" --dest "$D1B" --no-open > "$ROOT/out-lying-pgrep.log" 2>&1
rc=$?
set -e
[ "$rc" != "0" ] || fail "install.sh installed over a running mux0 because pgrep said nothing (old behaviour)"
grep -q 'mux0 is running' "$ROOT/out-lying-pgrep.log" \
    || { cat "$ROOT/out-lying-pgrep.log" >&2; fail "lying-pgrep round exited $rc but did not say why"; }
[ ! -e "$D1B/mux0.app" ] || fail "lying-pgrep round touched the destination while refusing"

# --dry-run refuses too: it is the run-a-user-does-before-installing.
set +e
"$ROOT/pkg/install.sh" --dest "$D1" --no-open --dry-run > "$ROOT/out-dryrun.log" 2>&1
rc=$?
set -e
[ "$rc" != "0" ] || fail "install.sh --dry-run returned 0 while mux0 was running"
grep -q 'mux0 is running' "$ROOT/out-dryrun.log" \
    || { cat "$ROOT/out-dryrun.log" >&2; fail "--dry-run exited $rc but did not say why"; }

# --force is the documented escape hatch and must still work.
set +e
"$ROOT/pkg/install.sh" --dest "$D1" --no-open --force > "$ROOT/out-force.log" 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || { cat "$ROOT/out-force.log" >&2; fail "install.sh --force exited $rc"; }
[ -d "$D1/mux0.app" ] || fail "install.sh --force did not install"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$D1/mux0.app/Contents/Info.plist" 2>/dev/null | grep -qx '9.9.9' \
    || fail "install.sh --force installed the wrong version"

# --- 3. once it is gone, install proceeds ------------------------------------
kill "$APP_PID" 2>/dev/null || true
# `wait` both reaps (so `kill -0` below cannot be fooled by a zombie) and blocks
# until the process is really gone, so ps cannot still be listing it.
wait "$APP_PID" 2>/dev/null || true
if kill -0 "$APP_PID" 2>/dev/null; then fail "fake app process $APP_PID would not die"; fi

set +e
"$INSTALLER" --running-check > "$ROOT/check-gone.log" 2>&1
rc=$?
set -e
[ "$rc" = "10" ] || { cat "$ROOT/check-gone.log" >&2; fail "--running-check exited $rc after the app quit, want 10 (not-running)"; }
grep -q 'not-running' "$ROOT/check-gone.log" || fail "--running-check output: $(cat "$ROOT/check-gone.log")"

D2="$ROOT/apps2"; mkdir -p "$D2"
set +e
"$ROOT/pkg/install.sh" --dest "$D2" --no-open > "$ROOT/out-after.log" 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || { cat "$ROOT/out-after.log" >&2; fail "install.sh exited $rc after mux0 quit"; }
[ -d "$D2/mux0.app" ] || fail "install.sh did not install after mux0 quit"

# The decoy is still alive the whole time: an unrelated mux0 must not block a
# real install either.
kill -0 "$DECOY_PID" 2>/dev/null || fail "decoy died mid-test, later assertions mean nothing"

[ "${CLICOLOR_FORCE:-}" = "1" ] || fail "CLICOLOR_FORCE was not set — this test would pass trivially"

echo "INSTALLER_RUNNING_OK"
