import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import fanfan

@MainActor
final class AppLifecycleTests: XCTestCase {
    override func setUp() async throws {
        // The SwiftUI test host may restore Settings at launch.
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        try await settle(for: 0.7)
    }

    func testWindowlessActivationRemovesDockIconAfterLatePromotion() async throws {
        let delegate = AppDelegate()
        NSApp.setActivationPolicy(.regular)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        try await settle(for: 0.1)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)

        // Simulate SwiftUI promoting the app later in the same activation cycle.
        NSApp.setActivationPolicy(.regular)
        try await settle(for: 0.6)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        withExtendedLifetime(delegate) {}
    }

    func testVisibleEmptySettingsWindowDoesNotKeepDockIcon() async throws {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("app.settings_title", comment: "")
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.setActivationPolicy(.regular)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.contentView?.bounds.width, 0)

        let delegate = AppDelegate()
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        try await settle(for: 0.7)

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        withExtendedLifetime(delegate) {}
    }

    func testSettingsCommandOpensAUsableWindow() async throws {
        func settingsCommands(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in
                if let submenu = item.submenu { return settingsCommands(in: submenu) }
                return item.keyEquivalent == "," && item.keyEquivalentModifierMask.contains(.command) ? [item] : []
            }
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let commands = settingsCommands(in: menu)
        XCTAssertEqual(commands.count, 1)
        let command = try XCTUnwrap(commands.first)
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(NSApp.sendAction(action, to: command.target, from: command))
        try await settle(for: 0.7)

        let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.isVisible }
        defer {
            windows.forEach { $0.close() }
            NSApp.setActivationPolicy(.accessory)
        }
        XCTAssertEqual(windows.count, 1)
        let window = try XCTUnwrap(windows.first)
        XCTAssertGreaterThan(window.contentView?.bounds.width ?? 0, 0)
        XCTAssertGreaterThan(window.contentView?.bounds.height ?? 0, 0)
    }

    func testActivationKeepsSettingsOpenedBeforeDelayedCheck() async throws {
        let delegate = AppDelegate()
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        try await settle(for: 0.1)

        let window = makeSettingsWindow()
        defer {
            window.close()
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.setActivationPolicy(.regular)
        window.orderFront(nil)
        try await settle(for: 0.6)

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        withExtendedLifetime(delegate) {}
    }

    func testNotificationClickKeepsMiniaturizedSettingsInDock() async throws {
        let window = makeSettingsWindow()
        defer {
            window.close()
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.setActivationPolicy(.regular)
        window.orderFront(nil)
        window.miniaturize(nil)
        let delegate = AppDelegate()
        delegate.handleNotificationResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "high-temp-90"
        )
        try await settle(for: 0.7)

        XCTAssertTrue(window.isMiniaturized)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        withExtendedLifetime(delegate) {}
    }

    func testOnlyOpeningHighTemperatureNotificationRestoresMenuBarPolicy() async throws {
        let delegate = AppDelegate()
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.setActivationPolicy(.regular)

        delegate.handleNotificationResponse(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: "high-temp-90"
        )
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        delegate.handleNotificationResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "unrelated"
        )
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        delegate.handleNotificationResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "high-temp-90"
        )
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        withExtendedLifetime(delegate) {}
    }

    func testPopoverWaitsForContentAndRepeatedShowKeepsItOpen() async throws {
        let manager = StatusBarManager()
        defer { manager.closePopover() }
        var mountCount = 0
        manager.showPopover()
        manager.setupStatusBar()
        try await settle(for: 0.1)
        XCTAssertFalse(manager.isPopoverShown)

        manager.setPopoverContent {
            mountCount += 1
            return Text("Notification lifecycle test").frame(width: 200, height: 80)
        }
        try await settle(for: 1.0)
        XCTAssertTrue(manager.isPopoverShown)
        XCTAssertEqual(mountCount, 1)

        manager.showPopover()
        XCTAssertTrue(manager.isPopoverShown)
        XCTAssertEqual(mountCount, 1)
    }

    func testPopoverWaitsForStatusItemWhenContentIsReadyFirst() async throws {
        let manager = StatusBarManager()
        defer { manager.closePopover() }
        manager.setPopoverContent { Text("Notification lifecycle test").frame(width: 200, height: 80) }
        manager.showPopover()
        try await settle(for: 0.1)
        XCTAssertFalse(manager.isPopoverShown)

        manager.setupStatusBar()
        try await settle(for: 1.0)
        XCTAssertTrue(manager.isPopoverShown)
    }

    func testNotificationClickOpensPopoverWithoutLeavingDockIcon() async throws {
        let delegate = AppDelegate()
        let manager = delegate.statusBarManager
        defer { manager.closePopover() }
        manager.setupStatusBar()
        manager.setPopoverContent { Text("Notification lifecycle test").frame(width: 200, height: 80) }
        try await settle(for: 0.1)

        NSApp.setActivationPolicy(.regular)
        delegate.handleNotificationResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "high-temp-90"
        )
        try await settle(for: 1.0)

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertTrue(manager.isPopoverShown)
        withExtendedLifetime(delegate) {}
    }

    func testNotificationHandoffPreservesPendingPopover() async throws {
        let delegate = AppDelegate()
        let manager = delegate.statusBarManager
        defer { manager.closePopover() }
        manager.setupStatusBar()
        manager.setPopoverContent { Text("Notification lifecycle test").frame(width: 200, height: 80) }
        try await settle(for: 0.1)
        delegate.handleNotificationResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "high-temp-90"
        )
        XCTAssertFalse(manager.isPopoverShown, "Leave the notification callback before showing the panel")
        // A focus handoff before presentation must not cancel the user's click.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await settle(for: 1.0)

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertTrue(manager.isPopoverShown)
        withExtendedLifetime(delegate) {}
    }

    func testResignActiveClosesShownPopoverAndDoesNotReopen() async throws {
        let manager = StatusBarManager()
        defer { manager.closePopover() }
        manager.setupStatusBar()
        manager.setPopoverContent { Text("Notification lifecycle test").frame(width: 200, height: 80) }
        manager.showPopover()
        try await settle(for: 1.0)
        XCTAssertTrue(manager.isPopoverShown)

        // Notification Center can return focus to the previous app without
        // activating an accessory app. Its loss-of-focus handler must still
        // dismiss an open panel, regardless of the host's activation grant.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await settle(for: 0.7)
        XCTAssertFalse(manager.isPopoverShown)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await settle(for: 0.7)
        XCTAssertFalse(manager.isPopoverShown)
    }

    func testClosingPendingPopoverCancelsActivationPresentation() async throws {
        let manager = StatusBarManager()
        defer { manager.closePopover() }
        manager.setupStatusBar()
        manager.setPopoverContent { Text("Notification lifecycle test").frame(width: 200, height: 80) }
        try await settle(for: 0.1)

        manager.showPopover()
        manager.closePopover()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await settle(for: 1.0)

        XCTAssertFalse(manager.isPopoverShown)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lifecycle test settings"
        window.isReleasedWhenClosed = false
        return window
    }

    private func settle(for seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
