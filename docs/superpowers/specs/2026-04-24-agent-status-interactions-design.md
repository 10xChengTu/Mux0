# Agent Status Interactions Design

**Date**: 2026-04-24
**Branch**: `agent/agent-status-interactions`
**Scope**: mux0 terminal status icon — add "read" state for turn-finished dots; fix `needsInput → running` not advancing after the user answers.

## Background

mux0's status pipeline produces a per-terminal `TerminalStatus` driven by Claude / OpenCode / Codex hooks (see `docs/agent-hooks.md`). The `TerminalStatusIconView` renders one of six visual states in the sidebar (per workspace) and tab bar (per tab), aggregated via `TerminalStatus.aggregate`.

Two behavioral gaps exist today:

1. **No "read" affordance.** After a turn finishes (`.success` green / `.failed` red), the solid dot remains indefinitely until a new turn starts. There is no visual distinction between "I haven't looked at this yet" and "I've seen this result."
2. **`needsInput` sticks after user answers (Claude only).** The only path out of `.needsInput` is a subsequent `running` / `finished` emit. When the user resolves a permission prompt mid-turn, `PostToolUse` fires but the current `agent-hook.py` emits nothing. The dot stays amber until either the next `PreToolUse` or `Stop` arrives — which for slow tools (or when the resolution was the last action in the turn) can feel stuck. OpenCode is fine because `permission.replied` already emits `running`. Codex has no `Notification` analogue so it never enters `.needsInput` in the first place.

## Goals

1. After the user switches to a workspace / tab whose aggregate shows `.success` or `.failed`, dim the dot to a hollow outline ("read").
2. New turn outcomes (`setFinished` arriving over an existing entry) reset the dot to unread (solid).
3. When the user answers an agent question / permission prompt, the status promptly returns to `running`.

## Non-goals

- Persisting read-state across app restarts (status store is in-memory already).
- Read semantics for `.idle` / `.running` / `.needsInput` / `.neverRan`.
- Changes to OpenCode or Codex hook scripts (already correct / not applicable).
- Introducing a user-visible "mark all read" action or settings toggle.

## Design

### A. Read-state for `.success` / `.failed`

#### Data model

Extend `TerminalStatus`:

```swift
case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
             agent: HookMessage.Agent, summary: String? = nil, readAt: Date? = nil)
case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
            agent: HookMessage.Agent, summary: String? = nil, readAt: Date? = nil)
```

`readAt == nil` means unread; non-nil means the terminal was on-screen at the captured time.

#### Store API

Add to `TerminalStatusStore`:

```swift
/// For each id whose current status is `.success(readAt: nil)` or
/// `.failed(readAt: nil)`, stamp `readAt` to `now`. Other states / already-read
/// entries are left untouched. Idempotent when called with the same visible set.
func markRead(terminalIds: [UUID], at now: Date = Date())
```

`setFinished` writes entries with `readAt: nil`, naturally resetting read-state when a new turn ends.

#### Aggregation

`TerminalStatus.aggregate` keeps its existing priority ladder (needsInput > running > failed > success > idle > neverRan). Break ties by preferring the **unread** entry (readAt == nil) within the same kind, so a workspace whose mix is one read success + one unread success still shows unread.

If all entries of the winning kind are read, return any of them (existing "first-wins" tie-break continues to apply among read entries).

#### Visual

`TerminalStatusIconView.render()` adds two new branches:

- `.success(..., readAt: nil)` — existing solid `theme.success` fill (no change)
- `.success(..., readAt: Date)` — hollow: `fillColor = .clear`, `strokeColor = theme.success`, `lineWidth = 1`
- `.failed` read/unread — same pattern with `theme.danger`

`tooltipText(for:)` for the read variants: append `" · read"` to help users confirm the state when hovering. (Optional polish; include in v1.)

`sameKind` treats `.success` and `.failed` as one kind regardless of readAt — toggling read does not need to rebuild animations.

