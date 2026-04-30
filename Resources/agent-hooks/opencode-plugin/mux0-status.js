// mux0-status.js — opencode plugin that reports session state to mux0 via Unix socket.
// ESM module. opencode (v1.4.x) loads plugins via `await import(fileURL)` and expects
// either a default export `{ server: async (input) => hooks }` (v1 shape) or any named
// async function export `(input, options) => hooks` (legacy shape). The plugin returns
// a hooks object; there is NO event bus on the input — we subscribe via the `event` hook.
//
// Authoritative schema: packages/plugin/src/index.ts in sst/opencode.
// Written independently for mux0.

import net from "node:net";

const SOCK = process.env.MUX0_HOOK_SOCK;
const TID  = process.env.MUX0_TERMINAL_ID;

// In-memory per-plugin turn state. Reset on session.idle / session.error /
// session.status{type=idle}. No session file needed — the plugin process
// outlives the turn naturally (opencode keeps it alive across turns).
let turn = { hadError: false, tool: null, startedAt: null };

function emit(msg) {
    if (!SOCK || !TID) return;
    const payload = JSON.stringify({
        terminalId: TID,
        agent: "opencode",
        at: Date.now() / 1000,
        ...msg,
    }) + "\n";
    try {
        const client = net.createConnection(SOCK);
        client.on("error", () => {});
        client.setTimeout(500, () => { try { client.destroy(); } catch {} });
        client.on("connect", () => client.end(payload));
    } catch (_) {
        // swallow
    }
}

function shortPath(p) {
    if (!p) return "";
    const parts = p.split("/").filter(Boolean);
    return parts.length > 3 ? parts.slice(-3).join("/") : parts.join("/");
}

// OpenCode session ids are alphanumeric with underscores/dashes (`ses_xxx`
// in current versions). Restrict the resume command to this charset so a
// malformed payload can't inject shell metacharacters into the persisted
// `initial_input`.
const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;
function resumeCommandFor(sessionID) {
    if (!sessionID || !SESSION_ID_RE.test(sessionID)) return null;
    return `opencode --session ${sessionID}`;
}

function describeOpencodeTool(tool, input) {
    if (!input || typeof input !== "object") return tool || "";
    const t = tool || "";
    if (t === "edit" || t === "write" || t === "read") {
        const p = shortPath(input.filePath || input.file_path || "");
        return p ? `${t.charAt(0).toUpperCase() + t.slice(1)} ${p}` : t;
    }
    if (t === "bash") {
        const cmd = (input.command || "").split("\n")[0].slice(0, 60);
        return cmd ? `Bash: ${cmd}` : "Bash";
    }
    return t;
}

function emitFinishedFromTurn() {
    emit({ event: "finished", exitCode: turn.hadError ? 1 : 0 });
    turn = { hadError: false, tool: null, startedAt: null };
}

export const Mux0StatusPlugin = async (_input) => ({
    event: async ({ event }) => {
        switch (event?.type) {
            case "session.created":
                // Do not reset turn state here — session.created fires before first turn too.
                return;
            case "session.idle":                // deprecated but still emitted
            case "session.error":
                return emitFinishedFromTurn();
            case "permission.asked":
                return emit({ event: "needsInput" });
            case "permission.replied":
                return emit({ event: "running" });
            case "session.status": {
                const t = event.properties?.status?.type;
                if (t === "busy") {
                    if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
                    emit({ event: "running" });
                } else if (t === "idle") {
                    emitFinishedFromTurn();
                }
                return;
            }
        }
    },

    // chat.message fires when the user sends a message — opencode's
    // equivalent of UserPromptSubmit. We attach resumeCommand here so the
    // session id is captured even on prompts that don't trigger any tool
    // calls (e.g. a quick chat answer with no Edit/Bash/Read).
    "chat.message": async (input, _output) => {
        if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
        const resumeCommand = resumeCommandFor(input?.sessionID);
        const payload = { event: "running" };
        if (resumeCommand) payload.resumeCommand = resumeCommand;
        emit(payload);
    },

    // Plugin runtime calls these hooks with two args:
    //   (input, output) where input has { tool, sessionID, callID, ... }.
    // Tool args live on output.args (before) and output.{title,output,metadata}
    // (after). See packages/plugin/src/index.ts in sst/opencode.
    "tool.execute.before": async (input, output) => {
        turn.tool = input?.tool;
        if (!turn.startedAt) turn.startedAt = Date.now() / 1000;
        const detail = describeOpencodeTool(input?.tool, output?.args);
        const resumeCommand = resumeCommandFor(input?.sessionID);
        const payload = { event: "running" };
        if (detail) payload.toolDetail = detail;
        if (resumeCommand) payload.resumeCommand = resumeCommand;
        emit(payload);
    },

    "tool.execute.after": async (_input, output) => {
        // Tools may report failure in `output.metadata.error` /
        // `output.metadata.status`, or by throwing (which surfaces as
        // session.error rather than reaching this hook).
        const hadErr = !!(output?.metadata?.error)
            || (output?.metadata?.status === "error");
        if (hadErr) turn.hadError = true;
        // No socket emit — icon only flips at session.idle / session.status{type=idle}.
    },
});
