#!/usr/bin/env python3
"""agent-hook.py — agent lifecycle dispatch for Claude Code / Codex / Grok hooks.

Invoked by agent-hook.sh. Reads environment variables set by the bash entry
(_MUX0_SUBCMD, _MUX0_AGENT, _MUX0_PAYLOAD, _MUX0_SESSION_FILE, plus
MUX0_TERMINAL_ID and MUX0_HOOK_SOCK). Dispatches on subcommand, updates the
session JSON file, and optionally emits a socket message.

Subcommands:
    prompt           — UserPromptSubmit: reset turn state, emit `running`
    pretool          — PreToolUse: record current tool, emit `running` + toolDetail
    posttool         — PostToolUse: sticky-set turnHadError if tool_response.is_error
    posttoolfailure  — PostToolUseFailure (grok): sticky-set turnHadError, emit `running`
    permissiondenied — PermissionDenied (grok): sticky-set turnHadError, emit `running`
    notification     — Notification: permission_prompt → `needsInput`; idle_prompt /
                       task_complete → turn-end backstop (emit `finished` only when a
                       turn is still open, i.e. Stop/StopFailure/StopCancelled did not
                       already settle it)
    stop             — Stop: aggregate to exitCode, read transcript summary, emit
                       `finished`, remove session entry
    stopfailure      — StopFailure (grok): emit `finished` with exitCode 1
    stopcancelled    — StopCancelled (grok): emit `finished` with exitCode 1
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

# Honor the active CODEX_HOME (the mux0 codex wrapper exports an overlay path;
# users may also set a custom one). The overlay symlinks `sessions/` back to
# the user's real ~/.codex/sessions, so globbing through it still finds the
# rollout. Falling back to ~/.codex covers native (non-wrapped) invocations.
CODEX_HOME = pathlib.Path(os.environ.get("CODEX_HOME") or "~/.codex").expanduser()

# Same reasoning for GROK_HOME: grok-wrapper.sh exports a mux0 overlay whose
# `sessions/` entry symlinks back to the user's real ~/.grok/sessions, so
# globbing through the overlay still finds the session record (and the
# `summary.json` we read the generated title from).
GROK_HOME = pathlib.Path(os.environ.get("GROK_HOME") or "~/.grok").expanduser()

# Grok's session titles are LLM-generated and land in `summary.json`. These two
# keys are the ones grok's own `--resume` picker shows (`generated_title` is the
# newest field, `session_summary` the legacy alias for the same string).
GROK_TITLE_KEYS = ("generated_title", "session_summary", "title")

# Grok wraps injected context (user_info / rules / system-reminder) in the same
# `user` role as real prompts, and the actual typed text inside `<user_query>`.
# Prefixes here mark "not a typed prompt" so a tab is never named after boilerplate.
GROK_SYNthetic_PREFIXES = ("<user_info>", "<rules>", "<system-reminder>",
                           "<user_query>", "<system_reminder>")


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
    # --- Grok CLI tool names (grok uses snake_case native names) ---
    if tool == "run_terminal_command":
        cmd = (inp.get("command") or "").split("\n")[0][:60]
        return f"Bash: {cmd}" if cmd else "Bash"
    if tool in ("read_file", "search_replace", "write_file", "create_file"):
        p = short_path(inp.get("path") or inp.get("file_path") or inp.get("target_file") or "")
        label = {"read_file": "Read", "search_replace": "Edit",
                 "write_file": "Write", "create_file": "Write"}[tool]
        return f"{label} {p}" if p else label
    if tool == "list_dir":
        p = short_path(inp.get("target_directory") or inp.get("path") or "")
        return f"List {p}" if p else "List"
    if tool == "grep":
        return f"Grep {inp.get('pattern', '')!r}"
    if tool in ("glob", "find_files"):
        return f"Glob {inp.get('pattern', '')}"
    if tool in ("web_search", "web_search_linear"):
        q = inp.get("query", "")
        return f"Web search {q!r}" if q else "Web search"
    if tool == "spawn_subagent":
        return f"Subagent: {inp.get('agent_type') or inp.get('description') or 'general'}"
    if tool == "update_plan":
        return "Update plan"
    # --- pi tool names (pi's built-ins are lowercase single words) ---
    # pi's real toolDetail is produced by the JS extension (mux0-status.js);
    # this branch keeps agent-hook.py the single source of truth for the label
    # shape in case pi ever routes a hook through the Python path.
    if tool == "bash":
        cmd = (inp.get("command") or "").split("\n")[0][:60]
        return f"Bash: {cmd}" if cmd else "Bash"
    if tool in ("read", "write", "edit"):
        p = short_path(inp.get("path") or inp.get("file_path") or "")
        return f"{tool.capitalize()} {p}" if p else tool.capitalize()
    if tool == "ls":
        p = short_path(inp.get("path") or "")
        return f"List {p}" if p else "List"
    return tool or ""


def _flatten_message_content(content) -> str:
    """Plain text from a string-or-typed-block message content value."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if isinstance(text, str):
                    return text
    return ""


