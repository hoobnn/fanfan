//
//  File: PopoverView.swift / 文件：PopoverView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Main menu bar popover. / 描述：主菜单栏弹出窗口。
//

import SwiftUI

struct PopoverView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject var permissions = PermissionsManager.shared
    @ObservedObject var battery = BatteryMonitor.shared

    var statusBarManager: StatusBarManager?

    @State private var showingQuitConfirm = false
    @State private var installError: String?
    @State private var selectedTab: Tab = .overview
    @State private var tempHistory: [Double] = []
    @State private var historyTimer: Timer?

    enum Tab: Hashable { case overview, sensors }

    /// Fanless Macs (e.g. MacBook Air) run as a plain temperature viewer — / 中文：无风扇 Mac (e.g. MacBook Air) run as a plain 温度 viewer —
    /// no fan blade, no controls. / 中文：no 风扇 blade, no 控制s.
    private var hasFans: Bool { viewModel.numberOfFans > 0 }

    var body: some View {
        let atmosphere = Theme.accent(for: viewModel.maxTemperature, scheme: scheme)
        return VStack(spacing: 0) {
            header

            content

            footer
        }
        .frame(width: 320)
        .frame(minHeight:   usesFixedHeight ? fixedPopoverHeight : nil,
               idealHeight: usesFixedHeight ? fixedPopoverHeight : nil,
               maxHeight:   usesFixedHeight ? fixedPopoverHeight : nil)
        .background(alignment: .top) {
            // No opaque fill: the popover's own Liquid Glass material is the
            // surface, the cards sit on it as the content layer.
            // 中文：不铺不透明底色：popover 自带的 Liquid Glass 材质就是底面，卡片作为内容层叠在上面。
            //
            // Temperature atmosphere — a barely-there wash bleeding down
            // from the top so the whole popover breathes the current heat.
            // Anchored to a fixed pixel height so tab-switching height
            // changes don't restretch the gradient behind the header.
            LinearGradient(
                    colors: [atmosphere.opacity(scheme == .dark ? 0.09 : 0.055),
                             .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 240)
                .ignoresSafeArea()
        }
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .alert(
            NSLocalizedString("popover.quit_confirm.title", comment: ""),
            isPresented: $showingQuitConfirm
        ) {
            Button(NSLocalizedString("popover.quit_confirm.cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("popover.quit_confirm.quit",   comment: ""), role: .destructive) { quit() }
        } message: {
            Text(NSLocalizedString("popover.quit_confirm.message", comment: ""))
        }
    }

    // MARK: - Header / 中文：头部

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(NSLocalizedString("popover.title", comment: ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)

                Spacer()

                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        headerButton(
                            systemImage: "gearshape",
                            title: NSLocalizedString("popover.settings", comment: "")
                        ) {
                            openWindow(id: "settings")
                        }
                        headerButton(
                            systemImage: "power",
                            title: NSLocalizedString("popover.quit_app", comment: "")
                        ) {
                            showingQuitConfirm = true
                        }
                    }
                }
            }
            // Indent title + buttons to sit on the same vertical baseline as
            // card content below (popover edge + 22pt). Negative trailing
            // padding pulls the close button back so its glyph reads as
            // anchored to the card-content right edge rather than floating
            // inside it.
            .padding(.leading, 12)
            .padding(.trailing, 8)

            if showsTabs {
                tabBar
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, showsTabs ? 8 : 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator(scheme))
                .frame(height: 0.5)
        }
    }

    // MARK: - Content / 中文：内容

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasAccess {
            PopoverMessageStateView(
                icon: "exclamationmark.triangle",
                title: NSLocalizedString("popover.system_access_required",   comment: ""),
                message: NSLocalizedString("popover.system_access_desc",     comment: "")
            )
        } else if viewModel.cpuTemperature == nil && viewModel.gpuTemperature == nil {
            PopoverMessageStateView(
                icon: "thermometer.medium.slash",
                title: NSLocalizedString("popover.no_temperature_data",       comment: ""),
                message: NSLocalizedString("popover.no_temperature_data_desc",comment: "")
            )
        } else {
            switch selectedTab {
            case .overview:
                // Overview grows to fit — no scroll, popover sizes to content. / 中文：概览按内容自适应增长，不滚动，弹出窗口随内容定尺寸。
                overviewTab
                    .padding(10)
            case .sensors:
                scrollableTabContent
            }
        }
    }

    @ViewBuilder
    private var scrollableTabContent: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch selectedTab {
                case .overview: overviewTab
                case .sensors:  sensorsTab
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    // MARK: - Tabs / 中文：标签页

    private var tabBar: some View {
        // Bare state change through the binding — wrapping it in
        // `withAnimation` animates the frame's height at the same time
        // NSPopover runs its own resize animation; the two run on different
        // curves and produce a visible "text drops down" jitter when
        // shrinking sensors → overview.
        // 中文：通过 binding 直接改状态——若包进 `withAnimation`，会与 NSPopover 自身的
        // 尺寸动画同时驱动高度，两条曲线不同步，从传感器切回概览时出现文字下坠抖动。
        Picker(NSLocalizedString("popover.tabs", comment: ""), selection: $selectedTab) {
            Text(NSLocalizedString("tab.overview", comment: "")).tag(Tab.overview)
            Text(NSLocalizedString("tab.sensors",  comment: "")).tag(Tab.sensors)
        }
        .labelsHidden()
        .tabsPickerStyle()
    }

    /// Icon-only header control. Glass buttons respond to the pointer on / 中文：仅图标的头部按钮。玻璃按钮在 macOS 27
    /// macOS 27; the title backs both the tooltip and VoiceOver. / 中文：上会跟随指针反馈；title 同时用作提示与 VoiceOver 标签。
    private func headerButton(systemImage: String,
                              title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - Overview / 中文：概览

    private var overviewTab: some View {
        VStack(spacing: 8) {
            HeroCard(metrics: heroMetrics, showsFan: hasFans)
            curveCard
            HStack(spacing: 5) {
                MicroMetricCard(label: "CPU", temp: viewModel.cpuTemperature,
                                help: NSLocalizedString("metric.hottest_core.help", comment: ""))
                MicroMetricCard(label: "GPU", temp: viewModel.gpuTemperature,
                                help: NSLocalizedString("metric.hottest_core.help", comment: ""))
                MicroMetricCard(label: "SSD", temp: ssdTemp)
                MicroMetricCard(label: NSLocalizedString("metric.battery", comment: ""),
                                temp: batteryTemp)
            }
            if hasFans {
                // `EquatableView`-style dedup: ControlsCard re-evaluates only / 中文：`EquatableView` 风格的去重：仅当
                // when something it actually depends on changes, not on every / 中文：snapshot 真正变化时 ControlsCard 才重算 body，
                // unrelated `@Published` tick from the view-model. / 中文：与 view-model 上无关的 `@Published` 触发无关。
                if permissions.isHelperInstalled {
                    ControlsCard(snapshot: controlsSnapshot, viewModel: viewModel)
                        .equatable()
                } else {
                    InstallHelperStateView(
                        installError: installError,
                        isInstalling: permissions.isInstalling,
                        needsApproval: permissions.needsApproval,
                        installHelper: installHelper
                    )
                }
            }
        }
    }

    // MARK: - Sensors / 中文：传感器

    private var sensorsTab: some View {
        SensorListView(sections: viewModel.sensorSections)
    }

    // MARK: - Curve card / 中文：曲线卡片

    private var curveCard: some View {
        let maxTemperature = viewModel.maxTemperature
        let accent = Theme.accent(for: maxTemperature, scheme: scheme)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(NSLocalizedString("curve.title", comment: ""))
                    .font(Theme.label(10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text(String(format: "%.0f°", maxTemperature))
                    .font(Theme.num(11.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
            }
            TempCurveView(samples: tempHistory, accent: accent)
                .frame(height: 38)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedCard(scheme)
    }

    // MARK: - Footer / 中文：页脚

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.launchAtLogin },
                set: { newValue in
                    viewModel.launchAtLogin = newValue
                    LaunchAtLoginManager.shared.isEnabled = newValue
                }
            )) {
                Text(NSLocalizedString("popover.startup_help", comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            Text(version)
                .font(Theme.num(10, weight: .medium))
                .foregroundStyle(Theme.text3)
        }
        // Align with the card-content baseline (22pt) so the footer reads
        // as belonging to the content column rather than floating between
        // the popover edge and the cards.
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator(scheme)).frame(height: 0.5)
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(v ?? "1.0")"
    }

    // MARK: - Derived / 中文：派生值

    private var showsTabs: Bool {
        viewModel.hasAccess && (viewModel.cpuTemperature != nil || viewModel.gpuTemperature != nil)
    }

    /// Fixed popover height for the scrollable Sensors tab and the / 中文：Fixed 弹出窗口 height for the scrollable 传感器s tab and the
    /// install/permission state screens. The Overview tab is excluded — it / 中文：安装/权限状态页面。概览页签除外，因为它
    /// grows to fit its content so the popover sizes dynamically. / 中文：g行s to fit its content so the 弹出窗口 sizes dynamically.
    private var usesFixedHeight: Bool {
        !showsTabs || selectedTab != .overview
    }

    private var fixedPopoverHeight: CGFloat { 640 }

    private var ssdTemp: Double? { viewModel.ssdTemperature }

    private var batteryTemp: Double? {
        if let t = viewModel.batterySensorTemperature { return t }
        if let t = battery.batteryInfo.temperature, t > 0 { return t.rounded() }
        return nil
    }

    private var heroMetrics: HeroCardMetrics {
        HeroCardMetrics(
            maxTemperature: viewModel.maxTemperature,
            currentFanSpeed: viewModel.currentFanSpeed,
            minRPM: viewModel.effectiveUnifiedMinRPM,
            maxRPM: viewModel.effectiveUnifiedMaxRPM,
            hasBattery: battery.hasBattery,
            batteryPowerWatts: battery.batteryInfo.powerWatts,
            batteryPercentage: battery.batteryInfo.percentage
        )
    }

    private var controlsSnapshot: ControlsSnapshot {
        ControlsSnapshot(
            controlMode: viewModel.controlMode,
            numberOfFans: viewModel.numberOfFans,
            autoThreshold: viewModel.autoThreshold,
            autoMaxSpeed: viewModel.autoMaxSpeed,
            autoAggressiveness: viewModel.autoAggressiveness,
            powerStrategy: viewModel.powerStrategy,
            perFanManualControl: viewModel.perFanManualControl,
            manualSpeed: viewModel.manualSpeed,
            manualSpeeds: viewModel.manualSpeeds,
            fanMinSpeeds: viewModel.fanMinSpeeds,
            fanMaxSpeeds: viewModel.fanMaxSpeeds,
            unifiedMinRPM: viewModel.effectiveUnifiedMinRPM,
            unifiedMaxRPM: viewModel.effectiveUnifiedMaxRPM,
            statusMessage: viewModel.statusMessage,
            applyDidFail: viewModel.applyDidFail
        )
    }

    // MARK: - Lifecycle / 中文：生命周期

    private func onAppear() {
        permissions.checkInstallation()
        if !viewModel.isMonitoring {
            viewModel.startMonitoring()
        }
        // `BatteryMonitor` already runs app-wide (started in `fanfanApp`) so the / 中文：`BatteryMonitor` 已由 app 全程运行（在 `fanfanApp` 启动），
        // auto-mode load feedforward always has live wattage. This call is / 中文：使自动模式负载前馈始终有实时功率。此调用幂等，
        // idempotent — it just refreshes once immediately on open. / 中文：仅在打开时立即刷新一次。
        battery.startMonitoring()
        // Resume the full sensor scan only now that its data is on screen. / 中文：现在数据可见了才恢复全传感器扫描。
        viewModel.setSensorScanActive(true)
        startHistoryTimer()
    }

    private func onDisappear() {
        // Do NOT stop `BatteryMonitor` here: it is an app-wide singleton feeding / 中文：这里不要停 `BatteryMonitor`：它是 app 级单例，
        // the auto-mode load feedforward whether or not the popover is open. / 中文：无论 popover 是否打开都为自动模式负载前馈供数。
        // Stopping it on close used to leave auto control without live wattage / 中文：之前关闭时停掉它，会让自动控制在重新打开 popover 前
        // until the popover was reopened. / 中文：一直拿不到实时功率。
        //
        // Stop the ~30-IOKit-round-trip sensor scan while hidden; the fast / 中文：隐藏期间停掉约 30 次 IOKit 往返的传感器扫描；
        // tier (temps + fan RPM) keeps feeding the icon and auto control. / 中文：快档（温度 + 风扇转速）继续供菜单栏图标与自动控制。
        viewModel.setSensorScanActive(false)
        historyTimer?.invalidate()
        historyTimer = nil
    }

    private func startHistoryTimer() {
        historyTimer?.invalidate()
        let seed = viewModel.maxTemperature
        tempHistory = Array(repeating: max(40, seed), count: 60)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let t = viewModel.maxTemperature
                guard t > 0 else { return }
                tempHistory.append(t)
                if tempHistory.count > 60 {
                    tempHistory.removeFirst(tempHistory.count - 60)
                }
            }
        }
        // Chart sampling at 1 Hz; ±0.2 s jitter is invisible in a 60 s window. / 中文：曲线按 1 Hz 采样；60 秒窗口里 ±0.2 秒抖动不可见。
        timer.tolerance = 0.2
        // `.common` keeps sampling alive while the run loop is in event-tracking
        // mode. Without it, dragging a slider or scrolling the sensor list froze
        // the curve and dropped every sample taken during the gesture.
        RunLoop.current.add(timer, forMode: .common)
        historyTimer = timer
    }

    private func installHelper() {
        guard !permissions.isInstalling else { return }
        installError = nil
        permissions.installHelper { success, error in
            if !success {
                installError = error ?? NSLocalizedString("popover.install_failed", comment: "")
            }
        }
    }

    private func quit() {
        viewModel.resetToSystemControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AppDelegate.isQuitConfirmed = true
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - State views / 中文：状态视图

private struct InstallHelperStateView: View {
    let installError: String?
    let isInstalling: Bool
    let needsApproval: Bool
    let installHelper: () -> Void

    @Environment(\.colorScheme) private var scheme

    // Hand-laid rather than `ContentUnavailableView`: that view wraps itself / 中文：不用 `ContentUnavailableView`：它内部自带滚动视图，
    // in a scroll view, which collapses inside the fit-to-content Overview. / 中文：在按内容自适应高度的概览页里会被压扁。
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.bottom, 2)

            Text(NSLocalizedString("popover.helper_required", comment: ""))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)

            Text(NSLocalizedString(
                needsApproval ? "popover.helper_approval_desc" : "popover.helper_required_desc",
                comment: ""
            ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            if let err = installError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger(scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            // The one primary action on the page, so the only tinted control. / 中文：本页唯一的主操作，也是唯一着色的控件。
            Button(action: installHelper) {
                Group {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(NSLocalizedString(
                            needsApproval ? "popover.open_login_items" : "popover.install_helper",
                            comment: ""
                        ))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isInstalling)
            .padding(.horizontal, 30)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .themedCard(scheme)
    }
}

private struct PopoverMessageStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PopoverView(viewModel: FanControlViewModel())
}
