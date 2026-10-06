//
//  File: SettingsView.swift / 文件：SettingsView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Settings window UI. / 描述：设置窗口界面。
//

import AppKit
import SwiftUI

enum StatusBarDisplayMode: String, CaseIterable {
    case none
    case temperature
    case power
    case fanSpeedPercentage
}

enum SettingsWindowLayout {
    static let minSize = CGSize(width: 420, height: 500)
    static let idealSize = CGSize(width: 456, height: 520)
    static let maxSize = CGSize(width: 560, height: 620)
}

// MARK: - Settings / 中文：设置

struct SettingsView: View {
    @ObservedObject var viewModel: FanControlViewModel

    @AppStorage("launchAtLogin")          private var launchAtLogin = false
    @AppStorage("statusBarDisplayMode")   private var statusBarDisplayMode = "temperature"
    @AppStorage("monitoringInterval")     private var monitoringInterval = 2.0
    @AppStorage("enableNotifications")    private var enableNotifications = true
    @AppStorage("highTempAlert")          private var highTempAlert = 85.0
    @AppStorage("autoSwitchMode")         private var autoSwitchMode = false

    @StateObject private var updateChecker = UpdateChecker()
    @State private var editingStrategy: PowerStrategy = .balanced

    private var availableRelease: UpdateChecker.Release? {
        if case .available(let r) = updateChecker.state { return r }
        return nil
    }

    var body: some View {
        // Native grouped form: the macOS 26 inset-group look, row separators, / 中文：原生分组表单：macOS 26 的内嵌分组外观、行分隔线、
        // scroll-edge effect and inactive-window dimming all come from the / 中文：滚动边缘效果与非活跃窗口变暗都由系统提供，
        // system, and follow later releases (macOS 27) without code changes. / 中文：后续系统（macOS 27）的样式更新无需改代码即可跟随。
        Form {
            menuBarSection
            monitoringSection
            strategyPresetsSection
            pidAdvancedSection
            generalSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: SettingsWindowLayout.minSize.width,
               idealWidth: SettingsWindowLayout.idealSize.width,
               maxWidth: SettingsWindowLayout.maxSize.width,
               minHeight: SettingsWindowLayout.minSize.height,
               idealHeight: SettingsWindowLayout.idealSize.height,
               maxHeight: SettingsWindowLayout.maxSize.height)
        .alert(
            NSLocalizedString("update.alert.title", comment: ""),
            isPresented: Binding(
                get: { availableRelease != nil },
                set: { if !$0 { updateChecker.dismissAvailable() } }
            ),
            presenting: availableRelease,
            actions: { release in
                Button(NSLocalizedString("update.alert.download", comment: "")) {
                    NSWorkspace.shared.open(release.htmlURL)
                }
                Button(NSLocalizedString("update.alert.later", comment: ""), role: .cancel) {}
            },
            message: { release in
                Text(updateAlertMessage(for: release))
            }
        )
    }

    // MARK: - Sections / 中文：分区

    private var menuBarSection: some View {
        Section(NSLocalizedString("settings.section.menu_bar", comment: "")) {
            Picker(selection: $statusBarDisplayMode) {
                Text(NSLocalizedString("settings.display_mode.none",        comment: "")).tag("none")
                Text(NSLocalizedString("settings.display_mode.temperature", comment: "")).tag("temperature")
                Text(NSLocalizedString("settings.display_mode.power",       comment: "")).tag("power")
                Text(NSLocalizedString("settings.display_mode.fan_speed",   comment: "")).tag("fanSpeedPercentage")
            } label: {
                rowLabel("settings.menu_bar_display")
            }
            .onChange(of: statusBarDisplayMode) { _, newValue in
                viewModel.statusBarDisplayMode = newValue
                NotificationCenter.default.post(
                    name: NSNotification.Name("StatusBarDisplayModeChanged"),
                    object: newValue
                )
            }
        }
    }

