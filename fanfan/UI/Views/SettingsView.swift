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
    static let minSize = CGSize(width: 700, height: 480)
    static let idealSize = CGSize(width: 800, height: 680)
    static let maxSize = CGSize(width: 1000, height: 860)
}

/// Sidebar pages of the Settings window. / 中文：设置窗口的侧边栏页面。
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case monitoring
    case strategies
    case schedule
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general:    return "settings.section.general"
        case .monitoring: return "settings.section.monitoring"
        case .strategies: return "popover.strategy"
        case .schedule:   return "settings.section.schedule"
        case .about:      return "settings.section.about"
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .monitoring: return "thermometer.medium"
        case .strategies: return "chart.xyaxis.line"
        case .schedule:   return "clock"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - Settings / 中文：设置

struct SettingsView: View {
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject var updater: AppUpdater

    @AppStorage("launchAtLogin")          private var launchAtLogin = false
    @AppStorage("statusBarDisplayMode")   private var statusBarDisplayMode = "temperature"
    @AppStorage(StatusBarAnimationSettings.userDefaultsKey)
    private var statusBarIconFPS = StatusBarAnimationSettings.defaultFramesPerSecond
    @AppStorage("monitoringInterval")     private var monitoringInterval = 2.0
    @AppStorage("enableNotifications")    private var enableNotifications = true
    @AppStorage("highTempAlert")          private var highTempAlert = 85.0
    @AppStorage("autoSwitchMode")         private var autoSwitchMode = false
    @AppStorage("protectionMaxFraction")  private var protectionMaxFraction = FanController.defaultProtectionMaxFraction
    @AppStorage("settingsPane")           private var paneRaw = SettingsPane.general.rawValue

