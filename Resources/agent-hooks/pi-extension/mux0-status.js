// mux0-status.js — pi extension that streams agent lifecycle state to mux0.
//
// Loaded per-process by `pi-wrapper.sh` via `pi -e <this file>`, so nothing is
// written into the user's `~/.pi` settings and non-mux0 pi sessions stay
// untouched. Same role as `opencode-plugin/mux0-status.js` for OpenCode: pi has
// no CLI hook files, so the extension *is* the hook layer, and it talks to the
// same Unix socket as `agent-hook.py` instead of shelling out.
//
// Wire format (one JSON per line, see docs/agent-hooks.md#ipc):
//   {"terminalId","event","agent":"pi","at","exitCode?","toolDetail?","summary?",
//    "resumeCommand?","sessionTitle?"}
//
// Zero third-party imports on purpose: only Node built-ins, so the file loads
// even when pi's extension dependency resolution is unavailable.

import net from "node:net";
import fs from "node:fs";

const SUMMARY_MAXLEN = 200;
// Same session-id whitelist as agent-hook.py: pi session ids are UUIDs, and the
// resume command is later replayed as shell input, so never let a malformed id
// carry shell metacharacters through.
const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

function hookSocketPath() {
  return process.env.MUX0_HOOK_SOCK || "";
}

function terminalId() {
  return process.env.MUX0_TERMINAL_ID || "";
}

function enabled() {
  return Boolean(hookSocketPath()) && Boolean(terminalId());
}

// Debug trail — same file the shell wrappers / hook-emit.sh append to, so
// `grep 'agent=pi' ~/Library/Caches/mux0/hook-emit.log` shows the whole stream.
function logLine(text) {
  try {
    const dir = `${process.env.HOME}/Library/Caches/mux0`;
    fs.appendFileSync(`${dir}/hook-emit.log`, text + "\n");
  } catch {
    /* best effort only */
  }
}

// Two events inside the same millisecond would let mux0's stale-event guard
// drop the newer one, so hand out strictly increasing timestamps.
let lastAt = 0;
function nextAt() {
  let now = Date.now() / 1000;
  if (now <= lastAt) now = lastAt + 1e-6;
  lastAt = now;
  return now;
}

// Handlers `await` this. Two reasons it is not fire-and-forget:
//   1. Order. One socket per event means the kernel decides which connection
//      mux0's listener accepts first. A `finished` could then be applied
//      before the `running` it follows, and mux0's stale-event guard would
//      re-stamp the later event and leave the tab spinning forever. pi awaits
//      each handler, so awaiting the flush serialises delivery.
//   2. Loss. `process.exit()` right after `session_shutdown` kills sockets whose
//      connect/write is still queued, which is exactly the event that turns the
//      icon idle.
// A dead socket fails fast (ENOENT / ECONNREFUSED), and EMIT_TIMEOUT_MS caps the
// wait so a wedged listener can never stall a turn for more than a fifth of a
// second.
const EMIT_TIMEOUT_MS = 200;

function emit(event, extra) {
  if (!enabled()) return Promise.resolve();
  const payload = {
    terminalId: terminalId(),
    event,
    agent: "pi",
    at: nextAt(),
    ...extra,
  };
  const line = JSON.stringify(payload);
  logLine(`[${payload.at}] event=${event} agent=pi tid=${terminalId().slice(0, 8)}` +
    (payload.exitCode !== undefined ? ` exit=${payload.exitCode}` : ""));
  return new Promise((resolve) => {
    let settled = false;
    let sock = null;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(() => {
      try { if (sock) sock.destroy(); } catch { /* ignore */ }
      finish();
    }, EMIT_TIMEOUT_MS);
    try {
      sock = net.createConnection({ path: hookSocketPath() });
    } catch {
      finish();
      return;
    }
    sock.on("connect", () => {
      try {
        sock.write(line + "\n", () => {
          // Half-close so the listener sees EOF right away instead of waiting
          // for the timeout — mux0's HookSocketListener reads until EOF per
          // accept. `close` then resolves us.
          try { sock.end(); } catch { finish(); }
        });
      } catch {
        try { sock.destroy(); } catch { /* ignore */ }
        finish();
      }
    });
    sock.on("close", finish);
    sock.on("error", () => {
      try { sock.destroy(); } catch { /* ignore */ }
      finish();
    });
  });
}

function clip(text) {
  return String(text).replace(/\s+/g, " ").trim().slice(0, SUMMARY_MAXLEN);
}

// pi content blocks: [{type:"text",text:...},{type:"thinking",thinking:...}, ...]
function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  for (const block of content) {
    if (block && block.type === "text" && typeof block.text === "string") return block.text;
  }
  return "";
}

// Last assistant text of a low-level run — `agent_end` carries the run's
// messages, which is pi's equivalent of Claude's transcript tail.
function lastAssistantText(messages) {
  if (!Array.isArray(messages)) return "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (!msg || msg.role !== "assistant") continue;
    const text = clip(textFromContent(msg.content));
    if (text) return text;
  }
  return "";
}

// Compact "Edit src/foo.ts" style label for the running tooltip (mirrors
// agent-hook.py's describe_tool so every agent renders the same shape).
function shortPath(p) {
  const parts = String(p || "").split("/").filter(Boolean);
  return parts.slice(-3).join("/");
}