def strip_thinking_and_clip(text: str) -> str:
    """Drop `<thinking>` blocks, collapse whitespace, clip to SUMMARY_MAXLEN."""
    text = re.sub(r"<thinking>.*?</thinking>", "", text, flags=re.S)
    text = " ".join(text.split())
    return text[:SUMMARY_MAXLEN]


def _grok_user_query(text: str) -> str:
    """Pull the typed prompt out of a grok `user` message.

    Grok injects `<user_info>` / `<rules>` / `<system-reminder>` blocks under the
    same `user` role as real prompts and wraps the typed text in `<user_query>`.
    Returns "" for injected-only messages so a tab is never named after boilerplate.
    """
    m = re.search(r"<user_query>(.*?)</user_query>", text, flags=re.S)
    if m:
        return m.group(1).strip()
    stripped = text.strip()
    if any(stripped.startswith(p) for p in GROK_SYNthetic_PREFIXES):
        return ""
    return stripped


def _find_grok_session_dir(session_id: str) -> pathlib.Path:
    """Locate `GROK_HOME/sessions/**/<session_id>` (grok nests it under a URL-quoted
    cwd). Empty-path sentinel on malformed id / no match."""
    if not session_id or not SESSION_ID_RE.match(session_id):
        return pathlib.Path()
    matches = sorted((GROK_HOME / "sessions").glob(f"*/{session_id}"))
    return matches[-1] if matches else pathlib.Path()


def read_grok_title(session_id: str) -> str:
    """Grok session title, two-tier priority (matches `grok --resume`'s picker):

      1. `summary.json` `generated_title` / `session_summary` — LLM-generated,
         written asynchronously, so a fresh session may not have one yet.
      2. First `<user_query>` (or first non-boilerplate `user`) text in
         `chat_history.jsonl` — fallback so short sessions still get a label.

    Empty string when neither is readable. Truncated to SUMMARY_MAXLEN.
    """
    session_dir = _find_grok_session_dir(session_id)
    if not session_dir.is_dir():
        return ""
    try:
        summary = json.loads((session_dir / "summary.json").read_text())
    except (OSError, json.JSONDecodeError):
        summary = {}
    if isinstance(summary, dict):
        for key in GROK_TITLE_KEYS:
            val = summary.get(key)
            if isinstance(val, str) and val.strip():
                return " ".join(val.split())[:SUMMARY_MAXLEN]
    try:
        lines = (session_dir / "chat_history.jsonl").read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    for line in lines:
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict) or d.get("type") != "user":
            continue
        text = _grok_user_query(_flatten_message_content(d.get("content")))
        text = " ".join(text.split())
        if text:
            return text[:SUMMARY_MAXLEN]
    return ""