#### Trigger

Read marking is a UI-layer concern. `ContentView` already holds both `WorkspaceStore` and `TerminalStatusStore`. Add:

1. A computed helper (either on `Workspace` or as a free function) that walks the currently selected workspace's currently selected tab's split tree and returns all descendant terminal UUIDs.
2. In `ContentView`, observe changes to:
   - `store.selectedWorkspaceId`
   - The selected workspace's `selectedTabId`
3. On each such change, compute the visible terminal set and call `statusStore.markRead(terminalIds:)`.

Initial app launch does not mark anything read (freshly loaded statuses are `.neverRan`, which isn't affected anyway).

#### Edge cases

- **Deleting a tab / workspace while it holds read entries** — `TerminalStatusStore.forget(terminalId:)` already drops the entry. No change needed.
- **Multi-pane tab** — selection is tab-granular, so all terminals under the selected tab are marked read together when the tab becomes visible. This matches the visual: all panes render simultaneously.
- **Workspace switch to an inactive one then back** — second switch re-stamps `readAt`; idempotent.
- **Re-selecting the currently selected tab** — no state change to observe, no markRead fires; that's fine, they were already read.

### B. Fix `needsInput → running` (Claude / Codex)

Edit `Resources/agent-hooks/agent-hook.py` `dispatch()` in the `posttool` branch:

```python
elif subcmd == "posttool":
    resp = payload.get("tool_response", {})
    if isinstance(resp, dict) and resp.get("is_error"):
        entry["turnHadError"] = True
    emit = {"event": "running", "at": now}
```

Rationale: `PostToolUse` by definition fires *inside* a live turn (tool just returned, agent is about to continue or emit `Stop`). Emitting `running` at this point:

- When the previous state was `.needsInput` → transitions back to `.running` (the bug fix).
- When the previous state was `.running` → `setRunning` preserves the original `startedAt` (existing logic), so tooltip duration doesn't reset.
- `Stop` still wins: it emits `finished` at a later timestamp, and `isStale` in the store guarantees monotonic replacement in the common case. Concurrent PostToolUse+Stop pairs are already handled by the existing stale-event guard.

No change to `HookDispatcher`, OpenCode plugin, or Codex wrapper.

## Testing

### Swift (`mux0Tests/`)

Extend the existing files rather than add new ones:

- `TerminalStatusTests.swift` — aggregate: unread beats read within same kind; priority ladder unchanged.
- `TerminalStatusStoreTests.swift` — `markRead` idempotence; non-`.success/.failed` ids untouched; new `setFinished` clears readAt.
- `TerminalStatusIconViewTests.swift` — read success renders hollow (stroke set, fill clear); unread stays solid.

No new UI-integration test for the `ContentView` selection → markRead wire — that path is thin glue; the store method's unit test is sufficient.

### Python (`Resources/agent-hooks/tests/`)

Extend `test_agent_hook.py` (or equivalent) with a `posttool_emits_running` case covering:

- Clean-response payload → emits `{event: running, at: <now>}` with no `exitCode` / `toolDetail`.
- Error-response payload → emits running **and** sets `turnHadError = True` (preserved via session file for the subsequent `stop`).

## Documentation

- `docs/agent-hooks.md` — update the "各 Agent 的信号来源" table / prose to note that PostToolUse now emits `running` for Claude/Codex (was "no emit").
- `docs/architecture.md` — short note in `### 终端状态推送` describing the read-state modifier on `.success` / `.failed` and the selection-driven `markRead` wire.
- No directory structure changes → no `CLAUDE.md` / `AGENTS.md` Directory Structure edits required. `./scripts/check-doc-drift.sh` should still pass.

## Out of scope / future

- Read-state for `.idle` (different semantic — idle isn't a notification, it's an ambient state).
- A "mark all read" keyboard shortcut.
- Cross-device / multi-window read semantics (mux0 is single-window today).
