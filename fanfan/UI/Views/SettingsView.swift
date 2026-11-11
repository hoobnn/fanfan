//
//  File: SettingsView.swift / 文件：SettingsView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Settings window UI. / 描述：设置窗口界面。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var editingScheduleID: UUID?

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
                    RecordingSection(viewModel: viewModel, recorder: viewModel.recorder)
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
        .background(EndEditingOnOutsideClick())
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
        viewModel.fanMinSpeeds.max() ?? FanRPMBounds.floorRPM
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
            // A selection bar, not a chevron: a chevron reads as "expandable" or "opens something". / 中文：用选中竖条而非箭头，箭头会让人以为这一行还能展开或打开。
            Capsule()
                .fill(Theme.text1)
                .frame(width: 3, height: 14)
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

    /// Laid out like the Clock app's alarms: each time point is a large time over a one-line summary, / 中文：布局参照「时钟」App 的闹钟：每个时间点是大号时间加一行摘要，
    /// listed in time order. Clicking a row opens its editor in a popover. / 中文：按时间先后排列。点一行在弹出面板里编辑。
    private var scheduleSection: some View {
        Section {
            if viewModel.scheduleEntries.isEmpty {
                Text(NSLocalizedString("settings.schedule_empty", comment: ""))
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedScheduleEntries) { entry in
                scheduleRow(entry)
            }
            Button {
                let entry = ScheduleEntry.new()
                viewModel.setScheduleEntries(viewModel.scheduleEntries + [entry])
                editingScheduleID = entry.id
            } label: {
                Label(NSLocalizedString("settings.schedule_add", comment: ""), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(NSLocalizedString("settings.schedule_header", comment: ""))
        } footer: {
            Text(NSLocalizedString("settings.schedule_footer", comment: ""))
        }
    }

    private var sortedScheduleEntries: [ScheduleEntry] {
        viewModel.scheduleEntries.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    private func scheduleRow(_ entry: ScheduleEntry) -> some View {
        Button {
            editingScheduleID = entry.id
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeBinding(entry).wrappedValue, format: .dateTime.hour().minute())
                        .font(Theme.num(22, weight: .regular))
                        .foregroundStyle(Theme.text1)
                    Text(scheduleSummary(entry))
                        .font(.callout)
                        .foregroundStyle(Theme.text2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { editingScheduleID == entry.id },
            set: { if !$0, editingScheduleID == entry.id { editingScheduleID = nil } }
        ), arrowEdge: .trailing) {
            scheduleEditor(entry)
        }
        .contextMenu {
            Button(NSLocalizedString("settings.schedule_remove", comment: ""), role: .destructive) {
                removeScheduleEntry(entry.id)
            }
        }
    }

    /// "Every Day · Auto · Balanced". The strategy only shows for automatic mode, where it applies. / 中文：如「每天 · 自动 · 均衡」。策略只在自动模式下有意义，也只在那时显示。
    private func scheduleSummary(_ entry: ScheduleEntry) -> String {
        var parts = [daysTitle(entry.days), modeTitle(entry.mode)]
        if entry.mode == .automatic {
            parts.append(entry.strategyID.flatMap { id in viewModel.strategies.first { $0.id == id }?.displayName }
                         ?? NSLocalizedString("settings.schedule_keep_strategy", comment: ""))
        }
        return parts.joined(separator: " · ")
    }

    private func daysTitle(_ days: ScheduleDays) -> String {
        switch days {
        case .everyDay: return NSLocalizedString("settings.schedule_days.every", comment: "")
        case .weekdays: return NSLocalizedString("settings.schedule_days.weekdays", comment: "")
        case .weekends: return NSLocalizedString("settings.schedule_days.weekends", comment: "")
        }
    }

    private func modeTitle(_ mode: ControlMode) -> String {
        switch mode {
        case .manual:    return NSLocalizedString("popover.mode.manual", comment: "")
        case .automatic: return NSLocalizedString("popover.mode.auto", comment: "")
        case .system:    return NSLocalizedString("popover.mode.system", comment: "")
        }
    }

    private func scheduleEditor(_ entry: ScheduleEntry) -> some View {
        let current = viewModel.scheduleEntries.first { $0.id == entry.id } ?? entry
        return VStack(alignment: .trailing, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    editorLabel("settings.schedule_field_time")
                    DatePicker("", selection: timeBinding(current), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .fixedSize()
                }
                GridRow {
                    editorLabel("settings.schedule_field_repeat")
                    menuPicker(scheduleBinding(current, \.days)) {
                        ForEach([ScheduleDays.everyDay, .weekdays, .weekends], id: \.self) { days in
                            Text(daysTitle(days)).tag(days)
                        }
                    }
                }
                GridRow {
                    editorLabel("settings.schedule_field_mode")
                    menuPicker(scheduleBinding(current, \.mode)) {
                        ForEach([ControlMode.manual, .automatic, .system], id: \.self) { mode in
                            Text(modeTitle(mode)).tag(mode)
                        }
                    }
                }
                if current.mode == .automatic {
                    GridRow {
                        editorLabel("settings.strategy_preset")
                        menuPicker(scheduleBinding(current, \.strategyID)) {
                            Text(NSLocalizedString("settings.schedule_keep_strategy", comment: "")).tag(String?.none)
                            Divider()
                            ForEach(viewModel.strategies) { strategy in
                                Text(strategy.displayName).tag(Optional(strategy.id))
                            }
                        }
                    }
                }
            }
            Button(NSLocalizedString("settings.schedule_remove", comment: ""), role: .destructive) {
                editingScheduleID = nil
                removeScheduleEntry(entry.id)
            }
        }
        .padding(16)
    }

    private func editorLabel(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: ""))
            .foregroundStyle(Theme.text2)
            .gridColumnAlignment(.trailing)
    }

    private func removeScheduleEntry(_ id: UUID) {
        viewModel.setScheduleEntries(viewModel.scheduleEntries.filter { $0.id != id })
    }

    /// A pop-up menu sized to its title. `.fixedSize()` alone sized the strategy menu to an / 中文：宽度贴合标题的弹出菜单。单用 `.fixedSize()` 时策略菜单按
    /// earlier, shorter title and clipped the start of long names. / 中文：先前较短的标题定宽，长名称开头被截掉。
    private func menuPicker<Value: Hashable, Content: View>(_ selection: Binding<Value>,
                                                            @ViewBuilder content: () -> Content) -> some View {
        Picker(selection: selection, content: content) { EmptyView() }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .id(selection.wrappedValue)
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

// MARK: - Recording / 中文：记录

/// Starts and stops a temperature / fan-speed recording and exports it as CSV. Its own view so it / 中文：开始、停止温度与转速记录并导出为 CSV。单独成视图，
/// observes the recorder directly and refreshes as samples arrive. / 中文：直接观察记录器，随新采样刷新。
private struct RecordingSection: View {
    let viewModel: FanControlViewModel
    @ObservedObject var recorder: ThermalRecorder

    var body: some View {
        Section(NSLocalizedString("settings.section.record", comment: "")) {
            LabeledContent {
                Button(NSLocalizedString(recorder.isRecording ? "settings.record.stop" : "settings.record.start",
                                         comment: "")) {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        viewModel.startRecording()
                    }
                }
            } label: {
                Text(NSLocalizedString("settings.record", comment: ""))
                Text(NSLocalizedString("settings.record_desc", comment: ""))
            }

            LabeledContent {
                Button(NSLocalizedString("settings.record.export", comment: "")) {
                    export()
                }
                .disabled(recorder.samples.isEmpty)
            } label: {
                Text(statusText)
                    .font(Theme.num(12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard !recorder.samples.isEmpty else {
            return NSLocalizedString("settings.record.empty", comment: "")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return String(format: NSLocalizedString("settings.record.status", comment: ""),
                      recorder.samples.count,
                      formatter.string(from: recorder.duration) ?? "")
    }

    /// Saves a snapshot, so exporting mid-recording is fine and recording carries on. / 中文：保存当前快照；记录中途也能导出，记录不中断。
    private func export() {
        let samples = recorder.samples
        guard let first = samples.first else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "fanfan-\(stamp.string(from: first.time)).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThermalRecorder.csvData(for: samples).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
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
                SettingsWindowPresenter.window?.standardWindowButton(.closeButton)?.isHidden = false
                SettingsWindowPresenter.bringToFront()
            }
    }
}

/// Opens Settings, or brings the open window to the front. `openWindow` on an existing window / 中文：打开设置窗口；已打开时把它带到最前。对已存在的窗口调用 `openWindow`
/// only reorders it inside this menu-bar app, which can leave it behind the app the user is in. / 中文：只会在本菜单栏应用内部调整次序，窗口可能仍压在用户当前使用的应用后面。
@MainActor
enum SettingsWindowPresenter {
    static var window: NSWindow? {
        NSApp.windows.first { $0.title == NSLocalizedString("app.settings_title", comment: "") }
    }

    /// Call from the click's action: activation is only granted on the stack of a user event, / 中文：请在点击回调中调用：只有在用户事件的调用栈上才会获准激活，
    /// so an open window is brought forward synchronously instead of through `openWindow`. / 中文：因此已打开的窗口直接同步前置，而不经 `openWindow`。
    static func show(using openWindow: OpenWindowAction) {
        // A closed Settings window stays in `NSApp.windows`; only a shown one is brought forward. / 中文：关闭后的设置窗口仍在 `NSApp.windows` 里，只前置正在显示的窗口。
        if let window, window.isVisible || window.isMiniaturized {
            bringToFront()
        } else {
            openWindow(id: "settings")
        }
    }

    static func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // `.floating` is only a way to surface the window from an accessory-policy app; / 中文：`.floating` 只用于让辅助模式应用的窗口浮到最前；
        // leaving it set would pin Settings above every other application. / 中文：一直保留会让设置窗口永远压在所有应用之上。
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { window.level = .normal }
    }
}

/// AppKit keeps a text field editing when the user clicks blank space. A click anywhere outside / 中文：AppKit 中点击空白处不会结束输入框的编辑。在当前输入框之外任意位置
/// the field being edited ends editing, which commits its value. / 中文：点击即结束编辑并提交输入内容。
private struct EndEditingOnOutsideClick: NSViewRepresentable {
    final class Coordinator {
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
            guard let window = view?.window, event.window === window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return event }
            if !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
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
