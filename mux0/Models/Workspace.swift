import Foundation
import CoreGraphics

enum SplitDirection: String, Codable, Equatable {
    case horizontal  // top / bottom
    case vertical    // left / right
}

indirect enum SplitNode: Equatable {
    // Leaf: one terminal identified by UUID
    case terminal(UUID)
    // Branch: (splitId, direction, firstRatio 0…1, first child, second child)
    case split(UUID, SplitDirection, CGFloat, SplitNode, SplitNode)

    // All terminal IDs in depth-first order
    func allTerminalIds() -> [UUID] {
        switch self {
        case .terminal(let id): return [id]
        case .split(_, _, _, let a, let b): return a.allTerminalIds() + b.allTerminalIds()
        }
    }

    // Replace the .terminal(terminalId) leaf with newNode
    func replacing(terminalId: UUID, with newNode: SplitNode) -> SplitNode {
        switch self {
        case .terminal(let id):
            return id == terminalId ? newNode : self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(sid, dir, ratio,
                first.replacing(terminalId: terminalId, with: newNode),
                second.replacing(terminalId: terminalId, with: newNode))
        }
    }

    // Remove terminalId. Returns nil when self IS that terminal (caller promotes sibling).
    func removing(terminalId: UUID) -> SplitNode? {
        switch self {
        case .terminal(let id):
            return id == terminalId ? nil : self
        case .split(let sid, let dir, let ratio, let first, let second):
            let r1 = first.removing(terminalId: terminalId)
            let r2 = second.removing(terminalId: terminalId)
            if r1 == nil { return second }   // first WAS the terminal → promote second
            if r2 == nil { return first }    // second WAS the terminal → promote first
            return .split(sid, dir, ratio, r1 ?? first, r2 ?? second)
        }
    }

    /// Structural equality that ignores split ratios. Two layouts share structure when
    /// their tree shape, split UUIDs, directions and terminal UUIDs all match. Used by
    /// TabContentView to decide whether a cached SplitPaneView can be reused: pure
    /// ratio changes (divider drags) must NOT cause a rebuild, otherwise the terminal
    /// views get re-parented on every drag, which resizes each ghostty surface through
    /// a transient 0×0 state and leaves the Metal renderer blank.
    static func sameStructure(_ a: SplitNode, _ b: SplitNode) -> Bool {
        switch (a, b) {
        case (.terminal(let i), .terminal(let j)):
            return i == j
        case (.split(let s1, let d1, _, let a1, let b1),
              .split(let s2, let d2, _, let a2, let b2)):
            return s1 == s2 && d1 == d2
                && sameStructure(a1, a2) && sameStructure(b1, b2)
        default:
            return false
        }
    }

    // Update the ratio of the split whose UUID matches splitId
    func updatingRatio(splitId: UUID, to ratio: CGFloat) -> SplitNode {
        switch self {
        case .terminal: return self
        case .split(let sid, let dir, let currentRatio, let first, let second):
            if sid == splitId {
                return .split(sid, dir, ratio, first, second)
            }
            return .split(sid, dir, currentRatio,
                first.updatingRatio(splitId: splitId, to: ratio),
                second.updatingRatio(splitId: splitId, to: ratio))
        }
    }
}

// MARK: - SplitNode Codable

extension SplitNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, terminalId, splitId, direction, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "terminal":
            self = .terminal(try c.decode(UUID.self, forKey: .terminalId))
        case "split":
            self = .split(
                try c.decode(UUID.self, forKey: .splitId),
                try c.decode(SplitDirection.self, forKey: .direction),
                try c.decode(CGFloat.self, forKey: .ratio),
                try c.decode(SplitNode.self, forKey: .first),
                try c.decode(SplitNode.self, forKey: .second)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown SplitNode type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let id):
            try c.encode("terminal", forKey: .type)
            try c.encode(id, forKey: .terminalId)
        case .split(let sid, let dir, let ratio, let first, let second):
            try c.encode("split", forKey: .type)
            try c.encode(sid, forKey: .splitId)
            try c.encode(dir, forKey: .direction)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

// MARK: - TerminalTab

struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var layout: SplitNode
    var focusedTerminalId: UUID
    /// Quick Action binding for this tab. nil = ordinary terminal tab.
    /// Non-nil values match either a `BuiltinQuickAction.id` (e.g.
    /// `"gitui"`, `"claude"`) or a custom action's UUID. When the tab's
    /// first terminal opens, `TabContentView.resolvedStartupCommand` resolves
    /// this id via `QuickActionsStore.command(for:)` and injects the result
    /// as the surface's initial_input.
    var quickActionId: String? = nil

    init(id: UUID = UUID(), title: String, terminalId: UUID = UUID(),
         quickActionId: String? = nil) {
        self.id = id
        self.title = title
        self.layout = .terminal(terminalId)
        self.focusedTerminalId = terminalId
        self.quickActionId = quickActionId
    }
}

// MARK: - Workspace

struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabs: [TerminalTab]
    var selectedTabId: UUID?
    var defaultCommand: String?
    /// Per-terminal one-shot command (key = terminalId.uuidString) to inject
    /// as the next surface's `initial_input`. Persisted synchronously on
    /// each agent `resumeCommand` so the latest session id survives
    /// ⌘Q / force-quit / crash without relying on `willTerminate`.
    /// Non-destructive read; overwritten only by the next prompt.
    var pendingPrefills: [String: String] = [:]

    init(id: UUID = UUID(), name: String, defaultCommand: String? = nil) {
        self.id = id
        self.name = name
        self.defaultCommand = defaultCommand
        self.tabs = []
        self.selectedTabId = nil
    }

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabId }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tabs, selectedTabId, defaultCommand, pendingPrefills
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.tabs = try c.decode([TerminalTab].self, forKey: .tabs)
        self.selectedTabId = try c.decodeIfPresent(UUID.self, forKey: .selectedTabId)
        self.defaultCommand = try c.decodeIfPresent(String.self, forKey: .defaultCommand)
        self.pendingPrefills = (try? c.decode([String: String].self, forKey: .pendingPrefills)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(selectedTabId, forKey: .selectedTabId)
        try c.encodeIfPresent(defaultCommand, forKey: .defaultCommand)
        try c.encode(pendingPrefills, forKey: .pendingPrefills)
    }
}

enum WorkspaceDefaultCommand {
    /// Build the auto-executing `initial_input` payload for a new ghostty
    /// surface. Trailing `\n` makes the shell run it immediately.
    static func startupInput(for command: String?) -> String? {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return "\(trimmed)\n"
    }
}
