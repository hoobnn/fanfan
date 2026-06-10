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
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(Theme.bgPrimary(scheme))
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
            }
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
                    .foregroundColor(Theme.text1(scheme))

                Spacer()

                Button {
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text3(scheme))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    showingQuitConfirm = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.text3(scheme))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Indent title + buttons to sit on the same vertical baseline as
            // card content below (popover edge + 22pt). Negative trailing
            // padding pulls the close button back so its glyph reads as
            // anchored to the card-content right edge rather than floating
            // inside it.
            .padding(.leading, 12)
            .padding(.trailing, 6)

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
        if !permissions.isHelperInstalled {
            InstallHelperStateView(
                installError: installError,
                installHelper: installHelper
            )
        } else if !viewModel.hasAccess {
            PopoverMessageStateView(
                icon: "exclamationmark.triangle",
                title: NSLocalizedString("popover.system_access_required",   comment: ""),
                message: NSLocalizedString("popover.system_access_desc",     comment: "")
            )
        } else if viewModel.cpuTemperature == nil {
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
        HStack(spacing: 3) {
            tabButton(.overview, NSLocalizedString("tab.overview", comment: ""))
            tabButton(.sensors,  NSLocalizedString("tab.sensors",  comment: ""))
        }
        .padding(2)
        .background(Theme.fill2(scheme), in: Capsule())
    }

    private func tabButton(_ tab: Tab, _ label: String) -> some View {
        Button {
            // Bare state change — wrapping in `withAnimation` animates the
            // frame's height (and any other selectedTab-derived layout) at
            // the same time NSPopover runs its own resize animation; the two
            // run on different curves and produce a visible "text drops down"
            // jitter when shrinking sensors → overview. Letting NSPopover own
            // the resize and only animating the tab indicator removes it.
            selectedTab = tab
        } label: {
            let selected = selectedTab == tab
            Text(label)
                .font(.system(size: 11,
                              weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? Theme.text1(scheme) : Theme.text3(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background {
                    // Animation scoped to the capsule only. SwiftUI can't
                    // tween font weights, it cross-fades snapshots whose
                    // metrics differ slightly — animating the text alongside
                    // produced a visible vertical jiggle on both labels.
                    ZStack {
                        if selected {
                            Capsule()
                                .fill(Theme.cardBg(scheme))
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Theme.cardStroke(scheme), lineWidth: 0.6)
                                }
                        }
                    }
                    .animation(.easeInOut(duration: 0.14), value: selectedTab)
                }
                .contentShape(Capsule())
            }
        .buttonStyle(.plain)
    }

    // MARK: - Overview / 中文：概览

    private var overviewTab: some View {
        VStack(spacing: 8) {
            HeroCard(metrics: heroMetrics, showsFan: hasFans)
            curveCard
            HStack(spacing: 5) {
                MicroMetricCard(label: "CPU", temp: viewModel.cpuTemperature)
                MicroMetricCard(label: "GPU", temp: viewModel.gpuTemperature)
                MicroMetricCard(label: "SSD", temp: ssdTemp)
                MicroMetricCard(label: NSLocalizedString("metric.battery", comment: ""),
                                temp: batteryTemp)
            }
            if hasFans {
                // `EquatableView`-style dedup: ControlsCard re-evaluates only / 中文：`EquatableView` 风格的去重：仅当
                // when something it actually depends on changes, not on every / 中文：snapshot 真正变化时 ControlsCard 才重算 body，
                // unrelated `@Published` tick from the view-model. / 中文：与 view-model 上无关的 `@Published` 触发无关。
                ControlsCard(snapshot: controlsSnapshot, viewModel: viewModel)
                    .equatable()
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
                    .foregroundColor(Theme.text3(scheme))
                Spacer()
                Text(String(format: "%.1f°", maxTemperature))
                    .font(Theme.num(11.5, weight: .semibold))
                    .foregroundColor(Theme.text1(scheme))
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
                Text(NSLocalizedString("popover.startup", comment: ""))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text2(scheme))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            Text(version)
                .font(Theme.num(10, weight: .medium))
                .foregroundColor(Theme.text3(scheme))
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
        permissions.isHelperInstalled && viewModel.hasAccess && viewModel.cpuTemperature != nil
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
        if let t = battery.batteryInfo.temperature, t > 0 { return t }
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
            unifiedMaxRPM: viewModel.effectiveUnifiedMaxRPM
        )
    }

    // MARK: - Lifecycle / 中文：生命周期

    private func onAppear() {
        permissions.checkInstallation()
        if viewModel.hasAccess && !viewModel.isMonitoring {
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
        historyTimer = timer
    }

    private func installHelper() {
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
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - State views / 中文：状态视图

private struct InstallHelperStateView: View {
    let installError: String?
    let installHelper: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Theme.text2(scheme))
                .padding(.bottom, 3)

            Text(NSLocalizedString("popover.helper_required", comment: ""))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.text1(scheme))

            Text(NSLocalizedString("popover.helper_required_desc", comment: ""))
                .font(.system(size: 11))
                .foregroundColor(Theme.text2(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if let err = installError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.danger(scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Button(action: installHelper) {
                Text(NSLocalizedString("popover.install_helper", comment: ""))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Theme.text1(scheme).opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: Theme.cardShadow(scheme), radius: 5, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 30)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 26)
    }
}

private struct PopoverMessageStateView: View {
    let icon: String
    let title: String
    let message: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Theme.text2(scheme))
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.text1(scheme))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.text2(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 26)
    }
}

#Preview {
    PopoverView(viewModel: FanControlViewModel())
}
