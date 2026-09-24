# agent-functions.zsh — override agent CLI names to point at our wrappers.
# Called by bootstrap.zsh.
[ -z "$MUX0_AGENT_HOOKS_DIR" ] && return 0

# CRITICAL: zsh performs alias expansion on function names during parsing.
# If the user has `alias claude=...` in their rc, writing `claude() { ... }`
# below would expand to `claude --extra-args() { ... }` and fail to parse
# (taking the rest of this file down with it). The `\name` form escapes the
# first character, disabling alias expansion on the function-name position.
# The user's alias still expands at COMMAND SITES (when they type `claude`),
# so their `claude --dangerously-skip-permissions` alias still works — the
# expanded first word resolves to our function, which forwards "$@".

\claude() {
    command "$MUX0_AGENT_HOOKS_DIR/claude-wrapper.sh" "$@"
}

\opencode() {
    command "$MUX0_AGENT_HOOKS_DIR/opencode-wrapper.sh" "$@"
}

\codex() {
    command "$MUX0_AGENT_HOOKS_DIR/codex-wrapper.sh" "$@"
}

\pi() {
    command "$MUX0_AGENT_HOOKS_DIR/pi-wrapper.sh" "$@"
}

\grok() {
    command "$MUX0_AGENT_HOOKS_DIR/grok-wrapper.sh" "$@"
}
