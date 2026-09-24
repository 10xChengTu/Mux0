#!/bin/bash
# installer_backup_prune.sh — drive scripts/install.sh against throwaway --dest
# directories and check the things you can only see on disk:
#
#   round 1 (discovery): it prefers `Mux0-<version>.zip` over an *older*
#            `mux0-*.zip` that happens to be newer on disk — the release name is
#            the contract, mtime is not;
#   round 2 (backup + pruning, --zip given so discovery cannot mask anything):
#            the previous app is kept as `mux0-<old version>-backup.app`, the new
#            version really landed, and backups beyond the three newest are
#            actually deleted.
#
# Both rounds are regression tests for the same class of bug: pruning piped
# `ls -1dt … | while read`, and with CLICOLOR_FORCE=1 each line arrived as
# "\033[34m…backup.app", so `rm -rf` was aimed at a path that does not exist and
# backups piled up forever; the zip lookup had the same problem. Colours are
# forced on below instead of inherited, so a clean environment cannot hide it.
#
# Nothing here touches /Applications or launches anything.
#
# Every round passes --force: these rounds are about what lands on disk, and the
# "quit mux0 first" guard is global, so without it a developer who happens to be
# running mux0 while running the tests would see all four rounds refuse. The
# guard itself is covered by installer_running_check.sh.

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

