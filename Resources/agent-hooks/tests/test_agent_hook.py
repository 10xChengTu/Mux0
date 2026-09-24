"""Unit tests for agent-hook.py. Run with:
    python3 -m pytest Resources/agent-hooks/tests/ -v
"""

import json
import os
import pathlib
import sys
import time
import tempfile

import pytest

# Make the sibling script importable.
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

# agent-hook.py uses a dash which isn't a valid Python identifier — load via
# importlib so we can treat it as a module.
import importlib.util
SPEC = importlib.util.spec_from_file_location(
    "agent_hook", str(HERE.parent / "agent-hook.py"))
agent_hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent_hook)


# ---------- describe_tool ----------

def test_describe_tool_edit():
    assert agent_hook.describe_tool("Edit", {"file_path": "/a/b/c/foo.swift"}) == "Edit b/c/foo.swift"

def test_describe_tool_read():
    assert agent_hook.describe_tool("Read", {"file_path": "/foo.swift"}) == "Read foo.swift"

def test_describe_tool_write_no_path():
    assert agent_hook.describe_tool("Write", {"file_path": ""}) == "Write"

def test_describe_tool_bash_truncates():
    cmd = "x" * 200
    out = agent_hook.describe_tool("Bash", {"command": cmd})
    assert out.startswith("Bash: ")
    assert len(out) == len("Bash: ") + 60

def test_describe_tool_bash_first_line_only():
    assert agent_hook.describe_tool("Bash", {"command": "ls\necho hi"}) == "Bash: ls"

def test_describe_tool_grep():
    assert agent_hook.describe_tool("Grep", {"pattern": "foo"}) == "Grep 'foo'"

def test_describe_tool_glob():
    assert agent_hook.describe_tool("Glob", {"pattern": "**/*.swift"}) == "Glob **/*.swift"

def test_describe_tool_task():
    assert agent_hook.describe_tool("Task", {"subagent_type": "Plan"}) == "Subagent: Plan"

def test_describe_tool_unknown():
    assert agent_hook.describe_tool("MysteryTool", {"foo": "bar"}) == "MysteryTool"

def test_describe_tool_non_dict_input():
    assert agent_hook.describe_tool("Edit", "not a dict") == "Edit"


# ---------- short_path ----------

def test_short_path_three_segments_or_fewer_unchanged():
    assert agent_hook.short_path("a/b/c") == "a/b/c"
    assert agent_hook.short_path("a/b") == "a/b"

def test_short_path_strips_leading_slash():
    assert agent_hook.short_path("/a/b/c/d") == "b/c/d"


# ---------- read_transcript_summary ----------

def _write_transcript(path, messages):
    with open(path, "w") as f:
        for m in messages:
            f.write(json.dumps(m) + "\n")


def test_read_transcript_summary_picks_last_assistant(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "Old response"},
        {"role": "user", "content": "another question"},
        {"role": "assistant", "content": "Latest response"},
    ])
    assert agent_hook.read_transcript_summary(str(p)) == "Latest response"


def test_read_transcript_summary_strips_thinking(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [
        {"role": "assistant", "content": "<thinking>internal</thinking>Actual answer here"},
    ])
    assert agent_hook.read_transcript_summary(str(p)) == "Actual answer here"


def test_read_transcript_summary_multi_block_content(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [
        {"role": "assistant",
         "content": [
             {"type": "text", "text": "Hello"},
             {"type": "tool_use", "name": "Edit"},
         ]},
    ])
    assert agent_hook.read_transcript_summary(str(p)) == "Hello"


def test_read_transcript_summary_truncates_to_200():
    # Write inline rather than tmp_path to verify the constant itself
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        txt = "x" * 500
        f.write(json.dumps({"role": "assistant", "content": txt}) + "\n")
        path = f.name
    try:
        result = agent_hook.read_transcript_summary(path)
        assert len(result) == 200
        assert result == "x" * 200
    finally:
        os.unlink(path)


def test_read_transcript_summary_empty_file(tmp_path):
    p = tmp_path / "empty.jsonl"
    p.write_text("")
    assert agent_hook.read_transcript_summary(str(p)) == ""


def test_read_transcript_summary_missing_file():
    assert agent_hook.read_transcript_summary("/nonexistent/path.jsonl") == ""


