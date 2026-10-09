//
//  File: fanfanApp.swift / 文件：fanfanApp.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Menu bar app lifecycle and settings scene entry point. / 描述：菜单栏应用生命周期和设置窗口入口。
//

import SwiftUI
import AppKit
import Combine
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBarManager = StatusBarManager()
    lazy var viewModel = FanControlViewModel()
    let updater = AppUpdater()
    private var iconUpdateTimer: Timer?
    private var displayModeObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    /// Keeps App Nap from freezing our background timers. / 中文：阻止 App Nap 冻结后台定时器的活动凭证。
    private var backgroundActivity: NSObjectProtocol?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register before launch completes so clicks on older alerts also work
        // when they launch the app. / 中文：在启动完成前接管通知，兼容点击旧通知启动应用。
        UNUserNotificationCenter.current().delegate = self
        // Hide dock icon as early as possible to minimize the brief Dock flash
        // that occurs because LSUIElement is NO (so the app shows in Launchpad).
        // 中文：尽早隐藏 Dock 图标，减少因 LSUIElement=NO（为了出现在启动台）
        // 而在 Dock 里短暂闪现图标的时间。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Suppress App Nap only while a real fan is under manual/automatic app
        // control. As an .accessory menu-bar app with no foreground window,
        // macOS otherwise freezes our monitoring/fan-control Timers when
        // the app sits in the background (e.g. lid closed). When that happens,
        // automatic scheduling silently stops on wake — even reapplySettings()'s
        // freshly created Timer gets frozen — until the user interacts with the
        // menu bar again. `userInitiatedAllowingIdleSystemSleep` keeps the timers
        // alive while still letting the system sleep normally (so closing the lid
        // still saves power).
        // 中文：仅在真实风扇处于手动/自动控制时抑制 App Nap。本应用是无前台窗口的
        // .accessory 菜单栏程序，否则
        // 合盖等后台场景下 macOS 会冻结我们的监控/风扇控制 Timer，导致唤醒后自动
        // 调度静默停止（连 reapplySettings() 新建的 Timer 也会被冻结），直到用户
        // 再次与菜单栏交互。userInitiatedAllowingIdleSystemSleep 既保持定时器运行，
        // 又允许系统正常睡眠（合盖依然省电）。
        viewModel.fanController.$isControlEnabled
            .removeDuplicates()
            .sink { [weak self] shouldPreventNap in
                self?.setFanControlActivityActive(shouldPreventNap)
            }
            .store(in: &cancellables)

        // Settings may promote the app to `.regular`. Restore menu-bar mode
        // after its last window closes. / 中文：设置可能将应用提升为普通应用，最后一个窗口关闭后恢复菜单栏模式。
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let closing = notification.object as? NSWindow
            self?.scheduleMenuBarPolicyUpdate(ignoring: closing)
        }

        // Initialize components immediately / 中文：立即初始化组件
        setupApplication()
    }
    
    private func setupApplication() {
        
        // Initialize and setup status bar immediately / 中文：立即初始化并配置状态栏
        statusBarManager.setupStatusBar()
        
        // Set initial display mode / 中文：设置初始显示模式
        let initialMode = UserDefaults.standard.string(forKey: "statusBarDisplayMode") ?? "temperature"
        statusBarManager.setDisplayMode(initialMode)
        
        // Listen for display mode changes / 中文：监听显示模式变化
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StatusBarDisplayModeChanged"),
            object: nil,
            queue: .main
        ) { [weak statusBarManager] notification in
            if let mode = notification.object as? String {
                statusBarManager?.setDisplayMode(mode)
            }
        }
        
        // Create popover content after a brief delay to ensure status bar is ready / 中文：短暂延迟后创建弹出内容，确保状态栏已就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let statusBarManager = self.statusBarManager
            
            let viewModel = self.viewModel
            statusBarManager.setPopoverContent { [weak statusBarManager] in
                PopoverView(viewModel: viewModel, statusBarManager: statusBarManager)
            }
            
            // Initialize monitoring / 中文：初始化监控
            self.initializeMonitoring()
        }
    }
    
    private func initializeMonitoring() {
        // Start monitoring regardless of permission check / 中文：无论权限检查结果如何都启动监控
        // SMC read operations typically work without special privileges / 中文：SMC 读取通常不需要特殊权限
        viewModel.startMonitoring()
        // Keep power-source info fresh app-wide, not just while the popover is / 中文：让电源功率信息全程保持刷新，而不仅在弹窗
        // open, so the auto-mode load-aware feedforward always has live wattage. / 中文：打开时刷新，使自动模式的负载感知前馈始终有实时功率。
        BatteryMonitor.shared.startMonitoring()
        startIconUpdateTimer()
    }

    private func setFanControlActivityActive(_ active: Bool) {
        if active, backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Continuous fan monitoring and automatic speed control"
            )
        } else if !active, let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
            self.backgroundActivity = nil
        }
    }
    
    private func startIconUpdateTimer() {
        iconUpdateTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateStatusBarIcon()
        }
        // The icon refresh is purely cosmetic — let the kernel coalesce it. / 中文：图标刷新纯属外观——允许内核合并唤醒。
        timer.tolerance = 0.5
        RunLoop.current.add(timer, forMode: .common)
        iconUpdateTimer = timer
        
        // Initial update / 中文：初始更新
        updateStatusBarIcon()
    }
    
    private func updateStatusBarIcon() {
        let maxTemp = viewModel.maxTemperature
        let power = BatteryMonitor.shared.batteryInfo.powerWatts
        statusBarManager.updateIcon(
            fanSpeeds: viewModel.fanSpeeds,
            fanMinSpeeds: viewModel.fanMinSpeeds,
            fanMaxSpeeds: viewModel.fanMaxSpeeds,
            temperature: maxTemp > 0 ? maxTemp : nil,
            powerWatts: power
        )
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Hand the fans back to the firmware before quitting, synchronously — / 中文：退出前同步把风扇交还固件——
        // otherwise they stay stuck at the last manual target until the next / 中文：否则它们会卡在最后的手动转速，
        // launch or system sleep. / 中文：直到下次启动或系统睡眠才恢复。
        viewModel.restoreAutomaticControlSync()
        iconUpdateTimer?.invalidate()
        viewModel.stopMonitoring()

        if let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
            self.backgroundActivity = nil
        }

        if let observer = displayModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Set by the popover's Quit button, the only in-app way to really quit. / 中文：由弹窗的退出按钮设置，这是应用内唯一真正退出的途径。
    static var isQuitConfirmed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // While Settings is open the app shows in the Dock, and its Dock menu
        // Quit (or ⌘Q) would kill the fan controller. Treat those two as
        // "close the windows" and stay in the menu bar. The popover's Quit
        // button, logout / shutdown and scripted quits (Homebrew's
        // `uninstall quit:`) still terminate.
        // 中文：设置窗口打开时应用会出现在 Dock，Dock 菜单的「退出」（或 ⌘Q）会
        // 直接结束风扇控制。仅把这两种请求当作「关闭窗口」并留在菜单栏；弹窗的
        // 退出按钮、注销 / 关机以及脚本退出（Homebrew 的 `uninstall quit:`）照常退出。
        guard !Self.isQuitConfirmed, isQuitFromDockOrMenu() else {
            return .terminateNow
        }
        for window in NSApp.windows where isUserWindow(window) {
            window.close()
        }
        demoteToMenuBarIfWindowless(ignoring: nil)
        return .terminateCancel
    }

    private func isQuitFromDockOrMenu() -> Bool {
        // ⌘Q goes straight to terminate(_:) without an Apple Event.
        // 中文：⌘Q 直接调用 terminate(_:)，不经 Apple Event。
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return true }
        guard let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value else {
            return false
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    private func isUserWindow(_ window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled) else { return false }
        if window.isMiniaturized { return true }
        // A restored, empty SwiftUI Settings window can report itself visible
        // while it has no usable content. It must not keep the Dock icon alive.
        // 中文：空的 SwiftUI 设置窗口恢复后也可能报告可见；没有实际内容时不能阻止隐藏 Dock 图标。
        guard window.isVisible, let contentSize = window.contentView?.bounds.size else { return false }
        return contentSize.width > 0 && contentSize.height > 0
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A notification click can activate the app without opening or closing
        // a window. / 中文：通知点击可能只激活应用，不触发任何窗口开关事件。
        scheduleMenuBarPolicyUpdate()
    }

    private func scheduleMenuBarPolicyUpdate(ignoring closing: NSWindow? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.demoteToMenuBarIfWindowless(ignoring: closing)
        }
        // SwiftUI can promote the app later in the activation/close cycle.
        // Re-read all windows so newly reopened Settings remains in the Dock.
        // 中文：等 SwiftUI 生命周期稳定后再检查；重新读取窗口，保留期间重新打开的设置窗口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.demoteToMenuBarIfWindowless(ignoring: nil)
        }
    }

    private func demoteToMenuBarIfWindowless(ignoring closing: NSWindow?) {
        let hasOpenWindow = NSApp.windows.contains { $0 !== closing && isUserWindow($0) }
        if !hasOpenWindow, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func handleNotificationResponse(actionIdentifier: String, requestIdentifier: String) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              requestIdentifier.hasPrefix("high-temp-") else { return }
        demoteToMenuBarIfWindowless(ignoring: nil)
        statusBarManager.showPopover()
        scheduleMenuBarPolicyUpdate()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handleNotificationResponse(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier
        )
    }
}

