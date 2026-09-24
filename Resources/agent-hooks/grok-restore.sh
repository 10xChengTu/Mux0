#!/bin/bash
# grok-restore.sh — undo everything mux0 does to the grok side of this machine.
#
# Primary (current) injection strategy is *not* a ~/.grok edit: `grok-wrapper.sh`
# points `GROK_HOME` at a private symlink overlay under
# ~/Library/Caches/mux0/grok-overlay and owns exactly one file inside it
# (`hooks/mux0.json`). So for today's installs "restore" is just deleting that
# overlay — nothing under ~/.grok was ever rewritten by us.
#
# The fallback strategy (documented in docs/agent-hooks.md) does write into the
# user's ~/.grok — a `hooks/mux0.json`, or an include line in `config.toml`.
# Any such writer must record what it did:
#
#   $GROK_HOME/.mux0-backup/<UTC timestamp>/<relative path>   original content
#                                        ("new file" is written as an empty
#                                         file named "<relpath>.NEW")
#   $GROK_HOME/.mux0-backup/CHANGES.log   one TAB-separated line per change:
#                                        <timestamp>\t<new|modify|delete>\t<relpath>\t<reason>
#
# This script replays that log backwards (newest change per path wins) and then
# removes the overlay, so it restores either strategy. It never touches grok's
# own runtime data (`sessions/`, `logs/`, `active_sessions.json`), which mux0
# deliberately leaves pointing at the real ~/.grok so `grok --resume` keeps
# working in a plain Terminal.
#
# Usage:
#   grok-restore.sh [--dry-run] [--home DIR] [--keep-overlay]
set -euo pipefail

DRY=0
KEEP_OVERLAY=0
HOME_DIR="${MUX0_GROK_RESTORE_HOME:-${GROK_HOME:-$HOME/.grok}}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY=1; shift ;;
        --keep-overlay) KEEP_OVERLAY=1; shift ;;
        --home)         HOME_DIR="${2:?--home needs a path}"; shift 2 ;;
        -h|--help)      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "grok-restore.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

say() { echo "grok-restore: $*"; }
run() { if [ "$DRY" = "1" ]; then echo "  would: $*"; else "$@"; fi; }

# Snapshot directories, oldest mtime first, printed one per line.
#
# Never `ls` here. With CLICOLOR_FORCE=1 (set by CI runners and by plenty of
# interactive dotfiles) ls writes "\033[34m<name>\033[39;49m\033[0m", and that
# escape sequence became part of the path: `[ -e "${snap}${path}" ]` was always
# false, so a B-style restore printed "no backup found" and quietly left mux0's
# edits in the user's config.toml. find + stat never colourise.
snapshots_oldest_first() {
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} + 2>/dev/null \
        | sort -n \
        | sed 's/^[0-9][0-9]* //'
}

# Refuse to "restore" an overlay: an overlay has no backup log and its hooks/
# directory is ours by definition, so pointing --home at one would be a mistake.
case "$HOME_DIR" in
    */Library/Caches/mux0/*)
        say "refusing to restore into what looks like an overlay: $HOME_DIR"
        say "pass --home \$HOME/.grok for the real directory"
        exit 1 ;;
esac

BACKUP_DIR="$HOME_DIR/.mux0-backup"
CHANGES="$BACKUP_DIR/CHANGES.log"
CHANGED=0

if [ -f "$CHANGES" ]; then
    say "replaying $(basename "$CHANGES") from $HOME_DIR"
    # Walk the log newest-first and act on the first entry seen per path (that
    # is the current state of that file); the *original* content is the oldest
    # snapshot that still has it, since later snapshots may hold mux0's edits.
    handled=""
    while IFS=$'\t' read -r _ts action path _reason; do
        [ -n "$path" ] || continue
        path="${path#/}"          # snapshots are joined as "$snap/$path"
        case "$handled" in *"|$path|"*) continue ;; esac
        handled="$handled|$path|"
        src=""
        while IFS= read -r snap; do
            [ -n "$snap" ] || continue
            if [ -z "$src" ] && [ -e "$snap/$path" ]; then
                src="$snap/$path"
            fi
        done < <(snapshots_oldest_first)
        case "$action" in
            new)
                say "remove $path (created by mux0)"
                run rm -f "$HOME_DIR/$path"
                CHANGED=1 ;;
            modify)
                if [ -n "$src" ]; then
                    say "restore $path from snapshot $(basename "$(dirname "$src")")"
                    run cp -p "$src" "$HOME_DIR/$path"
                    CHANGED=1
                else
                    say "WARN no backup found for $path — left as is"
                fi ;;
            delete)
                if [ -n "$src" ]; then
                    say "restore deleted $path from snapshot $(basename "$(dirname "$src")")"
                    run mkdir -p "$(dirname "$HOME_DIR/$path")"
                    run cp -p "$src" "$HOME_DIR/$path"
                    CHANGED=1
                else
                    say "WARN $path was deleted but no backup exists"
                fi ;;
            restore) : ;;
            *) say "WARN unknown action '$action' for $path" ;;
        esac
    done < <(tail -r "$CHANGES")
    if [ "$DRY" = "0" ]; then
        printf '%s\trestore\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "*" \
            "grok-restore.sh replayed $(grep -c . "$CHANGES") entries" >> "$CHANGES"
    fi
else
    say "no $CHANGES — mux0 never edited $HOME_DIR directly"
fi

# Leftover hook file from a fallback install, or from an interrupted run.
if [ -f "$HOME_DIR/hooks/mux0.json" ]; then
    if grep -q "agent-hook" "$HOME_DIR/hooks/mux0.json" 2>/dev/null; then
        say "remove $HOME_DIR/hooks/mux0.json (mux0's own hook file)"
        run rm -f "$HOME_DIR/hooks/mux0.json"
        CHANGED=1
    else
        say "kept $HOME_DIR/hooks/mux0.json — it does not look like ours"
    fi
fi

if [ "$KEEP_OVERLAY" = "0" ]; then
    for overlay in "$HOME/Library/Caches/mux0/grok-overlay" \
                   "$HOME/Library/Caches/mux0/grok-overlay-probe" \
                   "$HOME/Library/Caches/mux0/grok-overlay-test"; do
        if [ -e "$overlay" ]; then
            say "remove overlay $overlay"
            # Symlinks first, then the real files grok wrote here — never
            # follow the symlinks, or we would delete the user's real data.
            run find "$overlay" -type l -delete
            run rm -rf "$overlay"
            CHANGED=1
        fi
    done
fi

if [ "$CHANGED" = "0" ]; then
    say "nothing to do — grok config is already clean"
else
    say "done. grok sessions/logs under $HOME_DIR were left untouched on purpose."
fi
