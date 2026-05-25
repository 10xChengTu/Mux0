#!/usr/bin/env python3
"""agent-hook.py — agent lifecycle dispatch for Claude Code / Codex hooks.

Invoked by agent-hook.sh. Reads environment variables set by the bash entry
(_MUX0_SUBCMD, _MUX0_AGENT, _MUX0_PAYLOAD, _MUX0_SESSION_FILE, plus
MUX0_TERMINAL_ID and MUX0_HOOK_SOCK). Dispatches on subcommand, updates the
session JSON file, and optionally emits a socket message.

Subcommands:
    prompt    — UserPromptSubmit: reset turn state, emit `running`
    pretool   — PreToolUse: record current tool, emit `running` + toolDetail
    posttool  — PostToolUse: sticky-set turnHadError if tool_response.is_error
    stop      — Stop: aggregate to exitCode, read transcript summary, emit
                `finished`, remove session entry
"""

import json
import os
import re
import time
import fcntl
import socket
import pathlib


SESSION_TTL_SEC = 3600
SUMMARY_MAXLEN = 200
# Session ids from claude/codex are UUID-shaped. Restrict the resume command
# to this charset so a malformed payload can't inject shell metacharacters
# into the persisted `initial_input`.
SESSION_ID_RE = re.compile(r"\A[A-Za-z0-9_-]+\Z")

CODEX_HOME = pathlib.Path("~/.codex").expanduser()


def parse_payload() -> dict:
    """Parse _MUX0_PAYLOAD env var as JSON. Returns {} on any error."""
    raw = os.environ.get("_MUX0_PAYLOAD", "")
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def short_path(p: str) -> str:
    """Keep the last 3 path segments. `/a/b/c/d/e.swift` → `c/d/e.swift`."""
    parts = [s for s in p.split("/") if s]
    if len(parts) <= 3:
        return "/".join(parts)
    return "/".join(parts[-3:])


def describe_tool(tool: str, inp) -> str:
    """Human-readable label for a Claude Code tool + input dict."""
    if not isinstance(inp, dict):
        return tool or ""
    if tool in ("Edit", "Write", "Read"):
        p = short_path(inp.get("file_path", ""))
        return f"{tool} {p}" if p else tool
    if tool == "Bash":
        cmd = (inp.get("command") or "").split("\n")[0][:60]
        return f"Bash: {cmd}" if cmd else "Bash"
    if tool == "Grep":
        pat = inp.get("pattern", "")
        return f"Grep {pat!r}"
    if tool == "Glob":
        return f"Glob {inp.get('pattern', '')}"
    if tool == "Task":
        return f"Subagent: {inp.get('subagent_type', 'general-purpose')}"
    return tool or ""


def read_transcript_summary(path: str) -> str:
    """Read Claude's transcript JSONL, return last assistant text stripped of
    <thinking>...</thinking> blocks, truncated to SUMMARY_MAXLEN. Empty string
    on any error (missing file, malformed, no assistant message)."""
    if not path:
        return ""
    try:
        with open(path) as f:
            lines = f.readlines()
    except (FileNotFoundError, IsADirectoryError, PermissionError, OSError):
        return ""
    for line in reversed(lines):
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content", "")
        if isinstance(content, list):
            text = ""
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text", "")
                    break
            content = text
        if not isinstance(content, str):
            continue
        content = re.sub(r"<thinking>.*?</thinking>", "", content, flags=re.S)
        content = " ".join(content.split())
        if content:
            return content[:SUMMARY_MAXLEN]
    return ""


def _extract_user_text_from_claude(d: dict) -> str:
    """Plain-text content from a Claude transcript user row. Skips slash
    commands and meta injections, handles both string and typed-content-block
    (`[{type:"text",text:"..."}, ...]`) shapes."""
    if d.get("type") != "user" or d.get("isMeta"):
        return ""
    msg = d.get("message", {})
    content = msg.get("content", "") if isinstance(msg, dict) else ""
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                content = block.get("text", "")
                break
    if not isinstance(content, str):
        return ""
    text = content.strip()
    if not text or text.startswith("<command-") or text.startswith("<local-command-"):
        return ""
    return " ".join(text.split())


