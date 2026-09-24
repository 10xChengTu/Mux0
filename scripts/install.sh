#!/bin/bash
# install.sh — install mux0.app from the release zip into /Applications.
# Ships inside dist/ next to the zip. See usage() below for flags.
#
# The app is ad-hoc signed (no Developer ID, no notarization), so the only
# thing a user has to clear is the quarantine attribute — which this script
# strips after unpacking. Double-clicking mux0.app in Finder instead would
# need the right-click → Open dance on first launch.
set -euo pipefail

# Re-exec under bash when started through another shell (`zsh install.sh`),
# which is the default login shell on macOS.
if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
ZIP=""
DEST=""
OPEN_APP=1
DRY_RUN=0
FORCE=0
RUNNING_CHECK=0

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

  --zip PATH     zip to install (default: the newest Mux0-*.zip next to me,
                 then mux0-*.zip, then any other *.zip)
  --dest DIR     where to put mux0.app (default: /Applications, falling back
                 to ~/Applications when /Applications is not writable)
  --no-open      install but do not launch the app
  --force        install even while mux0 is running (not recommended: the
                 running process keeps the old bundle open, and its window
                 state can be rewritten over the new install)
  --dry-run      print what would happen, change nothing
  --running-check
                 only report whether mux0 looks like it is running: print the
                 matching pids and exit 0, or print "not-running" and exit 10.
                 Used by tests/installer_running_check.sh; changes nothing.
  -h, --help     this text

Environment: MUX0_INSTALL_EXE_SUFFIX overrides the executable path suffix that
counts as "mux0 is running" (tests point it at a throwaway bundle).

What it does: refuses to touch a running mux0, moves the previous app aside
as mux0-<old version>-backup.app, unpacks the zip with ditto, strips the
quarantine attribute, verifies the code signature and prints the version.
USAGE
}

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

# Files / directories in $1 matching the glob $2, newest first, one path per line.
#
# Deliberately not `ls`: with CLICOLOR_FORCE=1 ls decorates its output with ANSI
# colours, so `ZIP=$(ls -1t …)` yielded a path that exists nowhere, and the
# backup-pruning loop handed `rm -rf` a decorated name — old backups simply
# never went away. find + stat never colourise.
newest_first() {
    find "$1" -maxdepth 1 -type f -name "$2" -exec stat -f '%m %N' {} + 2>/dev/null \
        | sort -nr \
        | sed 's/^[0-9][0-9]* //'
}

newest_first_dirs() {
    find "$1" -maxdepth 1 -type d -name "$2" -exec stat -f '%m %N' {} + 2>/dev/null \
        | sort -nr \
        | sed 's/^[0-9][0-9]* //'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --zip)    ZIP="${2:?--zip needs a path}"; shift 2 ;;
        --dest)   DEST="${2:?--dest needs a path}"; shift 2 ;;
        --no-open) OPEN_APP=0; shift ;;
        --force)  FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --running-check) RUNNING_CHECK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# --- refuse to install over a running app -----------------------------------
# Replacing the bundle under a live process is how you get a window that looks
# like the old build and a settings file written by two versions at once, so
# the safe default is to stop and tell the user to quit mux0 first.
#
# What counts as "this app": the executable path of a bundle's main binary is
# always <somewhere>/mux0.app/Contents/MacOS/mux0, so the *path* is the
# identifier — it works for any install location (/Applications, ~/Applications,
# a staging dir) and does not match an unrelated program that happens to be
# called mux0 (a checkout's test helper, say).
#
# Matching on the process *name* alone is not enough. On at least one user's
# MacBook the app was demonstrably running — `ps -o comm=` reported
# /Applications/mux0.app/Contents/MacOS/mux0 — while `pgrep -x mux0`,
# `pgrep -ix mux0` and `pgrep -l mux0` all came back empty (`pgrep -x Finder`
# worked). The guard then never fired and the install swapped the bundle under a
# live process. So `ps -ax -o pid=,comm=` is the primary source; pgrep stays
# only as an extra hint for processes whose reported name carries no path, and
# those are verified by path before being counted.
MUX0_EXE_SUFFIX="${MUX0_INSTALL_EXE_SUFFIX:-/mux0.app/Contents/MacOS/mux0}"

path_is_mux0() { # <executable path or argv[0]>
    case "$1" in
        *"$MUX0_EXE_SUFFIX") return 0 ;;
    esac
    return 1
}

