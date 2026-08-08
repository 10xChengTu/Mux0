# mux0 shim vendor_conf.d — installed via XDG_DATA_DIRS injection in GhosttyBridge.
# fish has no ZDOTDIR-style hijack; it auto-loads fish/vendor_conf.d/*.fish from
# every XDG_DATA_DIRS entry at startup. Two jobs:
#   1. Source bootstrap.fish (defines claude/opencode/codex wrapper functions)
#      when running inside mux0 (MUX0_AGENT_HOOKS_DIR set), interactive only.
#   2. Remove our XDG_DATA_DIRS entry again so it doesn't leak into XDG-aware
#      tools or nested shells (mirrors ghostty's ghostty_restore_xdg_data_dir).

function __mux0_restore_xdg_data_dir -d "remove mux0's XDG_DATA_DIRS entry"
    if not set -q MUX0_XDG_DATA_DIR
        return
    end
    if set -q XDG_DATA_DIRS
        set --function --path xdg_data_dirs "$XDG_DATA_DIRS"
        if set --function index (contains --index "$MUX0_XDG_DATA_DIR" $xdg_data_dirs)
            set --erase --function xdg_data_dirs[$index]
        end
        if set -q xdg_data_dirs[1]
            set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
        else
            set --erase --global XDG_DATA_DIRS
        end
    end
    set --erase MUX0_XDG_DATA_DIR
end

if status --is-interactive; and set -q MUX0_AGENT_HOOKS_DIR
    test -f "$MUX0_AGENT_HOOKS_DIR/bootstrap.fish"; and source "$MUX0_AGENT_HOOKS_DIR/bootstrap.fish"
end

__mux0_restore_xdg_data_dir
functions -e __mux0_restore_xdg_data_dir