def read_grok_summary(session_id: str) -> str:
    """Last assistant text from grok's `chat_history.jsonl`.

    Used when a turn-end event arrives without `lastAssistantMessage` (e.g. the
    `idle_prompt` backstop). Grok's `transcript_path` points at `updates.jsonl`,
    an ACP `session/update` log whose rows have no `role` field, so the Claude
    transcript reader cannot use it — chat_history.jsonl is grok's own
    `{"type": "assistant", "content": "<text>"}` record. Empty on any error.
    """
    session_dir = _find_grok_session_dir(session_id)
    if not session_dir.is_dir():
        return ""
    try:
        lines = (session_dir / "chat_history.jsonl").read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict) or d.get("type") != "assistant":
            continue
        text = strip_thinking_and_clip(_flatten_message_content(d.get("content")))
        if text:
            return text
    return ""


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
        content = strip_thinking_and_clip(content)
        if content:
            return content
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


def read_payload_summary(payload: dict) -> str:
    """Turn-end summary carried directly by the hook payload.

    Grok's `Stop` / `StopFailure` / `StopCancelled` envelopes include
    `lastAssistantMessage` (the agent's final text this turn, clipped by grok to
    32k) precisely so hooks need not parse the transcript. Claude / Codex do not
    send it and keep using `transcript_path`. Empty string when absent.
    """
    text = payload.get("lastAssistantMessage") or payload.get("last_assistant_message") or ""
    if not isinstance(text, str):
        return ""
    return strip_thinking_and_clip(text)


def tool_response_had_error(resp, _depth: int = 0) -> bool:
    """Did a tool result report a failure?

    Claude / Codex put a boolean `is_error` on `tool_response`. Grok instead
    returns its own tagged output on `PostToolUse` — and, importantly, **fires
    `PostToolUse` (not `PostToolUseFailure`) for a command that exited non-zero**
    with no `is_error` field at all; the failure is only visible in the payload's
    structured fields (verified against grok 1.0.41):

        {"type": "Bash", "exit_code": 1, "output_for_prompt": "exit: 1\\nls: ...",
         "command": "...", "signal": null, "timed_out": false}

    So: accept `is_error` / `isError` / `isFailure` booleans, a non-empty string
    `error`, a non-zero `exit_code`, `timed_out: true`, or a non-null `signal`
    (killed by signal), at the top level or one level down (its `Content` /
    `content` wrapper). Unknown shapes read as "no error" (fail-open).
    """
    if not isinstance(resp, dict):
        return False
    for key in ("is_error", "isError", "isFailure", "is_failure"):
        if resp.get(key) is True:
            return True
    for key in ("error", "error_message", "errorMessage"):
        val = resp.get(key)
        if isinstance(val, str) and val.strip():
            return True
        if val is True:
            return True
    exit_code = resp.get("exit_code")
    if isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code != 0:
        return True
    if resp.get("timed_out") is True:
        return True
    if resp.get("signal") not in (None, False, ""):
        return True
    if _depth >= 1:
        return False
    for key in ("Content", "content", "toolResponse"):
        inner = resp.get(key)
        if isinstance(inner, dict) and tool_response_had_error(inner, _depth + 1):
            return True
    return False


