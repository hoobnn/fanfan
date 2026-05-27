//
//  File: fanfanApp.swift / 文件：fanfanApp.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Menu bar app lifecycle and settings scene entry point. / 描述：菜单栏应用生命周期和设置窗口入口。
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarManager: StatusBarManager?
    let viewModel = FanControlViewModel()
    private var iconUpdateTimer: Timer?
    private var displayModeObserver: NSObjectProtocol?
    /// Keeps App Nap from freezing our background timers. / 中文：阻止 App Nap 冻结后台定时器的活动凭证。
    private var backgroundActivity: NSObjectProtocol?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hide dock icon as early as possible to minimize the brief Dock flash
        // that occurs because LSUIElement is NO (so the app shows in Launchpad).
        // 中文：尽早隐藏 Dock 图标，减少因 LSUIElement=NO（为了出现在启动台）
        // 而在 Dock 里短暂闪现图标的时间。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Suppress App Nap. As an .accessory menu-bar app with no foreground
        // window, macOS otherwise freezes our monitoring/fan-control Timers when
        // the app sits in the background (e.g. lid closed). When that happens,
        // automatic scheduling silently stops on wake — even reapplySettings()'s
        // freshly created Timer gets frozen — until the user interacts with the
        // menu bar again. `userInitiatedAllowingIdleSystemSleep` keeps the timers
        // alive while still letting the system sleep normally (so closing the lid
        // still saves power).
        // 中文：抑制 App Nap。本应用是无前台窗口的 .accessory 菜单栏程序，否则
        // 合盖等后台场景下 macOS 会冻结我们的监控/风扇控制 Timer，导致唤醒后自动
        // 调度静默停止（连 reapplySettings() 新建的 Timer 也会被冻结），直到用户
        // 再次与菜单栏交互。userInitiatedAllowingIdleSystemSleep 既保持定时器运行，
        // 又允许系统正常睡眠（合盖依然省电）。
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Continuous fan monitoring and automatic speed control"
        )

        // Initialize components immediately / 中文：立即初始化组件
        setupApplication()
    }
    
    private func setupApplication() {
        
        // Initialize and setup status bar immediately / 中文：立即初始化并配置状态栏
        let statusBarManager = StatusBarManager()
        self.statusBarManager = statusBarManager
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
            guard let self = self,
                  let statusBarManager = self.statusBarManager else { return }
            
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
    
    private func startIconUpdateTimer() {
        iconUpdateTimer?.invalidate()
        iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateStatusBarIcon()
        }
        RunLoop.current.add(iconUpdateTimer!, forMode: .common)
        
        // Initial update / 中文：初始更新
        updateStatusBarIcon()
    }
    
    private func updateStatusBarIcon() {
        guard let statusBarManager = statusBarManager else { return }
        
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
        iconUpdateTimer?.invalidate()
        viewModel.stopMonitoring()

        if let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
            self.backgroundActivity = nil
        }

        if let observer = displayModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// SwiftUI App entry point / 中文：SwiftUI 应用入口
@main
struct fanfanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSettingsWindow = false
    
    var body: some Scene {
        // Use MenuBarExtra for macOS 13+ or Settings with empty content / 中文：在 macOS 13+ 使用 MenuBarExtra，或提供空内容的 Settings
        Settings {
            Text(NSLocalizedString("app.title", comment: ""))
                .frame(width: 0, height: 0)
                .hidden()
        }
        
        // Settings Window Scene / 中文：设置窗口场景
        Window(NSLocalizedString("app.settings_title", comment: ""), id: "settings") {
            SettingsWindowView(isOpen: $showSettingsWindow, viewModel: appDelegate.viewModel)
        }
        .keyboardShortcut(",", modifiers: .command)
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