def read_claude_title(path: str) -> str:
    """Read Claude's session title from the transcript JSONL with three-tier
    priority (matches `claude --resume` picker semantics):

      1. `{"type":"custom-title","customTitle":"..."}` — written by `/rename`,
         explicit user intent.
      2. `{"type":"ai-title","aiTitle":"..."}` — LLM-generated, async. Claude
         only emits these once the session has enough content; short
         exchanges never trigger one.
      3. First non-meta, non-slash-command user message — universal fallback
         so short sessions also get a meaningful label.

    Single forward pass keeps the latest of each kind. Truncated to
    SUMMARY_MAXLEN. Empty string on IO error.
    """
    if not path:
        return ""
    try:
        with open(path) as f:
            lines = f.readlines()
    except (FileNotFoundError, IsADirectoryError, PermissionError, OSError):
        return ""
    custom = ""
    ai = ""
    first_prompt = ""
    for line in lines:
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict):
            continue
        t = d.get("type")
        if t == "custom-title":
            val = d.get("customTitle") or ""
            if isinstance(val, str) and val:
                custom = val
        elif t == "ai-title":
            val = d.get("aiTitle") or ""
            if isinstance(val, str) and val:
                ai = val
        elif not first_prompt:
            text = _extract_user_text_from_claude(d)
            if text:
                first_prompt = text
    chosen = custom or ai or first_prompt
    return chosen[:SUMMARY_MAXLEN]


def _find_codex_rollout(session_id: str) -> str:
    """Locate the rollout JSONL for `session_id` under `CODEX_HOME / sessions`.

    Codex names rollouts `rollout-<timestamp>-<session_id>.jsonl` under a
    nested `<year>/<month>/<day>/` tree. We glob the session_id suffix and
    take the most recent match. Empty string on malformed id / no match.
    """
    if not session_id or not SESSION_ID_RE.match(session_id):
        return ""
    sessions_dir = CODEX_HOME / "sessions"
    matches = sorted(sessions_dir.glob(f"**/rollout-*-{session_id}.jsonl"))
    if not matches:
        return ""
    return str(matches[-1])


def read_codex_title(session_id: str) -> str:
    """Read Codex's session title from the rollout JSONL with two-tier
    priority:

      1. `event_msg.thread_name_updated` `thread_name` — Codex LLM-generated
         session title (same value Codex's own `resume` picker shows).
      2. First `event_msg.user_message` — fallback when the LLM title hasn't
         been written yet.

    Both signals live in the same rollout file; reading it once gets both.
    Truncated to SUMMARY_MAXLEN. Empty on IO/missing-rollout.
    """
    path = _find_codex_rollout(session_id)
    if not path:
        return ""
    try:
        with open(path) as f:
            lines = f.readlines()
    except (FileNotFoundError, IsADirectoryError, PermissionError, OSError):
        return ""
    thread_name = ""
    first_prompt = ""
    for line in lines:
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict) or d.get("type") != "event_msg":
            continue
        payload = d.get("payload", {})
        if not isinstance(payload, dict):
            continue
        ptype = payload.get("type")
        if ptype == "thread_name_updated":
            name = payload.get("thread_name") or ""
            if isinstance(name, str) and name:
                thread_name = name
        elif ptype == "user_message" and not first_prompt:
            msg = payload.get("message") or ""
            if isinstance(msg, str):
                text = " ".join(msg.split())
                if text:
                    first_prompt = text
    chosen = thread_name or first_prompt
    return chosen[:SUMMARY_MAXLEN]


def _session_title_for(agent: str, transcript_path: str, session_id: str) -> str:
    """Read the first-user-prompt session title for `agent`. Returns "" when
    the source file isn't readable yet.

    OpenCode flows through its own JS plugin (mux0-status.js) which fills in
    sessionTitle on the wire; this branch is unreachable for opencode in
    practice but kept for parity.
    """
    if agent == "claude":
        return read_claude_title(transcript_path or "")
    if agent == "codex":
        return read_codex_title(session_id)
    return ""


def load_sessions(session_file: pathlib.Path) -> dict:
    """Return the parsed sessions doc, or a fresh empty one on any failure."""
    if not session_file.exists():
        return {"version": 1, "sessions": {}}
    try:
        with open(session_file) as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            try:
                return json.load(f)
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
    except (json.JSONDecodeError, OSError):
        return {"version": 1, "sessions": {}}