# pids of running mux0.app processes, one per line.
#
# `ps -o comm=` prints argv[0], not a kernel-resolved path, so the two sources
# below cover each other's blind spot: one reads the reported path, the other
# asks which image is mapped. Either alone can miss a live app.
mux0_running_pids() {
    local pid path
    {
        # -ww: never truncate the line to the terminal width — a deep install
        # path must not lose the suffix being matched.
        while read -r pid path; do
            [ -n "${pid:-}" ] || continue
            if path_is_mux0 "$path"; then echo "$pid"; fi
        done < <(ps -ax -ww -o pid=,comm= 2>/dev/null)

        # Second source, never the only one: a process whose reported name is a
        # bare `mux0`, i.e. argv[0] carries no directory part (`ps -o comm=`
        # prints argv[0], which a launcher or the app itself can rewrite). Ask
        # which image is actually mapped before trusting it — that also keeps an
        # unrelated `mux0` binary out of the list. NB: no -ax with -p, BSD ps
        # would then ignore -p and list every process.
        for pid in $(pgrep -x mux0 2>/dev/null || true); do
            path=$(ps -ww -o comm= -p "$pid" 2>/dev/null | head -1)
            case "$path" in */*) continue ;; esac       # the scan above saw it
            command -v lsof >/dev/null 2>&1 || continue
            path=$(lsof -p "$pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
            if path_is_mux0 "$path"; then echo "$pid"; fi
        done
    } | sort -n -u
}

RUNNING_PIDS=""
if [ "$FORCE" != "1" ] || [ "$RUNNING_CHECK" = "1" ]; then
    RUNNING_PIDS=$(mux0_running_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//') || true
fi

if [ "$RUNNING_CHECK" = "1" ]; then
    if [ -n "$RUNNING_PIDS" ]; then
        echo "running: $RUNNING_PIDS"
        exit 0
    fi
    echo "not-running"
    exit 10
fi

if [ -n "$RUNNING_PIDS" ]; then
    note "mux0 is running (pid $RUNNING_PIDS) — quit it with Cmd-Q first,"
    note "or re-run with --force to install anyway."
    exit 1
fi

# --- locate the zip ---------------------------------------------------------
if [ -z "$ZIP" ]; then
    for pattern in 'Mux0-*.zip' 'mux0-*.zip' '*.zip'; do
        ZIP=$(newest_first "$SCRIPT_DIR" "$pattern" | head -1)
        [ -n "$ZIP" ] && break
    done
fi
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "no mux0 zip found next to install.sh (pass --zip PATH)"
note "package: $ZIP"

# --- pick the destination ---------------------------------------------------
if [ -z "$DEST" ]; then
    if [ -w /Applications ] || [ "$(id -u)" = "0" ]; then
        DEST=/Applications
    else
        DEST="$HOME/Applications"
        note "/Applications is not writable by $(id -un); using $DEST instead"
        note "(re-run with sudo to install system-wide: sudo ./install.sh --dest /Applications)"
    fi
fi
mkdir -p "$DEST"
TARGET="$DEST/mux0.app"

# --- unpack to a temp dir, verify, then swap ---------------------------------
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mux0-install.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

note "unpacking…"
unzip -q -o "$ZIP" -d "$STAGE"
[ -d "$STAGE/mux0.app" ] || die "zip does not contain mux0.app at its root"
NEW="$STAGE/mux0.app"

# Quarantine: set by browsers / AirDrop; blocks an ad-hoc signed app on first
# launch. Removing it is what makes "unzip → run install.sh" work with a plain
# double-click afterwards.
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || echo "?"; }
VERSION=$(plist_value CFBundleShortVersionString "$NEW/Contents/Info.plist")
BUILD=$(plist_value CFBundleVersion "$NEW/Contents/Info.plist")
note "version: v$VERSION (build $BUILD)"

if ! codesign --verify --deep --strict "$NEW" 2>/dev/null; then
    note "warning: code signature does not verify (the app may still run)"
fi

if [ "$DRY_RUN" = "1" ]; then
    [ -e "$TARGET" ] && note "would back up $TARGET as $(basename "$DEST")/mux0-$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist")-backup.app"
    note "would install v$VERSION to $TARGET"
    [ "$OPEN_APP" = "1" ] && note "would open $TARGET"
    exit 0
fi

# Back up whatever is there now. A previous install is *not* deleted outright:
# it is renamed aside, named after the version it carries, so rolling back is
# one `mv` and it is obvious which version you are rolling back to.
if [ -e "$TARGET" ]; then
    OLD_VERSION=$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist")
    OLD_BUILD=$(plist_value CFBundleVersion "$TARGET/Contents/Info.plist")
    BACKUP="$DEST/mux0-$OLD_VERSION-backup.app"
    if [ -e "$BACKUP" ]; then
        BACKUP="$DEST/mux0-$OLD_VERSION-backup-$(date +%Y%m%d-%H%M%S).app"
    fi
    note "existing mux0 v$OLD_VERSION (build $OLD_BUILD) → $(basename "$BACKUP")"
    mv "$TARGET" "$BACKUP"
    # Pin the fresh copy to *now*. `ditto` preserves the bundle's mtime, so a
    # backup carries the timestamp of whichever build produced it — and several
    # backups made from the same build all tie. Ties fall back to path order, so
    # the rollback copy you just made could rank last and get pruned by the very
    # install that created it. Pruning means "keep the three newest installs",
    # so the ordering key has to be when it was installed.
    touch "$BACKUP"
    # Keep at most 3 backups so repeated installs cannot fill the disk.
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        # Belt and braces: never prune the copy this run just made, whatever the
        # filesystem says about its mtime.
        if [ "$old" = "$BACKUP" ]; then continue; fi
        note "pruning old backup $(basename "$old")"
        rm -rf "$old"
    done < <(newest_first_dirs "$DEST" 'mux0-*-backup*.app' | tail -n +4)
fi

note "installing to $TARGET"
# ditto (not cp) keeps the bundle's metadata and code signature intact.
ditto "$NEW" "$TARGET"

# Read the version back out of the *installed* bundle — that is the number the
# user's About panel will show, so it is the one worth printing.
note "installed: v$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist") \
(build $(plist_value CFBundleVersion "$TARGET/Contents/Info.plist")) at $TARGET"
codesign --verify --deep --strict "$TARGET" 2>/dev/null \
    && note "signature: ok" \
    || note "warning: signature does not verify on the installed copy"

if [ "$OPEN_APP" = "1" ]; then
    note "launching $TARGET"
    open "$TARGET"
else
    note "done — run it with: open '$TARGET'"
fi
