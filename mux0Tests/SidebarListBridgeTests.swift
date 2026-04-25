import XCTest
import SwiftUI
@testable import mux0

final class SidebarListBridgeTests: XCTestCase {

    private func makeStore(workspaceCount: Int) -> WorkspaceStore {
        // Unique persistence key per test → no UserDefaults cross-pollution.
        let key = "mux0.test.sidebar.\(UUID().uuidString)"
        let store = WorkspaceStore(persistenceKey: key)
        // Custom-key store starts empty (auto-default only on prod key).
        for i in 0..<workspaceCount {
            store.createWorkspace(name: "ws\(i)")
        }
        return store
    }

    /// Drives the bridge through NSHostingView and returns the inner WorkspaceListView.
    private func materialize(_ store: WorkspaceStore,
                             metadata: [UUID: WorkspaceMetadata] = [:],
                             tick: Int = 0) throws -> (NSHostingView<AnyView>, WorkspaceListView) {
        let bridge = SidebarListBridge(
            store: store,
            statusStore: TerminalStatusStore(),
            theme: .systemFallback(isDark: true),
            metadata: metadata,
            metadataTick: tick,
            languageTick: 0,
            onRequestDelete: { _ in },
            onRequestEditCommand: { _, _ in }
        )
        let host = NSHostingView(rootView: AnyView(bridge))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        host.layout()
        // Run loop tick — SwiftUI may defer NSView creation until the next iteration.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let listView = try XCTUnwrap(findFirst(WorkspaceListView.self, in: host),
                                     "WorkspaceListView not found in hosting view tree")
        return (host, listView)
    }

    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = findFirst(type, in: sub) { return hit }
        }
        return nil
    }

    /// Counts WorkspaceRowItemView instances by class name (the type itself is private to
    /// WorkspaceListView.swift, so direct `as?` won't compile here).
    private func rowCount(in listView: WorkspaceListView) -> Int {
        var count = 0
        var queue: [NSView] = [listView]
        while let v = queue.first {
            queue.removeFirst()
            if String(describing: type(of: v)).contains("WorkspaceRowItemView") {
                count += 1
            }
            queue.append(contentsOf: v.subviews)
        }
        return count
    }

    private func rowHeights(in listView: WorkspaceListView) -> [CGFloat] {
        var rows: [NSView] = []
        var queue: [NSView] = [listView]
        while let v = queue.first {
            queue.removeFirst()
            if String(describing: type(of: v)).contains("WorkspaceRowItemView") {
                rows.append(v)
            }
            queue.append(contentsOf: v.subviews)
        }
        return rows.sorted { $0.frame.minY < $1.frame.minY }.map(\.frame.height)
    }

    // MARK: tests

    func testMakeProducesListViewWithCorrectRowCount() throws {
        let store = makeStore(workspaceCount: 2)
        let (_, listView) = try materialize(store)
        XCTAssertEqual(rowCount(in: listView), 2)
    }

    func testEmptyStoreYieldsZeroRows() throws {
        let store = makeStore(workspaceCount: 0)
        let (_, listView) = try materialize(store)
        XCTAssertEqual(rowCount(in: listView), 0)
    }

    func testRowCountReflectsStoreMutations() throws {
        let store = makeStore(workspaceCount: 1)
        let (host, listView) = try materialize(store)
        XCTAssertEqual(rowCount(in: listView), 1)

        store.createWorkspace(name: "second")
        host.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(rowCount(in: listView), 2)

        if let first = store.workspaces.first {
            store.deleteWorkspace(id: first.id)
        }
        host.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(rowCount(in: listView), 1)
    }

    func testShortDefaultCommandKeepsBaseRowHeight() throws {
        let store = makeStore(workspaceCount: 2)
        store.updateDefaultCommand(workspaceId: store.workspaces[1].id, command: "ssh inx-xe9680")

        let (_, listView) = try materialize(store)
        listView.layoutSubtreeIfNeeded()

        let heights = rowHeights(in: listView)
        XCTAssertEqual(heights.count, 2)
        XCTAssertEqual(heights[0], WorkspaceListView.baseRowHeight)
        XCTAssertEqual(heights[1], WorkspaceListView.baseRowHeight)
    }
}