def test_read_transcript_summary_malformed_lines_skipped(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text('not json\n{"role":"assistant","content":"good"}\n')
    assert agent_hook.read_transcript_summary(str(p)) == "good"


def test_read_transcript_summary_no_assistant(tmp_path):
    p = tmp_path / "t.jsonl"
    _write_transcript(p, [{"role": "user", "content": "only user"}])
    assert agent_hook.read_transcript_summary(str(p)) == ""


# ---------- gc_stale ----------

def test_gc_stale_drops_old_keeps_fresh():
    now = 10_000.0
    doc = {
        "version": 1,
        "sessions": {
            "s_old":   {"lastTouched": now - 7200},   # 2h ago: drop
            "s_fresh": {"lastTouched": now - 600},    # 10m ago: keep
            "s_no_ts": {},                            # missing: drop
        },
    }
    out = agent_hook.gc_stale(doc, now)
    assert "s_fresh" in out["sessions"]
    assert "s_old" not in out["sessions"]
    assert "s_no_ts" not in out["sessions"]


# ---------- dispatch end-to-end ----------

def test_dispatch_prompt_then_stop_clean_turn(tmp_path, monkeypatch):
    sf = tmp_path / "sessions.json"
    transcript = tmp_path / "transcript.jsonl"
    _write_transcript(transcript, [
        {"role": "assistant", "content": "Done."},
    ])

    now = 1_000_000.0

    prompt_payload = {"session_id": "s1", "transcript_path": str(transcript)}
    emit1 = agent_hook.dispatch("prompt", "claude", prompt_payload, "term1", sf, now)
    assert emit1 == {
        "event": "running",
        "at": now,
        "resumeCommand": "claude --resume s1",
    }

    stop_payload = {"session_id": "s1"}
    emit2 = agent_hook.dispatch("stop", "claude", stop_payload, "term1", sf, now + 10)
    assert emit2["event"] == "finished"
    assert emit2["exitCode"] == 0
    assert emit2["summary"] == "Done."

    # session entry removed by stop
    doc = agent_hook.load_sessions(sf)
    assert "s1" not in doc.get("sessions", {})


def test_dispatch_posttool_sets_sticky_error(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 2_000_000.0

    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s2"}, "term2", sf, now)
    agent_hook.dispatch("pretool", "claude",
                        {"session_id": "s2", "tool_name": "Edit",
                         "tool_input": {"file_path": "/foo.swift"}},
                        "term2", sf, now + 1)
    agent_hook.dispatch("posttool", "claude",
                        {"session_id": "s2", "tool_response": {"is_error": True}},
                        "term2", sf, now + 2)
    # Even after a subsequent clean posttool, flag should stay sticky
    agent_hook.dispatch("posttool", "claude",
                        {"session_id": "s2", "tool_response": {"is_error": False}},
                        "term2", sf, now + 3)
    emit = agent_hook.dispatch("stop", "claude",
                               {"session_id": "s2"}, "term2", sf, now + 4)
    assert emit["exitCode"] == 1


def test_dispatch_pretool_emits_tool_detail(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 3_000_000.0
    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s3"}, "term3", sf, now)
    emit = agent_hook.dispatch("pretool", "claude",
                               {"session_id": "s3", "tool_name": "Edit",
                                "tool_input": {"file_path": "/y/z/foo.swift"}},
                               "term3", sf, now + 1)
    assert emit["event"] == "running"
    assert emit["toolDetail"] == "Edit y/z/foo.swift"


def test_dispatch_stop_without_prompt_defaults_to_zero_exit(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 4_000_000.0
    # Stop arrives without a prior prompt — entry is created lazily
    emit = agent_hook.dispatch("stop", "claude",
                               {"session_id": "s4"}, "term4", sf, now)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 0   # default turnHadError=False


def test_dispatch_uses_terminal_id_when_no_session_id(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 5_000_000.0
    # payload without session_id — fallback to terminal_id as session key
    agent_hook.dispatch("prompt", "claude", {}, "term5", sf, now)
    doc = agent_hook.load_sessions(sf)
    assert "term5" in doc["sessions"]


def test_dispatch_posttool_emits_running(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 6_000_000.0
    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s6"}, "term6", sf, now)
    agent_hook.dispatch("pretool", "claude",
                        {"session_id": "s6", "tool_name": "Edit",
                         "tool_input": {"file_path": "/foo.swift"}},
                        "term6", sf, now + 1)
    # Clean posttool — emits running (no toolDetail / exitCode).
    emit = agent_hook.dispatch("posttool", "claude",
                                {"session_id": "s6",
                                 "tool_response": {"is_error": False}},
                                "term6", sf, now + 2)
    assert emit == {"event": "running", "at": now + 2}


def test_dispatch_posttool_running_emit_preserves_sticky_error(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 7_000_000.0
    agent_hook.dispatch("prompt", "claude",
                        {"session_id": "s7"}, "term7", sf, now)
    # Error posttool — still emits running AND sets the sticky flag.
    emit = agent_hook.dispatch("posttool", "claude",
                                {"session_id": "s7",
                                 "tool_response": {"is_error": True}},
                                "term7", sf, now + 1)
    assert emit["event"] == "running"
    # Stop reads the flag → exit code 1.
    stop_emit = agent_hook.dispatch("stop", "claude",
                                     {"session_id": "s7"}, "term7", sf, now + 2)
    assert stop_emit["exitCode"] == 1


# ---------- resume_command_for ----------

def test_resume_command_for_claude():
    assert agent_hook.resume_command_for("claude", "abc") == "claude --resume abc"


def test_resume_command_for_codex():
    assert agent_hook.resume_command_for("codex", "xyz") == "codex resume xyz"


def test_resume_command_for_opencode():
    assert agent_hook.resume_command_for("opencode", "ses_abc") == \
           "opencode --session ses_abc"


def test_resume_command_for_unknown_agent():
    # Any future agent returns empty until we know its CLI shape.
    assert agent_hook.resume_command_for("aider", "xyz") == ""


def test_resume_command_for_empty_session():
    assert agent_hook.resume_command_for("claude", "") == ""


def test_resume_command_for_rejects_shell_metacharacters():
    # Session id is persisted into `initial_input` for next-launch auto-exec.
    # Any character outside [A-Za-z0-9_-] must abort the build so the shell
    # can't be tricked into executing extra commands. Real claude/codex
    # session ids are UUID-shaped, so this never rejects a legitimate id.
    bad = ["abc; touch /tmp/pwn", "abc def", "abc`whoami`", "abc$(id)",
           "abc&", "abc|cat", "abc\nrm", "../etc/passwd", "a/b"]
    for value in bad:
        assert agent_hook.resume_command_for("claude", value) == "", value
        assert agent_hook.resume_command_for("codex", value) == "", value


def test_resume_command_for_accepts_uuid_shapes():
    # Real-world session ids: hex UUIDs (with or without dashes), short
    # alphanumeric tags, underscore-separated. All must round-trip.
    good = ["550e8400-e29b-41d4-a716-446655440000",
            "550e8400e29b41d4a716446655440000",
            "abc_DEF-123",
            "xyz"]
    for value in good:
        assert agent_hook.resume_command_for("claude", value) == \
               f"claude --resume {value}"


def test_dispatch_codex_prompt_emits_resume_command(tmp_path):
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("prompt", "codex",
                                {"session_id": "cdx-1"}, "term-c", sf, 5_000_000.0)
    assert emit["resumeCommand"] == "codex resume cdx-1"


def test_dispatch_pretool_does_not_emit_resume_command(tmp_path):
    # Only `prompt` should attach resumeCommand, to avoid spamming the socket
    # with the same value on every tool invocation.
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "claude", {"session_id": "s9"}, "t9", sf, 6_000_000.0)
    emit = agent_hook.dispatch("pretool", "claude",
                                {"session_id": "s9", "tool_name": "Bash",
                                 "tool_input": {"command": "ls"}},
                                "t9", sf, 6_000_001.0)
    assert "resumeCommand" not in emit


# ---------- read_claude_title (first user prompt) ----------

def test_read_claude_title_picks_first_user_prompt(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "user", "message": {"content": "How do I sort an array in Swift?"}}) + "\n" +
        json.dumps({"type": "assistant", "message": {"content": "..."}}) + "\n" +
        json.dumps({"type": "user", "message": {"content": "ignored later prompt"}}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "How do I sort an array in Swift?"


def test_read_claude_title_truncates_to_200(tmp_path):
    p = tmp_path / "t.jsonl"
    long = "x" * 500
    p.write_text(json.dumps({"type": "user", "message": {"content": long}}) + "\n")
    assert len(agent_hook.read_claude_title(str(p))) == 200


def test_read_claude_title_missing_file():
    assert agent_hook.read_claude_title("/nonexistent/path.jsonl") == ""


def test_read_claude_title_no_user_row(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(json.dumps({"type": "assistant", "message": {"content": "only assistant"}}) + "\n")
    assert agent_hook.read_claude_title(str(p)) == ""


def test_read_claude_title_skips_malformed_lines(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        "not json\n" +
        json.dumps({"type": "user", "message": {"content": "Good"}}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "Good"


def test_read_claude_title_skips_slash_commands(tmp_path):
    # /clear and /rename rows are recorded as user rows with <command-...> content.
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "user", "message": {"content": "<command-name>/clear</command-name>"}}) + "\n" +
        json.dumps({"type": "user", "message": {"content": "real question"}}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "real question"


def test_read_claude_title_skips_meta(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "user", "isMeta": True, "message": {"content": "meta payload"}}) + "\n" +
        json.dumps({"type": "user", "message": {"content": "first real"}}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "first real"


def test_read_claude_title_extracts_text_from_list_content(tmp_path):
    # Claude sometimes stores content as [{type: text, text: ...}, ...].
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({
            "type": "user",
            "message": {"content": [
                {"type": "text", "text": "list-form content"},
                {"type": "image"},
            ]},
        }) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "list-form content"


def test_read_claude_title_custom_title_wins(tmp_path):
    # /rename writes a custom-title row; it must beat both ai-title and the
    # first user prompt fallback.
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "user", "message": {"content": "first prompt"}}) + "\n" +
        json.dumps({"type": "ai-title", "aiTitle": "LLM derived"}) + "\n" +
        json.dumps({"type": "custom-title", "customTitle": "user named"}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "user named"


def test_read_claude_title_ai_title_beats_first_prompt(tmp_path):
    # No /rename → ai-title wins over user prompt.
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "user", "message": {"content": "first prompt"}}) + "\n" +
        json.dumps({"type": "ai-title", "aiTitle": "LLM derived"}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "LLM derived"


def test_read_claude_title_picks_latest_custom_title(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        json.dumps({"type": "custom-title", "customTitle": "first"}) + "\n" +
        json.dumps({"type": "custom-title", "customTitle": "second"}) + "\n"
    )
    assert agent_hook.read_claude_title(str(p)) == "second"


# ---------- read_codex_title (first user_message from rollout) ----------

def _write_codex_rollout(tmp_path, session_id, events):
    """Helper: build a CODEX_HOME-shaped rollout file for session_id.
    `events` is a list of dicts already shaped as `payload`."""
    sessions_dir = tmp_path / "sessions" / "2026" / "05" / "24"
    sessions_dir.mkdir(parents=True, exist_ok=True)
    f = sessions_dir / f"rollout-2026-05-24T00-00-00-{session_id}.jsonl"
    lines = [json.dumps({"type": "session_meta", "payload": {"id": session_id}})]
    for ev in events:
        lines.append(json.dumps({"type": "event_msg", "payload": ev}))
    f.write_text("\n".join(lines) + "\n")
    return f


def _user_msg(text):
    return {"type": "user_message", "message": text}


def _thread_name(name):
    return {"type": "thread_name_updated", "thread_name": name}


def test_read_codex_title_thread_name_beats_user_message(tmp_path, monkeypatch):
    _write_codex_rollout(tmp_path, "abc-123",
                          [_user_msg("first prompt"), _thread_name("Codex LLM name")])
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("abc-123") == "Codex LLM name"


def test_read_codex_title_falls_back_to_first_user_message(tmp_path, monkeypatch):
    # No thread_name_updated → use the user's own first prompt.
    _write_codex_rollout(tmp_path, "abc-123",
                          [_user_msg("first prompt"), _user_msg("second prompt")])
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("abc-123") == "first prompt"


def test_read_codex_title_no_rollout(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("missing") == ""


def test_codex_home_resolution_honors_env():
    # When CODEX_HOME is set (mux0 wrapper overlay, or a user-custom home),
    # the module-level constant must resolve to it rather than ~/.codex.
    # Mirrors the expression used at import time in agent-hook.py.
    resolved = pathlib.Path(
        ({"CODEX_HOME": "/custom/codex"}).get("CODEX_HOME") or "~/.codex"
    ).expanduser()
    assert str(resolved) == "/custom/codex"
    fallback = pathlib.Path(
        ({}).get("CODEX_HOME") or "~/.codex"
    ).expanduser()
    assert str(fallback).endswith("/.codex")


def test_read_codex_title_rejects_invalid_session_id(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("bad; DROP TABLE") == ""


def test_read_codex_title_truncates_to_200(tmp_path, monkeypatch):
    _write_codex_rollout(tmp_path, "abc-123", [_thread_name("x" * 500)])
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert len(agent_hook.read_codex_title("abc-123")) == 200


def test_read_codex_title_ignores_non_matching_event_msg(tmp_path, monkeypatch):
    sessions_dir = tmp_path / "sessions" / "2026" / "05" / "24"
    sessions_dir.mkdir(parents=True, exist_ok=True)
    f = sessions_dir / "rollout-2026-05-24T00-00-00-sid.jsonl"
    f.write_text(
        json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n" +
        json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": "real"}}) + "\n"
    )
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("sid") == "real"


def test_read_codex_title_picks_latest_thread_name(tmp_path, monkeypatch):
    # Codex may rewrite thread_name later in the session; take the latest.
    _write_codex_rollout(tmp_path, "abc-123",
                          [_thread_name("First name"), _thread_name("Second name")])
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    assert agent_hook.read_codex_title("abc-123") == "Second name"


# ---------- dispatch sessionTitle attachment ----------

def test_dispatch_claude_prompt_attaches_session_title(tmp_path):
    sf = tmp_path / "sessions.json"
    transcript = tmp_path / "t.jsonl"
    transcript.write_text(
        json.dumps({"type": "ai-title", "aiTitle": "My session"}) + "\n"
    )
    emit = agent_hook.dispatch("prompt", "claude",
                                {"session_id": "s1",
                                 "transcript_path": str(transcript)},
                                "term1", sf, 1.0)
    assert emit.get("sessionTitle") == "My session"


def test_dispatch_codex_prompt_attaches_session_title(tmp_path, monkeypatch):
    _write_codex_rollout(tmp_path, "cdx-1", [_thread_name("Codex LLM name")])
    monkeypatch.setattr(agent_hook, "CODEX_HOME", tmp_path)
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("prompt", "codex",
                                {"session_id": "cdx-1"},
                                "term-c", sf, 1.0)
    assert emit.get("sessionTitle") == "Codex LLM name"


def test_dispatch_no_session_title_when_empty(tmp_path):
    sf = tmp_path / "sessions.json"
    # No transcript_path → read_claude_title returns ""
    emit = agent_hook.dispatch("prompt", "claude",
                                {"session_id": "s1"},
                                "term1", sf, 1.0)
    assert "sessionTitle" not in emit


# ---------- pi / grok resume command shapes ----------

def test_resume_command_pi():
    assert agent_hook.resume_command_for("pi", "01a0d1d9-56a9-75eb") == \
        "pi --session 01a0d1d9-56a9-75eb"

def test_resume_command_grok():
    assert agent_hook.resume_command_for("grok", "01a0d1d8-4252-7992") == \
        "grok --resume 01a0d1d8-4252-7992"

def test_resume_command_rejects_malformed_ids_pi_grok():
    for agent in ("pi", "grok"):
        assert agent_hook.resume_command_for(agent, "") == ""
        assert agent_hook.resume_command_for(agent, "id;rm -rf /") == ""
        assert agent_hook.resume_command_for(agent, "id with space") == ""
        assert agent_hook.resume_command_for(agent, "`whoami`") == ""


# ---------- describe_tool: grok / pi native tool names ----------

def test_describe_tool_grok_run_terminal_command():
    assert agent_hook.describe_tool(
        "run_terminal_command", {"command": "cargo test\n# tail"}) == "Bash: cargo test"

def test_describe_tool_grok_read_and_edit():
    assert agent_hook.describe_tool("read_file", {"path": "/a/b/c/d.rs"}) == "Read b/c/d.rs"
    assert agent_hook.describe_tool("search_replace", {"path": "/x/y.ts"}) == "Edit x/y.ts"

def test_describe_tool_grok_list_dir_and_grep():
    assert agent_hook.describe_tool("list_dir", {"target_directory": "/tmp/proj"}) == "List tmp/proj"
    assert agent_hook.describe_tool("grep", {"pattern": "TODO"}) == "Grep 'TODO'"

def test_describe_tool_grok_subagent_and_plan():
    assert agent_hook.describe_tool("spawn_subagent", {"agent_type": "explore"}) == \
        "Subagent: explore"
    assert agent_hook.describe_tool("update_plan", {}) == "Update plan"

def test_describe_tool_pi_native_names():
    assert agent_hook.describe_tool("bash", {"command": "ls -la"}) == "Bash: ls -la"
    assert agent_hook.describe_tool("read", {"path": "/a/b/c.py"}) == "Read a/b/c.py"
    assert agent_hook.describe_tool("edit", {"path": "/a/b/c.py"}) == "Edit a/b/c.py"
    assert agent_hook.describe_tool("ls", {"path": "/tmp/x"}) == "List tmp/x"


# ---------- tool_response_had_error (claude + grok shapes) ----------

def test_tool_response_had_error_claude_is_error():
    assert agent_hook.tool_response_had_error({"is_error": True}) is True
    assert agent_hook.tool_response_had_error({"is_error": False}) is False

def test_tool_response_had_error_grok_tagged_content():
    # Healthy grok result: tagged output, no error markers anywhere.
    ok = {"type": "ListDir", "Content": {"content": "- a.txt", "absolute_root_path": "/tmp"}}
    assert agent_hook.tool_response_had_error(ok) is False

def test_tool_response_had_error_grok_bash_nonzero_exit():
    # Verified shape from grok 1.0.41: a failing `ls` fires PostToolUse (NOT
    # PostToolUseFailure) with no is_error field anywhere — the failure is only
    # visible in the structured fields of toolResult.
    bad = {
        "type": "Bash",
        "output_for_prompt": "exit: 1\nls: /nope: No such file or directory\n",
        "exit_code": 1,
        "command": "ls /nope",
        "signal": None,
        "timed_out": False,
    }
    assert agent_hook.tool_response_had_error(bad) is True

def test_tool_response_had_error_grok_bash_zero_exit_is_clean():
    ok = {
        "type": "Bash",
        "output_for_prompt": "exit: 0\nalpha.txt\n",
        "exit_code": 0,
        "command": "ls",
        "signal": None,
        "timed_out": False,
    }
    assert agent_hook.tool_response_had_error(ok) is False

def test_tool_response_had_error_grok_bash_timeout_or_signal():
    assert agent_hook.tool_response_had_error(
        {"type": "Bash", "exit_code": 0, "timed_out": True}) is True
    assert agent_hook.tool_response_had_error(
        {"type": "Bash", "exit_code": None, "signal": "SIGTERM"}) is True

def test_grok_dispatch_posttool_exit_code_marks_turn_failed(tmp_path):
    # The realistic grok failure path: PostToolUse carries exit_code 1 and the
    # turn then ends cleanly (Stop reason=end_turn) — the turn must still be
    # reported as failed, otherwise the sidebar shows a green dot for a red run.
    sf = tmp_path / "sessions.json"
    now = 5_000_000.0
    agent_hook.dispatch("userpromptsubmit", "grok",
                        {"session_id": "g1"}, "term-g", sf, now)
    # grok's hook config maps PostToolUse -> `posttool` (same subcommand as
    # claude) and carries the result under the top-level `toolResult` key.
    agent_hook.dispatch("posttool", "grok",
                        {"session_id": "g1", "tool_name": "Bash",
                         "tool_input": {"command": "ls /nope"},
                         "toolResult": {"type": "Bash", "exit_code": 1,
                                        "command": "ls /nope"}},
                        "term-g", sf, now + 1)
    emit = agent_hook.dispatch("stop", "grok",
                               {"session_id": "g1", "reason": "end_turn"},
                               "term-g", sf, now + 2)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 1

def test_grok_dispatch_posttoolfailure_marks_turn_failed(tmp_path):
    sf = tmp_path / "sessions.json"
    now = 5_100_000.0
    agent_hook.dispatch("userpromptsubmit", "grok",
                        {"session_id": "g2"}, "term-g", sf, now)
    agent_hook.dispatch("posttoolfailure", "grok",
                        {"session_id": "g2", "tool_name": "ReadFile",
                         "error": "no such file"},
                        "term-g", sf, now + 1)
    emit = agent_hook.dispatch("stop", "grok",
                               {"session_id": "g2", "reason": "end_turn"},
                               "term-g", sf, now + 2)
    assert emit["exitCode"] == 1

def test_tool_response_had_error_grok_nested_flag():
    bad = {"type": "Bash", "Content": {"is_error": True, "content": "exit 1"}}
    assert agent_hook.tool_response_had_error(bad) is True

def test_tool_response_had_error_string_error_field():
    assert agent_hook.tool_response_had_error({"error": "ENOENT"}) is True
    assert agent_hook.tool_response_had_error({"error": ""}) is False

def test_tool_response_had_error_non_dict():
    assert agent_hook.tool_response_had_error("nope") is False
    assert agent_hook.tool_response_had_error(None) is False


# ---------- read_grok_title / read_grok_summary ----------

def _make_grok_session(tmp_path, session_id, *, summary=None, history=None):
    """Lay out $GROK_HOME/sessions/<encoded-cwd>/<session_id>/ like grok does."""
    session_dir = tmp_path / "sessions" / "%2Fprivate%2Ftmp%2Fproj" / session_id
    session_dir.mkdir(parents=True)
    if summary is not None:
        (session_dir / "summary.json").write_text(json.dumps(summary))
    if history is not None:
        (session_dir / "chat_history.jsonl").write_text(
            "\n".join(json.dumps(row) for row in history) + "\n")
    return session_dir


def _grok_user(text):
    return {"type": "user", "content": [{"type": "text", "text": text}]}


def _grok_assistant(text):
    return {"type": "assistant", "content": text}


def test_read_grok_title_generated_title_wins(tmp_path, monkeypatch):
    sid = "01a0d1d8-4252-7992-a65b-4ee8d890878f"
    _make_grok_session(tmp_path, sid,
                       summary={"generated_title": "List Files Then Say Done",
                                "session_summary": "stale"},
                       history=[_grok_user("<user_query>\nls please\n</user_query>")])
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    assert agent_hook.read_grok_title(sid) == "List Files Then Say Done"


def test_read_grok_title_falls_back_to_user_query(tmp_path, monkeypatch):
    sid = "01a0d1d8-4252-7992-a65b-4ee8d890879f"
    _make_grok_session(tmp_path, sid, summary={"num_messages": 2},
                       history=[
                           _grok_user("<user_info>\nOS: macos\n</user_info>"),
                           _grok_user("<system-reminder>\nworkflows\n</system-reminder>"),
                           _grok_user("<user_query>\n\u53ea\u56de\u590d OK\n</user_query>"),
                       ])
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    assert agent_hook.read_grok_title(sid) == "只回复 OK"


def test_read_grok_title_skips_boilerplate_without_query(tmp_path, monkeypatch):
    sid = "01a0d1d8-4252-7992-a65b-4ee8d89087a0"
    _make_grok_session(tmp_path, sid, summary={},
                       history=[_grok_user("<rules>\nbe good\n</rules>"),
                                _grok_user("real typed prompt")])
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    assert agent_hook.read_grok_title(sid) == "real typed prompt"


def test_read_grok_title_missing_session(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    assert agent_hook.read_grok_title("01a0d1d8-4252-7992-a65b-4ee8d89087a1") == ""
    assert agent_hook.read_grok_title("bad id;rm") == ""


def test_read_grok_title_truncates_to_200(tmp_path, monkeypatch):
    sid = "01a0d1d8-4252-7992-a65b-4ee8d89087a2"
    _make_grok_session(tmp_path, sid, summary={"generated_title": "x" * 400})
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    assert len(agent_hook.read_grok_title(sid)) == agent_hook.SUMMARY_MAXLEN


def test_read_grok_summary_last_assistant(tmp_path, monkeypatch):
    sid = "01a0d1d8-4252-7992-a65b-4ee8d89087a3"
    _make_grok_session(tmp_path, sid, summary={},
                       history=[_grok_assistant("first"),
                                _grok_user("next prompt"),
                                _grok_assistant("final answer")])
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    assert agent_hook.read_grok_summary(sid) == "final answer"


def test_grok_home_resolution_honors_env():
    old = os.environ.get("GROK_HOME")
    os.environ["GROK_HOME"] = "/tmp/custom-grok-home"
    try:
        src = (HERE.parent / "agent-hook.py").read_text()
        # Re-evaluating the module-level constant is what the wrapper relies on.
        assert 'GROK_HOME = pathlib.Path(os.environ.get("GROK_HOME")' in src
    finally:
        if old is None:
            os.environ.pop("GROK_HOME", None)
        else:
            os.environ["GROK_HOME"] = old


# ---------- dispatch: grok envelope (camelCase + snake_case aliases) ----------

GROK_SID = "01a0d1d8-4252-7992-a65b-4ee8d890878f"


def _grok_prompt_payload():
    return {"session_id": GROK_SID, "sessionId": GROK_SID,
            "promptId": "ad9ea0c9", "hook_event_name": "UserPromptSubmit"}


def test_dispatch_grok_prompt_emits_running_with_resume(tmp_path, monkeypatch):
    sid = GROK_SID
    _make_grok_session(tmp_path, sid, summary={"generated_title": "Grokked Title"})
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(),
                               "term-g", sf, 1.0)
    assert emit["event"] == "running"
    assert emit["resumeCommand"] == f"grok --resume {sid}"
    assert emit["sessionTitle"] == "Grokked Title"


def test_dispatch_grok_prompt_session_id_from_camel_alias(tmp_path, monkeypatch):
    # A payload that only carries grok's camelCase sessionId must still key the
    # session entry (fallback chain session_id → sessionId → terminal_id).
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("prompt", "grok", {"sessionId": "only-camel-1"},
                               "term-g", sf, 1.0)
    assert emit["resumeCommand"] == "grok --resume only-camel-1"


def test_dispatch_grok_pretool_tool_detail_from_snake_alias(tmp_path):
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("pretool", "grok",
                               {"session_id": GROK_SID,
                                "tool_name": "list_dir",
                                "tool_input": {"target_directory": "/tmp/proj"}},
                               "term-g", sf, 2.0)
    assert emit == {"event": "running", "at": 2.0, "toolDetail": "List tmp/proj"}


def test_dispatch_grok_posttool_failure_sets_error(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    agent_hook.dispatch("posttool", "grok",
                        {"session_id": GROK_SID, "tool_name": "run_terminal_command",
                         "tool_response": {"type": "Bash",
                                           "Content": {"is_error": True,
                                                       "content": "boom"}}},
                        "term-g", sf, 2.0)
    emit = agent_hook.dispatch("stop", "grok",
                               {"session_id": GROK_SID, "reason": "end_turn",
                                "lastAssistantMessage": "It failed."},
                               "term-g", sf, 3.0)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 1
    assert emit["summary"] == "It failed."


def test_dispatch_grok_stop_uses_last_assistant_message(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("stop", "grok",
                               {"session_id": GROK_SID, "reason": "end_turn",
                                "lastAssistantMessage": "Files:\n- a.txt\n\nDONE"},
                               "term-g", sf, 3.0)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 0
    assert emit["summary"] == "Files: - a.txt DONE"


def test_dispatch_grok_session_end_stop_does_not_double_finish(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    first = agent_hook.dispatch("stop", "grok",
                                {"session_id": GROK_SID, "reason": "end_turn",
                                 "lastAssistantMessage": "done"},
                                "term-g", sf, 2.0)
    # grok fires a second, observe-only Stop with reason=shutdown at teardown.
    second = agent_hook.dispatch("stop", "grok",
                                 {"session_id": GROK_SID, "reason": "shutdown"},
                                 "term-g", sf, 3.0)
    assert first["event"] == "finished"
    assert second == {}


def test_dispatch_grok_stopfailure_and_stopcancelled_are_failed(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("stopfailure", "grok",
                               {"session_id": GROK_SID, "error": "rate_limit",
                                "lastAssistantMessage": "429 too many requests"},
                               "term-g", sf, 2.0)
    assert (emit["event"], emit["exitCode"], emit["summary"]) == \
        ("finished", 1, "429 too many requests")

    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 3.0)
    emit = agent_hook.dispatch("stopcancelled", "grok",
                               {"session_id": GROK_SID, "reason": "user_interrupt",
                                "cancelledBy": "user"},
                               "term-g", sf, 4.0)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 1


def test_dispatch_grok_permission_denied_marks_error(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("permissiondenied", "grok",
                               {"session_id": GROK_SID, "tool_name": "run_terminal_command"},
                               "term-g", sf, 2.0)
    assert emit == {"event": "running", "at": 2.0}
    emit = agent_hook.dispatch("stop", "grok",
                               {"session_id": GROK_SID, "reason": "end_turn"},
                               "term-g", sf, 3.0)
    assert emit["exitCode"] == 1


def test_dispatch_grok_notification_permission_prompt_needs_input(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("notification", "grok",
                               {"session_id": GROK_SID,
                                "notificationType": "permission_prompt",
                                "message": "Allow `rm`?"},
                               "term-g", sf, 2.0)
    assert emit == {"event": "needsInput", "at": 2.0}


def test_dispatch_grok_notification_idle_prompt_backstop(tmp_path):
    """idle_prompt settles a turn that never reported Stop."""
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("notification", "grok",
                               {"session_id": GROK_SID, "notificationType": "idle_prompt"},
                               "term-g", sf, 2.0)
    assert emit["event"] == "finished"
    assert emit["exitCode"] == 0


def test_dispatch_grok_idle_prompt_is_silent_after_stop(tmp_path):
    """grok fires idle_prompt after EVERY turn end — including the turns that
    already reported Stop. A duplicate `finished` would clobber the newer state,
    so the second report must be dropped."""
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    stop = agent_hook.dispatch("stop", "grok",
                               {"session_id": GROK_SID, "reason": "end_turn",
                                "lastAssistantMessage": "all good"},
                               "term-g", sf, 2.0)
    later = agent_hook.dispatch("notification", "grok",
                                {"session_id": GROK_SID, "notificationType": "idle_prompt"},
                                "term-g", sf, 3.0)
    assert stop["event"] == "finished"
    assert later == {}


def test_dispatch_grok_idle_prompt_reads_summary_from_chat_history(tmp_path, monkeypatch):
    sid = GROK_SID
    _make_grok_session(tmp_path, sid, summary={},
                       history=[agent_hook and _grok_assistant("answer from disk")])
    monkeypatch.setattr(agent_hook, "GROK_HOME", tmp_path)
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("notification", "grok",
                               {"session_id": GROK_SID, "notificationType": "idle_prompt"},
                               "term-g", sf, 2.0)
    assert emit["summary"] == "answer from disk"


def test_dispatch_grok_notification_unknown_kind_is_quiet(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("notification", "grok",
                               {"session_id": GROK_SID, "notificationType": "something_new"},
                               "term-g", sf, 2.0)
    assert emit == {}


def test_dispatch_grok_sessionend_emits_idle_and_clears(tmp_path):
    sf = tmp_path / "sessions.json"
    agent_hook.dispatch("prompt", "grok", _grok_prompt_payload(), "term-g", sf, 1.0)
    emit = agent_hook.dispatch("sessionend", "grok",
                               {"session_id": GROK_SID, "reason": "shutdown"},
                               "term-g", sf, 2.0)
    assert emit == {"event": "idle", "at": 2.0}
    doc = json.loads(sf.read_text())
    assert GROK_SID not in doc["sessions"]


def test_dispatch_pi_prompt_resume_command_via_python_path(tmp_path):
    """pi reports through its JS extension, but resume_command_for stays the
    single source of truth for the CLI shape — guard the pi branch too."""
    sf = tmp_path / "sessions.json"
    emit = agent_hook.dispatch("prompt", "pi", {"session_id": "pi-sess-1"},
                               "term-p", sf, 1.0)
    assert emit["resumeCommand"] == "pi --session pi-sess-1"