function describeTool(toolName, args) {
  const a = args && typeof args === "object" ? args : {};
  switch (toolName) {
    case "bash": {
      const cmd = String(a.command || "").split("\n")[0].slice(0, 60);
      return cmd ? `Bash: ${cmd}` : "Bash";
    }
    case "read":
    case "write":
    case "edit": {
      const p = shortPath(a.path || a.file_path);
      const label = toolName.charAt(0).toUpperCase() + toolName.slice(1);
      return p ? `${label} ${p}` : label;
    }
    case "ls": {
      const p = shortPath(a.path);
      return p ? `List ${p}` : "List";
    }
    case "grep":
      // JSON.stringify quotes the pattern, matching agent-hook.py's `{pat!r}`.
      return `Grep ${JSON.stringify(a.pattern ?? "")}`;
    case "find":
    case "glob":
      return `Glob ${a.pattern ?? ""}`;
    default:
      return toolName || "";
  }
}

function sessionIdOf(ctx) {
  try {
    const id = ctx?.sessionManager?.getSessionId?.();
    return typeof id === "string" ? id : "";
  } catch {
    return "";
  }
}

// Only pi's own display name (`/name`, `pi.setSessionName()`) counts as an
// explicit title; otherwise fall back to the first typed prompt, which is the
// same priority order mux0 uses for claude/codex tabs.
function titleFor(state) {
  if (state.sessionName) return clip(state.sessionName);
  if (state.firstPrompt) return clip(state.firstPrompt);
  return "";
}

export default function (pi) {
  if (!enabled()) {
    // Running outside mux0 (plain Terminal): subscribe to nothing at all so the
    // extension costs nothing and can never emit a mis-attributed event.
    return;
  }

  const state = {
    turnOpen: false,
    turnHadError: false,
    firstPrompt: "",
    sessionName: "",
  };

  try {
    const existing = pi.getSessionName?.();
    if (typeof existing === "string") state.sessionName = existing;
  } catch {
    /* older pi without getSessionName */
  }

  pi.on("session_start", async () => {
    state.turnOpen = false;
    state.turnHadError = false;
    state.firstPrompt = "";
    try {
      const name = pi.getSessionName?.();
      if (typeof name === "string") state.sessionName = name;
    } catch {
      /* ignore */
    }
    // pi sits idle at its prompt on launch; without this the icon would stay
    // "running" from shell preexec until the first turn ends.
    await emit("idle");
  });

  pi.on("before_agent_start", async (event, ctx) => {
    state.turnOpen = true;
    state.turnHadError = false;
    const prompt = typeof event?.prompt === "string" ? event.prompt : "";
    if (!state.firstPrompt && prompt.trim()) state.firstPrompt = prompt;
    const extra = {};
    const id = sessionIdOf(ctx);
    if (id && SESSION_ID_RE.test(id)) extra.resumeCommand = `pi --session ${id}`;
    const title = titleFor(state);
    if (title) extra.sessionTitle = title;
    await emit("running", extra);
  });

  pi.on("tool_execution_start", async (event) => {
    const detail = describeTool(event?.toolName, event?.args);
    await emit("running", detail ? { toolDetail: detail } : {});
  });

  pi.on("tool_execution_end", async (event) => {
    if (event?.isError) state.turnHadError = true;
    // Same reason as PostToolUse in agent-hook.py: push a needsInput back to
    // running once the user answers the prompt and the tool finishes.
    await emit("running");
  });

  pi.on("ui_prompt_start", async (event) => {
    // pi has no built-in permission prompt; this fires when an extension asks
    // the user something via ctx.ui.confirm/select/input/editor/custom.
    await emit("needsInput", event?.kind ? { toolDetail: `Waiting on ${event.kind}` } : {});
  });

  pi.on("ui_prompt_end", async () => {
    // await, like every other emit: one connection per event and no await means
    // the kernel decides the accept order, so this `running` can land after the
    // next `finished` and get dropped by the stale guard — leaving the orange
    // “needs input” dot on until some later event happens to clear it.
    if (state.turnOpen) await emit("running");
  });

  pi.on("agent_end", async (event) => {
    if (!state.turnOpen) return; // e.g. a run started without a user prompt
    state.turnOpen = false;
    const extra = { exitCode: state.turnHadError ? 1 : 0 };
    const summary = lastAssistantText(event?.messages);
    if (summary) extra.summary = summary;
    const title = titleFor(state);
    if (title) extra.sessionTitle = title;
    await emit("finished", extra);
    state.turnHadError = false;
  });

  pi.on("session_info_changed", async (event) => {
    const name = typeof event?.name === "string" ? event.name : "";
    state.sessionName = name;
    if (!name) return;
    const extra = { sessionTitle: clip(name) };
    // Report the rename with whatever state we are actually in — `idle` after a
    // finished turn keeps the terminal success/failed state (HookDispatcher
    // ignores idle once a turn settled), `running` mid-turn keeps the spinner.
    await emit(state.turnOpen ? "running" : "idle", extra);
  });

  pi.on("session_shutdown", async () => {
    await emit("idle");
  });
}
