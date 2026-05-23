import XCTest
@testable import mux0

final class NotificationNamesTests: XCTestCase {
    func testNewMenuNotificationRawValues() {
        XCTAssertEqual(Notification.Name.mux0FocusNextPane.rawValue, "mux0.focusNextPane")
        XCTAssertEqual(Notification.Name.mux0FocusPrevPane.rawValue, "mux0.focusPrevPane")
        XCTAssertEqual(Notification.Name.mux0SelectWorkspaceAtIndex.rawValue,
                       "mux0.selectWorkspaceAtIndex")
        // 注：mux0Copy / mux0Paste / mux0SelectAll 已删除——⌘C/⌘V/⌘A 不再走通知，
        // 改由 mux0App 的 pasteboard CommandGroup 通过 NSApp.sendAction(:to:nil)
        // 沿 responder chain 派发标准 selector，命中 NSText（rename / 设置 TextField）
        // 或终端 GhosttyTerminalView 的同名 selector。
    }
}
