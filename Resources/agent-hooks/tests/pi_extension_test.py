"""Tests for the pi extension (Resources/agent-hooks/pi-extension/mux0-status.js).

The extension is plain ESM JavaScript loaded in-process by pi, so it cannot be
exercised through agent-hook.sh. This test loads it in Node with a fake `pi`
object, points MUX0_HOOK_SOCK at a throwaway Unix socket, replays a real pi
event sequence, and asserts the JSON lines that reach the socket.

Run with:
    python3 -m pytest Resources/agent-hooks/tests/pi_extension_test.py -v
Skips automatically when Node is not installed.
"""

import json
import os
import pathlib
import re
import tempfile
import shutil
import socket
import subprocess
import threading
import time

import pytest

HERE = pathlib.Path(__file__).resolve().parent
EXTENSION = HERE.parent / "pi-extension" / "mux0-status.js"

NODE = shutil.which("node")
pytestmark = pytest.mark.skipif(NODE is None, reason="node not installed")

TERMINAL_ID = "00000000-0000-0000-0000-00000000000p"
SESSION_ID = "01a0d1d9-56a9-75eb-9106-cb8af466682c"

# pi's extension loader accepts ESM in .js files, but bare Node treats a .js
# without a `type: module` package.json as CommonJS — so the harness copies the
# exact bytes to a .mjs path. No source edits, so the shipped file is what runs.
HARNESS = """
import net from "node:net";
import fs from "node:fs";
const extension = (await import(process.env.MUX0_EXT_PATH)).default;

const handlers = {};
const pi = {
  on: (name, fn) => { handlers[name] = fn; },
  getSessionName: () => process.env.MUX0_FAKE_SESSION_NAME || undefined,
};
const ctx = {
  sessionManager: {
    getSessionId: () => process.env.MUX0_FAKE_SESSION_ID || "",
    getSessionFile: () => "/tmp/session.jsonl",
  },
};

extension(pi);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // With MUX0_HOOK_SOCK / MUX0_TERMINAL_ID unset the extension deliberately
  // subscribes to nothing; there is then nothing to replay.
  if (!handlers["session_start"]) return;
  // Emitted events must be separated in time: the extension connects a fresh
  // socket per event, so give each accept+read a chance to land in order.
  await handlers["session_start"]({}, ctx);                       await sleep(40);
  await handlers["before_agent_start"](
    { type: "before_agent_start", prompt: "list files then say DONE" }, ctx);
  await sleep(40);
  await handlers["tool_execution_start"](
    { type: "tool_execution_start", toolCallId: "t1", toolName: "bash",
      args: { command: "ls -la /tmp" } }, ctx);                    await sleep(40);
  await handlers["tool_execution_end"](
    { type: "tool_execution_end", toolCallId: "t1", toolName: "bash",
      result: { content: [] }, isError: true }, ctx);              await sleep(40);
  await handlers["ui_prompt_start"](
    { type: "ui_prompt_start", reason: "ui_prompt", kind: "confirm",
      title: "Allow?" }, ctx);                                     await sleep(40);
  await handlers["ui_prompt_end"]({ type: "ui_prompt_end" }, ctx);
  // The cushion after this handler is deliberately optional. When ui_prompt_end
  // dropped its emit promise, the write raced agent_end's and a fixed 40ms gap
  // hid that; MUX0_NO_SLEEP=1 takes the cushion away so the race is observable.
  if (!process.env.MUX0_NO_SLEEP) await sleep(40);
  await handlers["agent_end"]({
    type: "agent_end",
    messages: [
      { role: "user", content: [{ type: "text", text: "list files then say DONE" }] },
      { role: "assistant", content: [
          { type: "thinking", thinking: "hidden" },
          { type: "text", text: "Two files. DONE" }] },
    ],
  }, ctx);                                                          await sleep(40);
  await handlers["session_info_changed"]({ type: "session_info_changed",
                                           name: "Renamed by /name" }, ctx);
  await sleep(40);
  await handlers["session_shutdown"]({ type: "session_shutdown", reason: "quit" }, ctx);
  await sleep(120);
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
"""


def _collect(sock_path: pathlib.Path, stop: threading.Event, out: list):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    server.listen(16)
    server.settimeout(0.2)
    buf = ""
    while not stop.is_set():
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        with conn:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk.decode()
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            if line.strip():
                out.append(json.loads(line))
    server.close()


def _run_extension(tmp_path, extra_env=None):
    """Start the socket server, load the extension in node, return received msgs."""
    # macOS caps AF_UNIX paths at 104 bytes and pytest's tmp_path is already
    # ~80, so the socket lives in a short /tmp dir instead (cleaned up below).
    sock_dir = pathlib.Path(tempfile.mkdtemp(prefix="m0", dir="/tmp"))
    sock_path = sock_dir / "h.sock"
    ext_mjs = tmp_path / "mux0-status.mjs"
    ext_mjs.write_bytes(EXTENSION.read_bytes())
    harness = tmp_path / "harness.mjs"
    harness.write_text(HARNESS)

    received: list = []
    stop = threading.Event()
    thread = threading.Thread(target=_collect, args=(sock_path, stop, received),
                              daemon=True)
    thread.start()
    # Give the listener a moment to bind before node connects.
    for _ in range(50):
        if sock_path.exists():
            break
        time.sleep(0.02)

    env = {
        **os.environ,
        "MUX0_HOOK_SOCK": str(sock_path),
        "MUX0_TERMINAL_ID": TERMINAL_ID,
        "MUX0_EXT_PATH": ext_mjs.as_uri(),
        "MUX0_FAKE_SESSION_ID": SESSION_ID,
        "HOME": str(tmp_path),
    }
    env.update(extra_env or {})
    (tmp_path / "Library" / "Caches" / "mux0").mkdir(parents=True, exist_ok=True)

    proc = subprocess.run([NODE, str(harness)], env=env, capture_output=True,
                          text=True, timeout=60)
    # Drain before stopping the listener: node exiting does not mean the last
    # event was accepted and read yet. Wait for a quiet period instead of a
    # fixed sleep so the suite stays fast but never loses the tail.
    prev, quiet_since, deadline = len(received), None, time.time() + 2.0
    while time.time() < deadline:
        if len(received) != prev:
            prev, quiet_since = len(received), None
        else:
            if quiet_since is None:
                quiet_since = time.time()
            elif time.time() - quiet_since > 0.3:
                break
        time.sleep(0.05)
    stop.set()
    thread.join(timeout=3)
    shutil.rmtree(sock_dir, ignore_errors=True)
    assert proc.returncode == 0, proc.stderr
    return received


