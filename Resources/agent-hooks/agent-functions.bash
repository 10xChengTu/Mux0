# agent-functions.bash — override agent CLI names to point at our wrappers.
# Called by bootstrap.bash.
[ -z "$MUX0_AGENT_HOOKS_DIR" ] && return 0

claude()   { command "$MUX0_AGENT_HOOKS_DIR/claude-wrapper.sh"   "$@"; }
opencode() { command "$MUX0_AGENT_HOOKS_DIR/opencode-wrapper.sh" "$@"; }
codex()    { command "$MUX0_AGENT_HOOKS_DIR/codex-wrapper.sh"    "$@"; }
pi()       { command "$MUX0_AGENT_HOOKS_DIR/pi-wrapper.sh"       "$@"; }
grok()     { command "$MUX0_AGENT_HOOKS_DIR/grok-wrapper.sh"     "$@"; }

export -f claude opencode codex pi grok 2>/dev/null || true