// SwiftUI App entry point / 中文：SwiftUI 应用入口
@main
struct fanfanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettingsWindow = false
    
    var body: some Scene {
        // Keep a single settings scene. An empty Settings scene still creates
        // a titled window and can leave an invisible window holding the Dock icon.
        // 中文：只保留真正的设置场景；空 Settings 场景仍会创建带标题的窗口，导致无形窗口占用 Dock。
        Window(NSLocalizedString("app.settings_title", comment: ""), id: "settings") {
            SettingsWindowView(
                isOpen: $showSettingsWindow,
                viewModel: appDelegate.viewModel,
                updater: appDelegate.updater
            )
        }
        // Do not create Settings on launch or windowless reactivation; an
        // existing settings window may still be restored.
        // 中文：启动或无窗口激活时不新建设置窗口，仍允许恢复之前打开的真实设置窗口。
        .defaultLaunchBehavior(.suppressed)
        .commands { SettingsCommands() }
        .defaultWindowPlacement { content, context in
            let contentSize = content.sizeThatFits(.unspecified)
            let visibleSize = context.defaultDisplay.visibleRect.size
            let margin: CGFloat = 80

            let width = min(
                max(contentSize.width, SettingsWindowLayout.idealSize.width),
                max(SettingsWindowLayout.minSize.width, visibleSize.width - margin)
            )
            let height = min(
                max(contentSize.height, SettingsWindowLayout.idealSize.height),
                max(SettingsWindowLayout.minSize.height, visibleSize.height - margin)
            )

            return WindowPlacement(size: CGSize(width: width, height: height))
        }
    }
}

private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(NSLocalizedString("popover.settings", comment: "")) {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