def test_pi_extension_event_sequence(tmp_path):
    msgs = _run_extension(tmp_path)
    events = [m["event"] for m in msgs]
    assert events == ["idle", "running", "running", "running", "needsInput",
                      "running", "finished", "idle", "idle"], msgs

    for msg in msgs:
        assert msg["agent"] == "pi"
        assert msg["terminalId"] == TERMINAL_ID
        assert isinstance(msg["at"], float)

    # Every message is one flat JSON object — no stray keys from the wire format.
    assert all(set(m) <= {"terminalId", "event", "agent", "at", "exitCode",
                          "toolDetail", "summary", "resumeCommand",
                          "sessionTitle"} for m in msgs)


def test_pi_extension_running_carries_resume_and_title(tmp_path):
    msgs = _run_extension(tmp_path)
    prompt_msg = msgs[1]
    assert prompt_msg["resumeCommand"] == f"pi --session {SESSION_ID}"
    # No /name yet → first user prompt is the title (same fallback order as
    # claude / codex tabs).
    assert prompt_msg["sessionTitle"] == "list files then say DONE"


def test_pi_extension_tool_detail_and_error_flag(tmp_path):
    msgs = _run_extension(tmp_path)
    tool_msg = msgs[2]
    assert tool_msg["toolDetail"] == "Bash: ls -la /tmp"
    finished = next(m for m in msgs if m["event"] == "finished")
    # tool_execution_end reported isError → the turn's sentinel is 1.
    assert finished["exitCode"] == 1
    assert finished["summary"] == "Two files. DONE"


def test_pi_extension_session_rename_updates_title(tmp_path):
    msgs = _run_extension(tmp_path)
    renamed = [m for m in msgs if m.get("sessionTitle") == "Renamed by /name"]
    assert renamed, msgs
    # Emitted as `idle` because no turn was open — HookDispatcher keeps the
    # terminal success/failed state instead of spinning again.
    assert renamed[0]["event"] == "idle"


def test_pi_extension_needs_input_precedes_resume_of_running(tmp_path):
    msgs = _run_extension(tmp_path)
    idx = {m["event"]: i for i, m in enumerate(msgs)}
    assert idx["needsInput"] < msgs.index(next(m for m in msgs if m["event"] == "finished"))
    # ui_prompt_end pushed the terminal back to running before agent_end.
    assert msgs[idx["needsInput"] + 1]["event"] == "running"


def test_pi_extension_recovers_needs_input_without_a_time_gap(tmp_path):
    """Same ordering, but with the 40ms cushion after ui_prompt_end removed.

    One connection per event means the accept order is the kernel's decision, so
    a `running` whose emit is *not* awaited can reach the socket after the
    following `finished`; the app's stale guard then drops it and the orange
    “needs input” dot stays on until some later event clears it. `ui_prompt_end`
    shipped exactly like that.
    """
    msgs = _run_extension(tmp_path, {"MUX0_NO_SLEEP": "1"})
    events = [m["event"] for m in msgs]
    assert "needsInput" in events, events
    after = events[events.index("needsInput") + 1:]
    assert after and after[0] == "running", events
    assert "finished" in after, events
    assert after.index("running") < after.index("finished"), events


def test_pi_extension_awaits_every_emit():
    """Behavioural ordering tests can be lucky; this one cannot.

    Every emit inside a handler must be awaited (or explicitly returned). A
    dropped promise is a dropped status transition, and the comment block at the
    top of the extension says why: accept order is not ours to choose.
    """
    src = EXTENSION.read_text()
    offenders = []
    for lineno, line in enumerate(src.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        for m in re.finditer(r"(?<![A-Za-z0-9_$.])emit\(", line):
            before = line[: m.start()]
            if re.search(r"\b(await|return|function)\s+$", before):
                continue
            offenders.append(f"L{lineno}: {stripped}")
    assert not offenders, "un-awaited emit(): " + "; ".join(offenders)


def test_pi_extension_silent_without_mux0_env(tmp_path):
    """Outside mux0 (no MUX0_HOOK_SOCK / MUX0_TERMINAL_ID) the extension must
    subscribe to nothing rather than emit events with an empty terminalId."""
    env = {"MUX0_HOOK_SOCK": "", "MUX0_TERMINAL_ID": ""}
    msgs = _run_extension(tmp_path, env)
    assert msgs == []


def test_pi_extension_rejects_malformed_session_id(tmp_path):
    msgs = _run_extension(tmp_path, {"MUX0_FAKE_SESSION_ID": "bad id; rm -rf /"})
    prompt_msg = msgs[1]
    assert "resumeCommand" not in prompt_msg