def write_sessions(session_file: pathlib.Path, data: dict) -> None:
    """Write the sessions doc atomically-ish: lock then replace contents."""
    session_file.parent.mkdir(parents=True, exist_ok=True)
    with open(session_file, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            json.dump(data, f)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def gc_stale(sessions_doc: dict, now: float) -> dict:
    """Drop session entries whose lastTouched is older than SESSION_TTL_SEC."""
    cutoff = now - SESSION_TTL_SEC
    kept = {
        sid: s for sid, s in sessions_doc.get("sessions", {}).items()
        if s.get("lastTouched", 0) > cutoff
    }
    return {"version": 1, "sessions": kept}


def emit_to_socket(sock_path: str, msg: dict) -> None:
    """Best-effort write to the Unix socket. Silent on any failure."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(sock_path)
        s.sendall((json.dumps(msg) + "\n").encode())
        s.close()
    except OSError:
        pass


def _default_entry(agent: str, terminal_id: str) -> dict:
    return {
        "agent": agent,
        "terminalId": terminal_id,
        "turnStartedAt": 0,
        "turnHadError": False,
        "currentToolName": None,
        "currentToolDetail": None,
        "transcriptPath": None,
        "lastTouched": 0,
    }


def resume_command_for(agent: str, session_id: str) -> str:
    """Build the user-facing CLI command that resumes the given session.
    Empty string if the session id is missing/malformed, or if we don't
    have a stable resume invocation for the agent.

    Note: opencode does not actually flow through this Python hook (it has
    its own JS plugin that emits resumeCommand directly), but we keep its
    branch here so this function stays the single source of truth for the
    CLI shape of every supported agent.
    """
    if not session_id or not SESSION_ID_RE.match(session_id):
        return ""
    if agent == "claude":
        return f"claude --resume {session_id}"
    if agent == "codex":
        return f"codex resume {session_id}"
    if agent == "opencode":
        return f"opencode --session {session_id}"
    return ""


def dispatch(subcmd: str, agent: str, payload: dict,
             terminal_id: str, session_file: pathlib.Path, now: float) -> dict:
    """Apply subcommand to session file; return dict describing socket emit.
    Return dict keys: event, at, plus optional exitCode, toolDetail, summary.
    Return empty dict if this subcommand emits nothing."""
    sessions_doc = load_sessions(session_file)
    entries = sessions_doc.setdefault("sessions", {})

    session_id = (payload.get("session_id")
                  or payload.get("sessionId")
                  or terminal_id)

    entry = entries.setdefault(session_id, _default_entry(agent, terminal_id))
    entry["agent"] = agent
    entry["terminalId"] = terminal_id
    entry["lastTouched"] = now

    emit: dict = {}

    if subcmd == "prompt":
        entry["turnStartedAt"] = now
        entry["turnHadError"] = False
        entry["currentToolName"] = None
        entry["currentToolDetail"] = None
        tp = payload.get("transcript_path")
        if tp:
            entry["transcriptPath"] = tp
        emit = {"event": "running", "at": now}
        # Attach the resume command on every prompt so mux0 always tracks the
        # most-recent session_id (a /clear or /resume mid-conversation rotates
        # to a new id, and we want the latest one preserved for next launch).
        resume = resume_command_for(agent, str(session_id))
        if resume:
            emit["resumeCommand"] = resume
        title = _session_title_for(agent, entry.get("transcriptPath"), str(session_id))
        if title:
            emit["sessionTitle"] = title

    elif subcmd == "pretool":
        tool = payload.get("tool_name", "") or ""
        tool_input = payload.get("tool_input", {})
        detail = describe_tool(tool, tool_input) if tool else None
        entry["currentToolName"] = tool or None
        entry["currentToolDetail"] = detail
        emit = {"event": "running", "at": now}
        if detail:
            emit["toolDetail"] = detail

    elif subcmd == "posttool":
        resp = payload.get("tool_response", {})
        if isinstance(resp, dict) and resp.get("is_error"):
            entry["turnHadError"] = True
        # Emit running so needsInput (set by Notification mid-turn) returns
        # to the live-turn state after the user resolves a permission prompt.
        # Stop fires later with a newer timestamp and overwrites to finished.
        emit = {"event": "running", "at": now}

    elif subcmd == "stop":
        exit_code = 1 if entry.get("turnHadError") else 0
        summary = read_transcript_summary(entry.get("transcriptPath") or "")
        emit = {"event": "finished", "at": now, "exitCode": exit_code}
        if summary:
            emit["summary"] = summary
        title = _session_title_for(agent, entry.get("transcriptPath"), str(session_id))
        if title:
            emit["sessionTitle"] = title
        entries.pop(session_id, None)

    sessions_doc = gc_stale(sessions_doc, now)
    write_sessions(session_file, sessions_doc)
    return emit


def main():
    subcmd = os.environ.get("_MUX0_SUBCMD", "stop")
    agent = os.environ.get("_MUX0_AGENT", "claude")
    session_file = pathlib.Path(os.environ["_MUX0_SESSION_FILE"])
    terminal_id = os.environ["MUX0_TERMINAL_ID"]
    sock_path = os.environ["MUX0_HOOK_SOCK"]
    payload = parse_payload()
    now = time.time()

    emit = dispatch(subcmd, agent, payload, terminal_id, session_file, now)
    if emit:
        emit["terminalId"] = terminal_id
        emit["agent"] = agent
        emit_to_socket(sock_path, emit)


if __name__ == "__main__":
    main()
