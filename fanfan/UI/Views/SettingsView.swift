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
    @Environment(\.colorScheme) private var scheme

    @AppStorage("launchAtLogin")          private var launchAtLogin = false
    @AppStorage("statusBarDisplayMode")   private var statusBarDisplayMode = "temperature"
    @AppStorage("monitoringInterval")     private var monitoringInterval = 2.0
    @AppStorage("enableNotifications")    private var enableNotifications = true
    @AppStorage("highTempAlert")          private var highTempAlert = 85.0
    @AppStorage("autoSwitchMode")         private var autoSwitchMode = false

    @StateObject private var updateChecker = UpdateChecker()

    private var availableRelease: UpdateChecker.Release? {
        if case .available(let r) = updateChecker.state { return r }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                menuBarSection
                monitoringSection
                pidAdvancedSection
                generalSection
                aboutSection
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: SettingsWindowLayout.minSize.width,
               idealWidth: SettingsWindowLayout.idealSize.width,
               maxWidth: SettingsWindowLayout.maxSize.width,
               minHeight: SettingsWindowLayout.minSize.height,
               idealHeight: SettingsWindowLayout.idealSize.height,
               maxHeight: SettingsWindowLayout.maxSize.height)
        .background(Theme.bgPrimary(scheme))
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
        SettingsSection(NSLocalizedString("settings.section.menu_bar", comment: ""), scheme: scheme) {
            VStack(alignment: .leading, spacing: 9) {
                SettingRowLabel(
                    icon: "menubar.rectangle",
                    title: NSLocalizedString("settings.menu_bar_display", comment: ""),
                    desc: NSLocalizedString("settings.menu_bar_display_desc", comment: ""),
                    scheme: scheme
                )

                Picker("", selection: $statusBarDisplayMode) {
                    Text(NSLocalizedString("settings.display_mode.none",        comment: "")).tag("none")
                    Text(NSLocalizedString("settings.display_mode.temperature", comment: "")).tag("temperature")
                    Text(NSLocalizedString("settings.display_mode.power",       comment: "")).tag("power")
                    Text(NSLocalizedString("settings.display_mode.fan_speed",   comment: "")).tag("fanSpeedPercentage")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: statusBarDisplayMode) { _, newValue in
                    viewModel.statusBarDisplayMode = newValue
                    NotificationCenter.default.post(
                        name: NSNotification.Name("StatusBarDisplayModeChanged"),
                        object: newValue
                    )
                }
            }
            .padding(12)
        }
    }

    private var monitoringSection: some View {
        SettingsSection(NSLocalizedString("settings.section.monitoring", comment: ""), scheme: scheme) {
            VStack(spacing: 0) {
                SettingRow(
                    icon: "timer",
                    title: NSLocalizedString("settings.monitoring_interval", comment: ""),
                    desc: NSLocalizedString("settings.monitoring_interval_desc", comment: ""),
                    scheme: scheme
                ) {
                    InlineSlider(value: $monitoringInterval, range: 0.5...5.0, step: 0.5,
                                 format: { String(format: "%.1fs", $0) })
                    .frame(width: 152)
                    .onChange(of: monitoringInterval) { _, newValue in
                        viewModel.setMonitoringInterval(newValue)
                    }
                }

                rowDivider

                SettingRow(
                    icon: "exclamationmark.triangle",
                    title: NSLocalizedString("settings.high_temp_alert", comment: ""),
                    desc: NSLocalizedString("settings.high_temp_alert_desc", comment: ""),
                    scheme: scheme
                ) {
                    InlineSlider(value: $highTempAlert, range: 70...95, step: 1,
                                 format: { String(format: "%.0f°C", $0) },
                                 accent: .thermal)
                    .frame(width: 152)
                    .onChange(of: highTempAlert) { _, newValue in
                        viewModel.highTempAlert = newValue
                    }
                }

                rowDivider

                SettingRow(
                    icon: "bell",
                    title: NSLocalizedString("settings.notifications", comment: ""),
                    desc: NSLocalizedString("settings.notifications_desc", comment: ""),
                    scheme: scheme
                ) {
                    Toggle("", isOn: $enableNotifications)
                        .labelsHidden()
                        .onChange(of: enableNotifications) { _, newValue in
                            viewModel.enableNotifications = newValue
                        }
                }

                rowDivider

                SettingRow(
                    icon: "bolt",
                    title: NSLocalizedString("settings.auto_mode_switching", comment: ""),
                    desc: NSLocalizedString("settings.auto_mode_switching_desc", comment: ""),
                    scheme: scheme
                ) {
                    Toggle("", isOn: $autoSwitchMode)
                        .labelsHidden()
                        .onChange(of: autoSwitchMode) { _, newValue in
                            viewModel.autoSwitchMode = newValue
                        }
                }
            }
        }
    }

    // MARK: - PID Advanced Tuning / 中文：PID 高级调节

    @State private var pidExpanded: Bool = false

    private var useCustomPIDBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pidKpCustom != nil
                || viewModel.pidKiCustom != nil
                || viewModel.pidKdCustom != nil },
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

    private func pidGainBinding(
        get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(get: get, set: set)
    }

    private var pidAdvancedSection: some View {
        SettingsSection(NSLocalizedString("settings.section.advanced_pid", comment: ""), scheme: scheme) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SettingIcon(icon: "slider.horizontal.3", scheme: scheme)
                    Text(NSLocalizedString("settings.pid_override", comment: ""))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.text1(scheme))
                    Spacer()
                    Image(systemName: pidExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.text3(scheme))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { pidExpanded.toggle() } }

                if pidExpanded {
                    rowDivider

                    SettingRow(
                        icon: "switch.2",
                        title: NSLocalizedString("settings.pid_override", comment: ""),
                        desc: NSLocalizedString("settings.pid_override_desc", comment: ""),
                        scheme: scheme
                    ) {
                        Toggle("", isOn: useCustomPIDBinding).labelsHidden()
                    }

                    let custom = viewModel.pidKpCustom != nil
                        || viewModel.pidKiCustom != nil
                        || viewModel.pidKdCustom != nil

                    rowDivider
                    SettingRow(
                        icon: "p.circle",
                        title: NSLocalizedString("settings.pid_kp", comment: ""),
                        desc: NSLocalizedString("settings.pid_kp_desc", comment: ""),
                        scheme: scheme
                    ) {
                        InlineSlider(
                            value: pidGainBinding(
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
                        .frame(width: 152)
                        .disabled(!custom)
                        .opacity(custom ? 1 : 0.5)
                    }

                    rowDivider
                    SettingRow(
                        icon: "i.circle",
                        title: NSLocalizedString("settings.pid_ki", comment: ""),
                        desc: NSLocalizedString("settings.pid_ki_desc", comment: ""),
                        scheme: scheme
                    ) {
                        InlineSlider(
                            value: pidGainBinding(
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
                        .frame(width: 152)
                        .disabled(!custom)
                        .opacity(custom ? 1 : 0.5)
                    }

                    rowDivider
                    SettingRow(
                        icon: "d.circle",
                        title: NSLocalizedString("settings.pid_kd", comment: ""),
                        desc: NSLocalizedString("settings.pid_kd_desc", comment: ""),
                        scheme: scheme
                    ) {
                        InlineSlider(
                            value: pidGainBinding(
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
                        .frame(width: 152)
                        .disabled(!custom)
                        .opacity(custom ? 1 : 0.5)
                    }

                    rowDivider
                    HStack {
                        Spacer()
                        Button(NSLocalizedString("settings.pid_reset", comment: "")) {
                            viewModel.setPIDGains(kp: nil, ki: nil, kd: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!custom)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var generalSection: some View {
        SettingsSection(NSLocalizedString("settings.section.general", comment: ""), scheme: scheme) {
            SettingRow(
                icon: "rectangle.and.paperclip",
                title: NSLocalizedString("settings.launch_at_login", comment: ""),
                desc: NSLocalizedString("settings.launch_at_login_desc", comment: ""),
                scheme: scheme
            ) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, newValue in
                        viewModel.launchAtLogin = newValue
                        LaunchAtLoginManager.shared.isEnabled = newValue
                    }
            }
        }
    }

    // MARK: - About / 中文：关于

    private var aboutSection: some View {
        SettingsSection(NSLocalizedString("settings.section.about", comment: ""), scheme: scheme) {
            VStack(spacing: 0) {
                SettingRow(
                    icon: "info.circle",
                    title: NSLocalizedString("settings.version", comment: ""),
                    desc: NSLocalizedString("settings.version_desc", comment: ""),
                    scheme: scheme
                ) {
                    Text(versionDisplay)
                        .font(Theme.num(11.5, weight: .semibold))
                        .foregroundColor(Theme.text2(scheme))
                }

                rowDivider

                SettingRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: NSLocalizedString("settings.check_updates", comment: ""),
                    desc: checkUpdatesDescription,
                    scheme: scheme
                ) {
                    Button(action: { Task { await updateChecker.check() } }) {
                        if updateChecker.state == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(NSLocalizedString("settings.check_updates.button", comment: ""))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updateChecker.state == .checking)
                }
            }
        }
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

    /// Hairline between rows, inset past the icon column. / 中文：Hairline between 行s, inset past the 图标 column.
    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 46)
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
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
    }
}

// MARK: - Section container / 中文：分区容器

private struct SettingsSection<Content: View>: View {
    let title: String
    let scheme: ColorScheme
    @ViewBuilder var content: () -> Content

    init(_ title: String, scheme: ColorScheme, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.scheme = scheme
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(Theme.text3(scheme))
                .padding(.leading, 4)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedCard(scheme)
        }
    }
}

// MARK: - Rows / 中文：行

/// Square icon chip shared by every settings row. / 中文：Square 图标 chip shared by every 设置 行.
private struct SettingIcon: View {
    let icon: String
    let scheme: ColorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.fill2(scheme))
                .frame(width: 22, height: 22)
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.text1(scheme))
        }
    }
}

/// Icon + title + description, no trailing control. / 中文：图标 + title + description, no trailing 控制.
private struct SettingRowLabel: View {
    let icon: String
    let title: String
    let desc: String
    let scheme: ColorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SettingIcon(icon: icon, scheme: scheme)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.text1(scheme))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text2(scheme))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A full settings row: label on the left, a control on the right. / 中文：A full 设置 行: label on the left, a 控制 on the right.
private struct SettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    let desc: String
    let scheme: ColorScheme
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SettingRowLabel(icon: icon, title: title, desc: desc, scheme: scheme)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct InlineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double.Stride
    let format: (Double) -> String
    var accent: SliderAccent = .neutral

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: step)
                .tint(sliderTint)
            Text(format(value))
                .font(Theme.num(11.5, weight: .semibold))
                .foregroundColor(Theme.text1(scheme))
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var sliderTint: Color {
        switch accent {
        case .thermal: return Theme.thermalColor(forTemperature: value, scheme: scheme)
        case .neutral: return Theme.sliderTint(scheme)
        }
    }
}