    private var monitoringSection: some View {
        Section(NSLocalizedString("settings.section.monitoring", comment: "")) {
            LabeledContent {
                InlineSlider(value: $monitoringInterval, range: 0.5...5.0, step: 0.5,
                             format: { String(format: "%.1fs", $0) },
                             showsTicks: true)
                    .onChange(of: monitoringInterval) { _, newValue in
                        viewModel.setMonitoringInterval(newValue)
                    }
            } label: {
                rowLabel("settings.monitoring_interval")
            }

            LabeledContent {
                InlineSlider(value: $highTempAlert, range: 70...95, step: 1,
                             format: { String(format: "%.0f°C", $0) },
                             accent: .thermal)
                    .onChange(of: highTempAlert) { _, newValue in
                        viewModel.highTempAlert = newValue
                    }
            } label: {
                rowLabel("settings.high_temp_alert")
            }

            Toggle(isOn: $enableNotifications) {
                rowLabel("settings.notifications")
            }
            .onChange(of: enableNotifications) { _, newValue in
                viewModel.enableNotifications = newValue
            }

            Toggle(isOn: $autoSwitchMode) {
                rowLabel("settings.auto_mode_switching")
            }
            .onChange(of: autoSwitchMode) { _, newValue in
                viewModel.autoSwitchMode = newValue
            }
        }
    }

    // MARK: - Strategy presets / 中文：策略预设

    private var editingPreset: StrategyPreset {
        viewModel.preset(for: editingStrategy) ?? StrategyPreset(targetTemp: 60, aggressiveness: 1.5, maxSpeedFraction: 0.65)
    }

    /// Writes one field of the preset being edited. / 中文：写入正在编辑的预设中的单个字段。
    private func presetBinding(_ keyPath: WritableKeyPath<StrategyPreset, Double>) -> Binding<Double> {
        Binding(
            get: { editingPreset[keyPath: keyPath] },
            set: { newValue in
                var preset = editingPreset
                preset[keyPath: keyPath] = newValue
                viewModel.setStrategyPreset(preset, for: editingStrategy)
            }
        )
    }