def _notification_type(payload: dict) -> str:
    """Grok's Notification subtype. The docs steer integrations at
    `notificationType` (the human `message` is display text and can change)."""
    for key in ("notificationType", "notification_type", "type"):
        val = payload.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip().lower()
    return ""


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
    if agent == "grok":
        return read_grok_title(session_id)
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
    if agent == "pi":
        return f"pi --session {session_id}"
    if agent == "grok":
        return f"grok --resume {session_id}"
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

    # "Turn open" = we saw UserPromptSubmit for this session and have not yet
    # settled it with a turn-end event. Grok's `idle_prompt` Notification is a
    # backstop for the turns that report no Stop/StopFailure/StopCancelled at
    # all; it must NOT re-emit `finished` for a turn that already reported one
    # (grok fires idle_prompt after *every* turn end, including the ones that
    # reported, and a late duplicate would clobber a newer state).
    prior = entries.get(session_id) or {}
    turn_open = bool(prior.get("turnStartedAt"))

    entry = entries.setdefault(session_id, _default_entry(agent, terminal_id))
    entry["agent"] = agent
    entry["terminalId"] = terminal_id
    entry["lastTouched"] = now

    emit: dict = {}

    def _finish(summary_source="transcript", force_exit_code=None):
        """Emit `finished`, attaching summary + sessionTitle when available."""
        exit_code = (force_exit_code if force_exit_code is not None
                     else (1 if entry.get("turnHadError") else 0))
        summary = ""
        if summary_source == "payload":
            summary = read_payload_summary(payload)
        if not summary and agent == "grok":
            summary = read_grok_summary(str(session_id))
        if not summary and agent != "grok":
            # grok's transcript_path is an ACP update log (no `role` field) —
            # only claude/codex transcripts are readable by this helper.
            summary = read_transcript_summary(entry.get("transcriptPath") or "")
        emit.update({"event": "finished", "at": now, "exitCode": exit_code})
        if summary:
            emit["summary"] = summary
        title = _session_title_for(agent, entry.get("transcriptPath"), str(session_id))
        if title:
            emit["sessionTitle"] = title
        entries.pop(session_id, None)

    if subcmd == "prompt":
        entry["turnStartedAt"] = now
        entry["turnHadError"] = False
        entry["currentToolName"] = None
        entry["currentToolDetail"] = None
        tp = payload.get("transcript_path") or payload.get("transcriptPath")
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
        # grok only starts sending `transcript_path` from PreToolUse onwards —
        # UserPromptSubmit carries none — so latch it here too when present.
        pre_tp = payload.get("transcript_path") or payload.get("transcriptPath")
        if pre_tp and not entry.get("transcriptPath"):
            entry["transcriptPath"] = pre_tp
        emit = {"event": "running", "at": now}
        if detail:
            emit["toolDetail"] = detail

    elif subcmd == "posttool":
        if tool_response_had_error(payload.get("tool_response",
                                               payload.get("toolResult", {}))):
            entry["turnHadError"] = True
        # Emit running so needsInput (set by Notification mid-turn) returns
        # to the live-turn state after the user resolves a permission prompt.
        # Stop fires later with a newer timestamp and overwrites to finished.
        emit = {"event": "running", "at": now}

    elif subcmd in ("posttoolfailure", "permissiondenied"):
        # Grok-only: PostToolUseFailure = dispatch/MCP failure, PermissionDenied
        # = the permission system denied the call. Both mean a tool did not run
        # successfully, so they sticky-set the turn error flag. The turn itself
        # continues (the model gets to react), hence `running`, not `finished`.
        entry["turnHadError"] = True
        emit = {"event": "running", "at": now}

    elif subcmd == "notification":
        kind = _notification_type(payload)
        if kind == "permission_prompt":
            emit = {"event": "needsInput", "at": now}
        elif kind in ("idle_prompt", "task_complete") and turn_open:
            # Turn-end backstop. Same aggregation as Stop, but never claims
            # failure on its own — a turn grok reported nothing about is
            # "unknown", and unknown reads as clean.
            _finish(summary_source="payload")
        elif kind == "idle_prompt" or kind == "task_complete":
            # Already settled by Stop/StopFailure/StopCancelled — stay silent.
            entries.pop(session_id, None)
        else:
            # Unknown notification kind: no opinion.
            emit = {}

    elif subcmd == "stop":
        # Grok fires an extra observe-only Stop at session teardown with
        # `reason: "shutdown"` / `"channel_closed"`. The turn already reported,
        # so emitting another `finished` would double-count; just drop the entry
        # and let the SessionEnd hook's `idle` stand. Claude/Codex never send
        # `reason`, so the guard is a no-op for them.
        reason = payload.get("reason")
        if isinstance(reason, str) and reason and reason != "end_turn":
            entries.pop(session_id, None)
        else:
            # Grok ships the final text in `lastAssistantMessage`; claude/codex
            # have no such field, so _finish falls through to transcript_path.
            _finish(summary_source="payload")

    elif subcmd == "stopfailure":
        # Turn ended on an API error → always a failed turn.
        _finish(summary_source="payload", force_exit_code=1)

    elif subcmd == "stopcancelled":
        # Turn ended without completing (interrupt / declined permission /
        # --max-turns / no-progress). Not a clean finish → exitCode 1.
        _finish(summary_source="payload", force_exit_code=1)

    elif subcmd == "sessionend":
        emit = {"event": "idle", "at": now}
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