ROOT=$(mktemp -d -t mux0-installer.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/pkg"
fail() { echo "INSTALLER_FAIL: $*" >&2; exit 1; }

# --- a fake app bundle (unsigned on purpose: install.sh only warns) ---------
make_app() { # <dir> <version> <build>
    mkdir -p "$1/Contents/MacOS"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key><string>com.mux0.app</string>\n\t<key>CFBundleName</key><string>mux0</string>\n\t<key>CFBundleExecutable</key><string>mux0</string>\n\t<key>CFBundleShortVersionString</key><string>%s</string>\n\t<key>CFBundleVersion</key><string>%s</string>\n</dict>\n</plist>\n' "$2" "$3" > "$1/Contents/Info.plist"
    printf '#!/bin/sh\necho mux0 %s\n' "$2" > "$1/Contents/MacOS/mux0"
    chmod +x "$1/Contents/MacOS/mux0"
}

version_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

make_app "$ROOT/stage/mux0.app" 9.9.9 900
( cd "$ROOT/stage" && zip -qr "$ROOT/pkg/Mux0-9.9.9.zip" mux0.app )
# A decoy in the older naming scheme that is *newer* on disk: Mux0-*.zip must
# still win.
make_app "$ROOT/old.app" 0.0.1 1
( cd "$ROOT" && zip -qr "$ROOT/pkg/mux0-0.0.1-universal.zip" old.app )
touch -t 209901010000 "$ROOT/pkg/mux0-0.0.1-universal.zip"

# install.sh looks for the zip next to itself — that is the shipped layout
# (dist/install.sh beside dist/Mux0-<v>.zip), so test that and nothing else.
cp "$INSTALLER" "$ROOT/pkg/install.sh"
chmod +x "$ROOT/pkg/install.sh"

# --- round 1: discovery ------------------------------------------------------
D1="$ROOT/apps1"; mkdir -p "$D1"
"$ROOT/pkg/install.sh" --dest "$D1" --no-open --force > "$ROOT/out1.log" 2>&1 \
    || { cat "$ROOT/out1.log" >&2; fail "round 1: install.sh exited non-zero"; }
grep -q 'package: .*Mux0-9\.9\.9\.zip' "$ROOT/out1.log" \
    || { cat "$ROOT/out1.log" >&2; fail "round 1: did not prefer Mux0-*.zip over a newer mux0-*.zip"; }
[ "$(version_of "$D1/mux0.app")" = "9.9.9" ] \
    || fail "round 1: installed $(version_of "$D1/mux0.app"), want 9.9.9"

# --- round 2: version-named backup + pruning (explicit --zip) ----------------
D2="$ROOT/apps2"; mkdir -p "$D2"
make_app "$D2/mux0.app" 0.8.4 3
for v in 0.8.1 0.8.2 0.8.3; do
    make_app "$D2/mux0-$v-backup.app" "$v" 1
done
# Unambiguous ordering: 0.8.1 oldest, 0.8.3 newest.
touch -t 202501010000 "$D2/mux0-0.8.1-backup.app"
touch -t 202501020000 "$D2/mux0-0.8.2-backup.app"
touch -t 202501030000 "$D2/mux0-0.8.3-backup.app"

"$ROOT/pkg/install.sh" --dest "$D2" --no-open --force --zip "$ROOT/pkg/Mux0-9.9.9.zip" \
        > "$ROOT/out2.log" 2>&1 \
    || { cat "$ROOT/out2.log" >&2; fail "round 2: install.sh exited non-zero"; }

[ -d "$D2/mux0-0.8.4-backup.app" ] \
    || fail "round 2: previous app was not kept as mux0-0.8.4-backup.app"
[ "$(version_of "$D2/mux0.app")" = "9.9.9" ] \
    || fail "round 2: installed $(version_of "$D2/mux0.app"), want 9.9.9"

# 4 backups existed right after the swap; only the three newest may survive.
count=$(find "$D2" -maxdepth 1 -type d -name 'mux0-*-backup*.app' | wc -l | tr -d ' ')
[ "$count" = "3" ] \
    || fail "round 2: expected 3 backups after pruning, found $count — rm -rf on a colour-decorated path deletes nothing"
[ ! -e "$D2/mux0-0.8.1-backup.app" ] || fail "round 2: oldest backup mux0-0.8.1-backup.app survived pruning"
for v in 0.8.2 0.8.3 0.8.4; do
    [ -d "$D2/mux0-$v-backup.app" ] || fail "round 2: backup mux0-$v-backup.app should have been kept"
done

# The run must actually have been under colours, or it proves nothing.
[ "${CLICOLOR_FORCE:-}" = "1" ] || fail "CLICOLOR_FORCE was not set — this test would pass trivially"

# --- round 3: the rollback copy must survive its own install ------------------
# `ditto` preserves the bundle's mtime, so a backup carries the *build* time, not
# the time it was made. Ordering backups "newest first" by that mtime can rank
# the copy you just created last, and `tail -n +4` then deletes the one file the
# user needs to roll back with.
rollback_survives() { # <label> <seed-app-mtime> <backup-mtime>…
    local label="$1" seed_mtime="$2"; shift 2
    local d="$ROOT/$label" v
    mkdir -p "$d"
    make_app "$d/mux0.app" 0.8.4 3
    touch -t "$seed_mtime" "$d/mux0.app"
    for v in 0.8.1 0.8.2 0.8.3; do
        make_app "$d/mux0-$v-backup.app" "$v" 1
        touch -t "$1" "$d/mux0-$v-backup.app"
    done

    "$ROOT/pkg/install.sh" --dest "$d" --no-open --force --zip "$ROOT/pkg/Mux0-9.9.9.zip" \
            > "$ROOT/$label.log" 2>&1 \
        || { cat "$ROOT/$label.log" >&2; fail "$label: install.sh exited non-zero"; }

    [ -d "$d/mux0-0.8.4-backup.app" ] \
        || fail "$label: the rollback copy mux0-0.8.4-backup.app was deleted by its own install"
    local n
    n=$(find "$d" -maxdepth 1 -type d -name 'mux0-*-backup*.app' | wc -l | tr -d ' ')
    [ "$n" = "3" ] || fail "$label: expected 3 backups, found $n"
    [ ! -e "$d/mux0-0.8.1-backup.app" ] \
        || fail "$label: the oldest backup should have been pruned instead of the new one"
}

# 3a. the seed app is older than every existing backup: deterministic pre-fix
# failure, the fresh copy sorts last and gets pruned.
rollback_survives round3a 202401010000 202501010000
# 3b. the ditto case: everything carries the same build mtime, so ordering is a
# four-way tie and only the explicit "never prune what we just made" rule saves it.
rollback_survives round3b 202501010000 202501010000

echo "INSTALLER_OK"
