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


def test_resume_command_for_unknown_agent():
    # OpenCode (and any future agent) returns empty until we know its CLI shape.
    assert agent_hook.resume_command_for("opencode", "xyz") == ""


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