    private var strategyPresetsSection: some View {
        Section(NSLocalizedString("settings.section.strategy_presets", comment: "")) {
            Picker(selection: $editingStrategy) {
                ForEach(PowerStrategy.named, id: \.self) { strategy in
                    Text(strategyName(strategy)).tag(strategy)
                }
            } label: {
                rowLabel("settings.strategy_preset")
            }
            .pickerStyle(.segmented)

            LabeledContent {
                InlineSlider(value: presetBinding(\.targetTemp),
                             range: StrategyPreset.targetTempRange, step: 1,
                             format: { String(format: "%.0f°C", $0) },
                             accent: .thermal,
                             valueWidth: 64)
            } label: {
                rowLabel("settings.strategy_preset_target")
            }

            LabeledContent {
                InlineSlider(value: presetBinding(\.maxSpeedFraction),
                             range: StrategyPreset.maxSpeedFractionRange, step: 0.05,
                             format: { String(format: "%.0f%%", $0 * 100) },
                             valueWidth: 64)
            } label: {
                rowLabel("settings.strategy_preset_max_speed")
            }

            LabeledContent {
                InlineSlider(
                    value: Binding(
                        get: { Double(ResponseScale.index(for: editingPreset.aggressiveness)) },
                        set: { presetBinding(\.aggressiveness).wrappedValue = ResponseScale.step($0) }
                    ),
                    range: ResponseScale.sliderRange, step: 1,
                    format: { ResponseScale.label(for: ResponseScale.step($0)) },
                    showsTicks: true,
                    valueWidth: 64
                )
            } label: {
                rowLabel("settings.strategy_preset_response")
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("settings.strategy_preset_reset", comment: "")) {
                    viewModel.resetStrategyPreset(for: editingStrategy)
                }
                .disabled(viewModel.strategyPresetOverrides[editingStrategy] == nil)
            }
        }
    }

    private func strategyName(_ strategy: PowerStrategy) -> String {
        switch strategy {
        case .powerSaving: return NSLocalizedString("popover.strategy.power_saving", comment: "")
        case .balanced:    return NSLocalizedString("popover.strategy.balanced", comment: "")
        case .performance: return NSLocalizedString("popover.strategy.performance", comment: "")
        case .custom:      return NSLocalizedString("settings.strategy_custom", comment: "")
        }
    }

    // MARK: - PID Advanced Tuning / 中文：PID 高级调节

    private var useCustomPIDBinding: Binding<Bool> {
        Binding(
            get: { isCustomPID },
            set: { newVal in
                if newVal {
                    viewModel.setPIDGains(
                        kp: viewModel.effectivePIDKp,
                        ki: viewModel.effectivePIDKi,
                        kd: viewModel.effectivePIDKd
                    )
                } else {
                    viewModel.setPIDGains(kp: nil, ki: nil, kd: nil)
                }
            }
        )
    }

    private var isCustomPID: Bool {
        viewModel.pidKpCustom != nil
            || viewModel.pidKiCustom != nil
            || viewModel.pidKdCustom != nil
    }

    /// Progressive disclosure: the gain sliders only appear once custom / 中文：渐进披露：打开自定义增益后才显示增益滑杆，
    /// gains are switched on, instead of showing three disabled rows. / 中文：而不是摆出三行禁用的控件。
    private var pidAdvancedSection: some View {
        Section(NSLocalizedString("settings.section.advanced_pid", comment: "")) {
            Toggle(isOn: useCustomPIDBinding.animation(.snappy)) {
                rowLabel("settings.pid_override")
            }

            if isCustomPID {
                LabeledContent {
                    InlineSlider(
                        value: Binding(
                            get: { viewModel.pidKpCustom ?? viewModel.effectivePIDKp },
                            set: { newVal in
                                viewModel.setPIDGains(
                                    kp: newVal,
                                    ki: viewModel.pidKiCustom ?? viewModel.effectivePIDKi,
                                    kd: viewModel.pidKdCustom ?? viewModel.effectivePIDKd
                                )
                            }
                        ),
                        range: 0...2000, step: 10,
                        format: { String(format: "%.0f", $0) }
                    )
                } label: {
                    rowLabel("settings.pid_kp")
                }

                LabeledContent {
                    InlineSlider(
                        value: Binding(
                            get: { viewModel.pidKiCustom ?? viewModel.effectivePIDKi },
                            set: { newVal in
                                viewModel.setPIDGains(
                                    kp: viewModel.pidKpCustom ?? viewModel.effectivePIDKp,
                                    ki: newVal,
                                    kd: viewModel.pidKdCustom ?? viewModel.effectivePIDKd
                                )
                            }
                        ),
                        range: 0...100, step: 0.5,
                        format: { String(format: "%.1f", $0) }
                    )
                } label: {
                    rowLabel("settings.pid_ki")
                }

                LabeledContent {
                    InlineSlider(
                        value: Binding(
                            get: { viewModel.pidKdCustom ?? viewModel.effectivePIDKd },
                            set: { newVal in
                                viewModel.setPIDGains(
                                    kp: viewModel.pidKpCustom ?? viewModel.effectivePIDKp,
                                    ki: viewModel.pidKiCustom ?? viewModel.effectivePIDKi,
                                    kd: newVal
                                )
                            }
                        ),
                        range: 0...5000, step: 50,
                        format: { String(format: "%.0f", $0) }
                    )
                } label: {
                    rowLabel("settings.pid_kd")
                }

                HStack {
                    Spacer()
                    Button(NSLocalizedString("settings.pid_reset", comment: "")) {
                        withAnimation(.snappy) {
                            viewModel.setPIDGains(kp: nil, ki: nil, kd: nil)
                        }
                    }
                }
            }
        }
    }

    private var generalSection: some View {
        Section(NSLocalizedString("settings.section.general", comment: "")) {
            Toggle(isOn: $launchAtLogin) {
                rowLabel("settings.launch_at_login")
            }
            .onChange(of: launchAtLogin) { _, newValue in
                viewModel.launchAtLogin = newValue
                LaunchAtLoginManager.shared.isEnabled = newValue
            }
        }
    }

    // MARK: - About / 中文：关于

    private var aboutSection: some View {
        Section(NSLocalizedString("settings.section.about", comment: "")) {
            LabeledContent {
                Text(versionDisplay)
                    .font(Theme.num(12, weight: .medium))
                    .textSelection(.enabled)
            } label: {
                rowLabel("settings.version")
            }

            LabeledContent {
                Button(action: { Task { await updateChecker.check() } }) {
                    if updateChecker.state == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(NSLocalizedString("settings.check_updates.button", comment: ""))
                    }
                }
                .disabled(updateChecker.state == .checking)
            } label: {
                Text(NSLocalizedString("settings.check_updates", comment: ""))
                Text(checkUpdatesDescription)
            }
        }
    }

    /// Title plus secondary description; `Form` renders the second `Text` / 中文：标题加次要说明；`Form` 会把第二个 `Text`
    /// as the row's subtitle. / 中文：渲染为该行的副标题。
    @ViewBuilder
    private func rowLabel(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: ""))
        Text(NSLocalizedString(key + "_desc", comment: ""))
    }

    private var versionDisplay: String {
        let v = updateChecker.currentVersion
        let b = updateChecker.currentBuild
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    private var checkUpdatesDescription: String {
        switch updateChecker.state {
        case .checking:
            return NSLocalizedString("settings.check_updates.checking", comment: "")
        case .upToDate:
            return NSLocalizedString("settings.check_updates.up_to_date", comment: "")
        case .failed(let msg):
            return String(format: NSLocalizedString("settings.check_updates.failed_format", comment: ""), msg)
        case .idle, .available:
            return NSLocalizedString("settings.check_updates_desc", comment: "")
        }
    }

    private func updateAlertMessage(for release: UpdateChecker.Release) -> String {
        let header = String(
            format: NSLocalizedString("update.alert.message_header_format", comment: ""),
            release.version,
            updateChecker.currentVersion
        )
        let trimmed = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return header }
        let capped = trimmed.count > 700 ? String(trimmed.prefix(700)) + "…" : trimmed
        return "\(header)\n\n\(capped)"
    }

}