    /// Strategy whose values the editor shows. Separate from the active one: editing the active / 中文：编辑器所显示的策略，与当前生效的策略分开：
    /// strategy applies immediately in automatic mode; other strategies remain inactive. / 中文：自动模式下编辑生效中的策略会立即应用，其他策略不受影响。
    @State private var editingStrategyID = FanStrategy.balancedID
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var pendingDeleteID: String?

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .general }

    var body: some View {
        // Sidebar + one grouped form per page, like System Settings. Each page stays short / 中文：侧边栏加每页一个分组表单，与系统设置一致。
        // enough to read without scrolling, and the strategy curve gets room to be edited. / 中文：每页基本无需滚动，策略曲线也有足够的编辑空间。
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(
                get: { pane },
                set: { if let newPane = $0 { paneRaw = newPane.rawValue } }
            )) {
                ForEach(SettingsPane.allCases) { item in
                    // Monochrome icons: temperature is the only colour in the UI. / 中文：图标保持单色，界面中只有温度使用颜色。
                    Label {
                        Text(NSLocalizedString(item.titleKey, comment: ""))
                    } icon: {
                        Image(systemName: item.symbol).foregroundStyle(.secondary)
                    }
                    .tag(item)
                }
            }
            // A plain frame: on macOS 26 the column-width modifier alone left the sidebar at ~145 pt. / 中文：直接设 frame：macOS 26 上仅用列宽修饰符时侧边栏只有约 145 pt。
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Native grouped form: the macOS 26 inset-group look, row separators, / 中文：原生分组表单：macOS 26 的内嵌分组外观、行分隔线、
            // scroll-edge effect and inactive-window dimming all come from the system. / 中文：滚动边缘效果与非活跃窗口变暗都由系统提供。
            Form {
                switch pane {
                case .general:
                    generalSection
                    menuBarSection
                case .monitoring:
                    monitoringSection
                    protectionSection
                case .strategies:
                    strategyListSection
                    strategyEditorSection
                case .schedule:
                    scheduleSection
                case .about:
                    aboutSection
                }
            }
            .formStyle(.grouped)
            .id(pane)
        }
        .confirmationDialog(
            String(format: NSLocalizedString("settings.strategy_delete_title", comment: ""),
                   viewModel.strategy(id: pendingDeleteID ?? "")?.displayName ?? ""),
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("settings.strategy_delete", comment: ""), role: .destructive) {
                if let id = pendingDeleteID { deleteStrategy(id) }
                pendingDeleteID = nil
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text(NSLocalizedString("settings.strategy_delete_message", comment: ""))
        }
        .onAppear {
            editingStrategyID = viewModel.activeStrategyID
            nameDraft = viewModel.strategy(id: editingStrategyID)?.name ?? ""
        }
        .onChange(of: viewModel.strategies) { _, strategies in
            if !strategies.contains(where: { $0.id == editingStrategyID }) {
                editingStrategyID = viewModel.activeStrategyID
                nameDraft = editingStrategy?.name ?? ""
            }
        }
        // A typed name is kept however the field is left: Return, clicking elsewhere, / 中文：无论以何种方式离开输入框都保存名称：回车、点别处、
        // switching page or closing the window. / 中文：切换页面或关闭窗口。
        .onChange(of: nameFieldFocused) { _, focused in
            if !focused { commitName(for: editingStrategyID) }
        }
        .onChange(of: paneRaw) { _, _ in commitName(for: editingStrategyID) }
        .onDisappear { commitName(for: editingStrategyID) }
        .frame(minWidth: SettingsWindowLayout.minSize.width,
               idealWidth: SettingsWindowLayout.idealSize.width,
               maxWidth: SettingsWindowLayout.maxSize.width,
               minHeight: SettingsWindowLayout.minSize.height,
               idealHeight: SettingsWindowLayout.idealSize.height,
               maxHeight: SettingsWindowLayout.maxSize.height)
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

            Picker(selection: $statusBarIconFPS) {
                ForEach(StatusBarAnimationSettings.framesPerSecondOptions, id: \.self) { fps in
                    if fps == 0 {
                        Text(NSLocalizedString("settings.icon_animation.off", comment: "")).tag(fps)
                    } else {
                        Text(verbatim: "\(fps) fps").tag(fps)
                    }
                }
            } label: {
                rowLabel("settings.icon_animation")
            }
            .onChange(of: statusBarIconFPS) { _, newValue in
                NotificationCenter.default.post(
                    name: NSNotification.Name("StatusBarIconFPSChanged"),
                    object: newValue
                )
            }
        }
    }

    private var monitoringSection: some View {
        Section {
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
        }
    }

    /// What the app does on its own when the Mac runs hot. / 中文：Mac 过热时应用自行采取的动作。
    private var protectionSection: some View {
        Section {
            LabeledContent {
                InlineSlider(value: $protectionMaxFraction,
                             range: FanController.protectionMaxFractionRange, step: 0.05,
                             format: { String(format: "%.0f%%", $0 * 100) })
                    .onChange(of: protectionMaxFraction) { _, newValue in
                        viewModel.setProtectionMaxFraction(newValue)
                    }
            } label: {
                rowLabel("settings.protection_max")
            }

            Toggle(isOn: $autoSwitchMode) {
                rowLabel("settings.auto_mode_switching")
            }
            .onChange(of: autoSwitchMode) { _, newValue in
                viewModel.autoSwitchMode = newValue
            }
        }
    }

    // MARK: - Strategy / 中文：策略

    private var editingStrategy: FanStrategy? {
        viewModel.strategy(id: editingStrategyID)
    }

    /// Fan limits the curve is drawn against: the same bounds the controller clamps to. / 中文：曲线绘制所用的转速边界，与控制器夹取所用的边界一致。
    private var unifiedFloorRPM: Int {
        viewModel.fanMinSpeeds.max() ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
    }

    private var unifiedHardwareMaxRPM: Int {
        let hardware = viewModel.fanMaxSpeeds.min() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
        return max(unifiedFloorRPM, hardware)
    }

    /// Every strategy in one list. Clicking a row opens it in the editor below; the trailing / 中文：所有策略列在一处。点一行即在下方编辑它；行尾
    /// control shows or sets which one the fans follow, so "editing" and "in use" never share a control. / 中文：显示或切换风扇实际使用的策略，「编辑」与「生效」不再共用一个控件。
    private var strategyListSection: some View {
        Section {
            ForEach(viewModel.strategies) { strategy in
                strategyRow(strategy)
            }
            Button {
                addStrategy()
            } label: {
                Label(NSLocalizedString("settings.strategy_new", comment: ""), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("settings.strategy_new_help", comment: ""))
        } header: {
            Text(NSLocalizedString("settings.section.strategy_presets", comment: ""))
        } footer: {
            Text(NSLocalizedString("settings.strategy_list_footer", comment: ""))
        }
    }

    private func strategyRow(_ strategy: FanStrategy) -> some View {
        let isEditing = strategy.id == editingStrategyID
        let isActive = strategy.id == viewModel.activeStrategyID
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .opacity(isEditing ? 1 : 0)
            Text(strategy.displayName)
                .fontWeight(isEditing ? .semibold : .regular)
                .foregroundStyle(Theme.text1)
            Spacer(minLength: 8)
            // Both states are buttons of the same size, so they line up in one column. The in-use one / 中文：两种状态都是同尺寸按钮，在同一列对齐。
            // is a filled system-accent badge that does nothing when clicked. / 中文：「正在生效」是系统强调色的实心标记，点击无动作。
            // Both titles are laid out hidden so the column takes the wider one in every language. / 中文：两种标题都隐藏排版一次，任何语言下这一列都取较宽者。
            ZStack {
                Button(NSLocalizedString("settings.strategy_in_use", comment: "")) {}.hidden()
                Button(NSLocalizedString("settings.strategy_activate", comment: "")) {}.hidden()
            }
            .overlay {
                if isActive {
                    Button {} label: {
                        Text(NSLocalizedString("settings.strategy_in_use", comment: "")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .allowsHitTesting(false)
                    .accessibilityRemoveTraits(.isButton)
                } else {
                    Button {
                        viewModel.setActiveStrategy(strategy.id)
                    } label: {
                        Text(NSLocalizedString("settings.strategy_activate", comment: "")).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectStrategy(strategy.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isEditing ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectStrategy(strategy.id) }
    }

    private var strategyEditorSection: some View {
        Section {
            LabeledContent {
                TextField(
                    "",
                    text: $nameDraft,
                    prompt: Text(editingStrategy?.displayName ?? "")
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($nameFieldFocused)
                .onSubmit { commitName(for: editingStrategyID) }
                // Width follows the name instead of leaving a wide empty field. / 中文：宽度随名称变化，不留大片空白。
                .fixedSize()
                .frame(minWidth: 60, alignment: .trailing)
            } label: {
                Text(NSLocalizedString("settings.strategy_name", comment: ""))
                if editingStrategy?.isBuiltIn ?? false {
                    Text(NSLocalizedString("settings.strategy_name_desc", comment: ""))
                }
            }

            // Curve edits are committed on release; precision controls commit one step at a time.
            ResponseCurveView(
                strategies: viewModel.strategies,
                selectedID: editingStrategyID,
                floorRPM: unifiedFloorRPM,
                hardwareMaxRPM: unifiedHardwareMaxRPM,
                protectionFraction: protectionMaxFraction,
                liveTemperature: viewModel.maxTemperature > 0 ? viewModel.maxTemperature : nil,
                liveRPM: viewModel.fanSpeeds.max().map(Double.init),
                onCommit: { curve in viewModel.setStrategyCurve(curve, for: editingStrategyID) },
                chartHeight: 240
            )
            .padding(.vertical, 4)

            // Built-ins can be reset but not deleted; user strategies the other way round. / 中文：内置策略只能恢复默认、不能删除；自定义策略相反。
            LabeledContent {
                if editingStrategy?.isBuiltIn ?? true {
                    Button(NSLocalizedString("settings.strategy_preset_reset", comment: "")) {
                        viewModel.resetStrategyCurve(for: editingStrategyID)
                    }
                    .disabled(!(editingStrategy?.isModified ?? false))
                } else {
                    Button(NSLocalizedString("settings.strategy_delete_ellipsis", comment: ""), role: .destructive) {
                        pendingDeleteID = editingStrategyID
                    }
                }
            } label: {
                Text(strategyStateText)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(format: NSLocalizedString("settings.strategy_editor_header", comment: ""),
                        editingStrategy?.displayName ?? ""))
        } footer: {
            Text(NSLocalizedString("settings.strategy_curve_desc", comment: ""))
        }
    }

    private var strategyStateText: String {
        guard let strategy = editingStrategy else { return "" }
        if !strategy.isBuiltIn {
            return NSLocalizedString("settings.strategy_state_custom", comment: "")
        }
        return strategy.isModified
            ? NSLocalizedString("settings.strategy_state_modified", comment: "")
            : NSLocalizedString("settings.strategy_state_shipped", comment: "")
    }

    /// Switches the editor, saving a half-typed name for the strategy it was typed for. / 中文：切换编辑对象，并把输入到一半的名称存给它原本对应的策略。
    private func selectStrategy(_ id: String) {
        guard id != editingStrategyID else { return }
        commitName(for: editingStrategyID)
        editingStrategyID = id
        nameDraft = viewModel.strategy(id: id)?.name ?? ""
    }

    private func addStrategy() {
        let number = viewModel.strategies.filter { !$0.isBuiltIn }.count + 1
        let name = String(format: NSLocalizedString("settings.strategy_new_name", comment: ""), number)
        let newID = viewModel.addStrategy(name: name, basedOn: editingStrategyID)
        selectStrategy(newID)
    }

    private func deleteStrategy(_ id: String) {
        viewModel.deleteStrategy(id)
        if !viewModel.strategies.contains(where: { $0.id == editingStrategyID }) {
            editingStrategyID = viewModel.activeStrategyID
            nameDraft = editingStrategy?.name ?? ""
        }
    }

    /// Applies the name field to `id`, which must be the strategy the field was typed for. / 中文：把名称输入框的内容应用到 `id`，`id` 必须是输入时所对应的策略。
    /// Empty input on a built-in restores its localized title. Only a real change is written. / 中文：内置策略留空即恢复本地化标题；只在内容真正变化时写入。
    private func commitName(for id: String) {
        guard let strategy = viewModel.strategy(id: id) else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (strategy.name ?? "") else { return }
        viewModel.renameStrategy(id, to: trimmed)
    }

    // MARK: - Schedule / 中文：时间计划

    private var scheduleSection: some View {
        Section {
            ForEach(viewModel.scheduleEntries) { entry in
                scheduleRow(entry)
            }
            Button {
                viewModel.setScheduleEntries(viewModel.scheduleEntries + [ScheduleEntry.new()])
            } label: {
                Label(NSLocalizedString("settings.schedule_add", comment: ""), systemImage: "plus")
            }
        } footer: {
            Text(NSLocalizedString("settings.schedule_footer", comment: ""))
        }
    }

    private func scheduleRow(_ entry: ScheduleEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DatePicker("", selection: timeBinding(entry), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                Spacer(minLength: 8)
                Picker("", selection: scheduleBinding(entry, \.days)) {
                    Text(NSLocalizedString("settings.schedule_days.every", comment: "")).tag(ScheduleDays.everyDay)
                    Text(NSLocalizedString("settings.schedule_days.weekdays", comment: "")).tag(ScheduleDays.weekdays)
                    Text(NSLocalizedString("settings.schedule_days.weekends", comment: "")).tag(ScheduleDays.weekends)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button(role: .destructive) {
                    viewModel.setScheduleEntries(viewModel.scheduleEntries.filter { $0.id != entry.id })
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("settings.schedule_remove", comment: ""))
            }
            HStack(spacing: 8) {
                Picker("", selection: scheduleBinding(entry, \.mode)) {
                    Text(NSLocalizedString("popover.mode.manual", comment: "")).tag(ControlMode.manual)
                    Text(NSLocalizedString("popover.mode.auto", comment: "")).tag(ControlMode.automatic)
                    Text(NSLocalizedString("popover.mode.system", comment: "")).tag(ControlMode.system)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if entry.mode == .automatic {
                    Picker("", selection: scheduleBinding(entry, \.strategyID)) {
                        Text(NSLocalizedString("settings.schedule_keep_strategy", comment: "")).tag(String?.none)
                        ForEach(viewModel.strategies) { strategy in
                            Text(strategy.displayName).tag(Optional(strategy.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func updateScheduleEntry(_ id: UUID, _ change: (inout ScheduleEntry) -> Void) {
        var entries = viewModel.scheduleEntries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        viewModel.setScheduleEntries(entries)
    }

    private func scheduleBinding<Value>(_ entry: ScheduleEntry, _ keyPath: WritableKeyPath<ScheduleEntry, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.scheduleEntries.first { $0.id == entry.id }?[keyPath: keyPath] ?? entry[keyPath: keyPath] },
            set: { newValue in updateScheduleEntry(entry.id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func timeBinding(_ entry: ScheduleEntry) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: entry.hour, minute: entry.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                updateScheduleEntry(entry.id) {
                    $0.hour = parts.hour ?? 0
                    $0.minute = parts.minute ?? 0
                }
            }
        )
    }

    private var generalSection: some View {
        Section {
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
        Section {
            LabeledContent {
                Text(versionDisplay)
                    .font(Theme.num(12, weight: .medium))
                    .textSelection(.enabled)
            } label: {
                rowLabel("settings.version")
            }

            Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                rowLabel("settings.auto_check_updates")
            }

            // Sparkle shows its own progress, result and install windows.
            // 中文：检查进度、结果和安装界面都由 Sparkle 自己的窗口展示。
            LabeledContent {
                Button(NSLocalizedString("settings.check_updates.button", comment: "")) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            } label: {
                rowLabel("settings.check_updates")
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
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

}

// MARK: - Dedicated Settings Window / 中文：独立设置窗口

struct SettingsWindowView: View {
    @Binding var isOpen: Bool
    let viewModel: FanControlViewModel
    let updater: AppUpdater

    var body: some View {
        SettingsView(viewModel: viewModel, updater: updater)
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
        .frame(width: 200 + valueWidth)
    }

    private var sliderTint: Color {
        switch accent {
        case .thermal: return Theme.thermalColor(forTemperature: value, scheme: scheme)
        case .neutral: return Theme.sliderTint(scheme)
        }
    }
}