// MARK: - Dedicated Settings Window / 中文：独立设置窗口

struct SettingsWindowView: View {
    @Binding var isOpen: Bool
    let viewModel: FanControlViewModel

    var body: some View {
        SettingsView(viewModel: viewModel)
            .onAppear {
                if let window = NSApplication.shared.windows.first(where: {
                    $0.title == NSLocalizedString("app.settings_title", comment: "")
                }) {
                    window.standardWindowButton(.closeButton)?.isHidden = false
                    // `.floating` is only a way to surface the window from an
                    // accessory-policy app; leaving it set pinned Settings above
                    // every other application for the rest of the session, with
                    // no way for the user to send it behind anything.
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        window.level = .normal
                    }
                }
            }
    }
}

// MARK: - Controls / 中文：控件

private struct InlineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var accent: SliderAccent = .neutral
    var showsTicks: Bool = false
    var valueWidth: CGFloat = 48

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            SnappingSlider(value: $value, range: range, step: step, showsTicks: showsTicks)
                .tint(sliderTint)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(Theme.num(12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .frame(width: 132 + valueWidth)
    }

    private var sliderTint: Color {
        switch accent {
        case .thermal: return Theme.thermalColor(forTemperature: value, scheme: scheme)
        case .neutral: return Theme.sliderTint(scheme)
        }
    }
}
