//
//  File: ControlsCard.swift / 文件：ControlsCard.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Fan mode and slider controls in one dense card. / 描述：集中展示风扇模式与滑杆控制的紧凑卡片。
//

import SwiftUI

/// Value snapshot of everything `ControlsCard` reads off the view-model. / 中文：`ControlsCard` 从 view-model 上读到的所有内容的值快照。
/// Built once per popover `body` evaluation; equality on the snapshot lets / 中文：每次 popover `body` 求值时构建一次；快照相等让 SwiftUI
/// SwiftUI skip `ControlsCard.body` whenever an *unrelated* `@Published` on / 中文：在 view-model 上**无关**的 `@Published` 触发时（例如
/// the view-model fires (e.g. CPU temperature ticks every 2 s). / 中文：每 2 秒 CPU 温度变化）跳过 `ControlsCard.body`。
struct ControlsSnapshot: Equatable {
    var controlMode: ControlMode
    var numberOfFans: Int
    var autoThreshold: Double
    var autoMaxSpeed: Int
    var strategies: [FanStrategy]
    var activeStrategyID: String
    var perFanManualControl: Bool
    var manualSpeed: Int
    var manualSpeeds: [Int]
    var fanMinSpeeds: [Int]
    var fanMaxSpeeds: [Int]
    var unifiedMinRPM: Int
    var unifiedMaxRPM: Int
    var statusMessage: String
    var applyDidFail: Bool

    func minRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMinSpeeds.count else {
            return FanRPMBounds.floorRPM
        }
        return fanMinSpeeds[index]
    }

    func maxRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMaxSpeeds.count else {
            return FanRPMBounds.fallbackMaxWhenSMCUnreadable
        }
        return fanMaxSpeeds[index]
    }
}

struct ControlsCard: View, Equatable {
    /// Read-side state. Equality on this drives SwiftUI's input dedup. / 中文：读侧状态。SwiftUI 的输入去重以它的相等性为准。
    let snapshot: ControlsSnapshot
    /// Write-side handle. Held as a plain reference (not `@ObservedObject`) / 中文：写侧句柄。以普通引用持有（不是 `@ObservedObject`），
    /// so changes on the view-model don't invalidate this view directly — only / 中文：所以 view-model 上的变化不会直接让本视图失效——
    /// the parent rebuilding the snapshot does. / 中文：只有父视图重建 snapshot 才会。
    let viewModel: FanControlViewModel

    static func == (lhs: ControlsCard, rhs: ControlsCard) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    @Environment(\.colorScheme) private var scheme

    @State private var manualDraft: Double?
    @State private var manualApplyTask: Task<Void, Never>?
    @State private var perFanDraft: [Int: Double] = [:]
    @State private var perFanApplyTasks: [Int: Task<Void, Never>] = [:]
    @State private var selectedMode: ControlMode
    @State private var selectedStrategyID: String
    /// Drives which section is laid out. Changed inside one animation so the card and
    /// the popover (which follows the measured height every frame) resize together. / 中文：决定展示哪个分区。
    /// 在同一个动画里变化，使卡片与逐帧跟随测量高度的弹窗一起平滑缩放。
    @State private var displayedMode: ControlMode
    /// Opacity of the visible section. Only this animates: the layout change itself is
    /// instant, so the popover window and the content never disagree on height. / 中文：可见分区的透明度。只有它做动画，
    /// 布局变化本身即时完成，因此弹窗窗口与内容的高度永远一致。
    @State private var sectionOpacity: Double = 1

    /// Seeds `selectedMode` from the snapshot so the first layout pass already / 中文：用 snapshot 初始化 `selectedMode`，让首次布局就是
    /// has the live mode. The popover rebuilds this view on every open, and / 中文：当前模式。popover 每次打开都重建本视图，
    /// syncing only in `onAppear` let the first pass lay out the manual / 中文：只在 `onAppear` 同步时，首次布局会按手动模式计算
    /// controls and size the popover for them. / 中文：并据此定 popover 尺寸。
    init(snapshot: ControlsSnapshot, viewModel: FanControlViewModel) {
        self.snapshot = snapshot
        self.viewModel = viewModel
        _selectedMode = State(initialValue: snapshot.controlMode)
        _selectedStrategyID = State(initialValue: snapshot.activeStrategyID)
        _displayedMode = State(initialValue: snapshot.controlMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Group {
                if displayedMode == .automatic {
                    autoSliders
                } else if displayedMode == .manual {
                    manualSliders
                }
            }
            .opacity(sectionOpacity)

            if snapshot.applyDidFail {
                Label(
                    NSLocalizedString("controls.apply_failed", comment: ""),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Theme.danger(scheme))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .themedCard()
        .onChange(of: snapshot.controlMode) { _, newMode in
            withAnimation(.snappy) { selectedMode = newMode }
        }
        .onChange(of: selectedMode) { _, newMode in
            displayedMode = newMode
            sectionOpacity = 0
            // Fade in on the next runloop, after the new layout has been committed. / 中文：下一轮事件循环再淡入，确保新布局已先提交。
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { sectionOpacity = 1 }
            }
        }
        .onChange(of: snapshot.activeStrategyID) { _, newID in
            withAnimation(.snappy) { selectedStrategyID = newID }
        }
        .onDisappear(perform: cancelPendingSliderApplies)
    }

    /// Cancel any in-flight debounced slider writes when the popover closes. / 中文：popover 关闭时取消所有处于防抖窗口内的滑杆写入。
    /// Without this, dragging a slider and closing the popover within the / 中文：否则在 500/700 ms 防抖窗口内拖动滑杆并关闭 popover 时，
    /// 500–700 ms debounce window lets the stale draft fire after the SwiftUI / 中文：旧 draft 仍会在 SwiftUI 视图树被销毁
    /// tree (and the `@State` cancel handles) have already been torn down. / 中文：（及 `@State` 取消句柄一起被释放）后触发。
    private func cancelPendingSliderApplies() {
        manualApplyTask?.cancel()
        manualApplyTask = nil
        manualDraft = nil
        for (_, task) in perFanApplyTasks {
            task.cancel()
        }
        perFanApplyTasks.removeAll()
        perFanDraft.removeAll()
    }

    // MARK: - Header / 中文：头部

    private var header: some View {
        labeledRow {
            Text(NSLocalizedString("popover.mode", comment: ""))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text1)
        } control: {
            Picker(NSLocalizedString("popover.mode", comment: ""), selection: Binding(
                get: { selectedMode },
                set: { newMode in
                    guard newMode != selectedMode else { return }
                    withAnimation(.snappy) { selectedMode = newMode }
                    DispatchQueue.main.async {
                        viewModel.setControlMode(newMode)
                    }
                }
            )) {
                Text(NSLocalizedString("popover.mode.manual", comment: "")).tag(ControlMode.manual)
                Text(NSLocalizedString("popover.mode.auto",   comment: "")).tag(ControlMode.automatic)
                Text(NSLocalizedString("popover.mode.system", comment: "")).tag(ControlMode.system)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Label and segmented control share one row when both fit; otherwise the / 中文：标签与分段控件放得下时同处一行，否则
    /// control drops below its label, shrinking to the small control size as a / 中文：控件移到标签下方，最后一档缩成小号控件。
    /// last resort. Segment widths follow the localized titles and never / 中文：分段宽度随本地化标题变化且不会压缩，
    /// compress, so a fixed width would clip them or widen the card. / 中文：固定宽度会截断文字或把卡片撑宽。
    private func labeledRow<Label: View, Control: View>(
        @ViewBuilder label: () -> Label,
        @ViewBuilder control: () -> Control
    ) -> some View {
        let label = label().lineLimit(1)
        let control = control()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                label.fixedSize()
                Spacer(minLength: 8)
                control.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                control.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                control.controlSize(.small).fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Auto / 中文：自动

    private var autoSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            strategyPicker
            // Slider values follow the chosen strategy, so they glide with it. / 中文：滑杆数值随所选策略变化，因此一起平滑过渡。
            Group {
            LabeledSlider(
                label: NSLocalizedString("popover.threshold", comment: ""),
                value: Binding(
                    get: { snapshot.autoThreshold },
                    set: { viewModel.setAutoThreshold($0) }
                ),
                range: 40...90, step: 1,
                format: { String(format: "%.0f°C", $0) },
                accent: .thermal
            )
            LabeledSlider(
                label: NSLocalizedString("popover.max_speed", comment: ""),
                value: Binding(
                    get: { Double(snapshot.autoMaxSpeed) },
                    set: { viewModel.setAutoMaxSpeed(Int($0)) }
                ),
                range: rpmRange,
                step: 50,
                format: { "\(Int($0.rounded())) rpm" }
            )
            }
            .animation(.snappy, value: selectedStrategyID)
        }
    }

    /// Strategies are shown as a native segmented control, so every option is visible at once. / 中文：策略以原生分段控件展示，所有选项一览无余。
    /// Restoring shipped values lives in Settings, not here. / 中文：恢复出厂参数放在设置里，不在这里。
    /// Same row layout as the mode picker, so both controls share one right edge. / 中文：与模式选择器相同的行布局，两者右边缘对齐。
    private var strategyPicker: some View {
        let label = Text(NSLocalizedString("popover.strategy", comment: ""))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text1)
            .lineLimit(1)
        // Segmented while every strategy fits, beside or below the label; a menu once user / 中文：所有策略放得下时用分段控件（与标签同行或换行）；
        // strategies make it wider than the card, which would otherwise push the card past the popover. / 中文：自定义策略多到比卡片还宽时改用菜单，否则卡片会被撑出 popover。
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                label.fixedSize()
                Spacer(minLength: 8)
                strategyControl.pickerStyle(.segmented).fixedSize()
            }
            // Wrapped below the label, the control keeps the right edge shared with every other row. / 中文：换到标签下方时，控件仍与其他各行共用右边缘。
            VStack(alignment: .leading, spacing: 6) {
                label
                strategyControl.pickerStyle(.segmented).fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                strategyControl.pickerStyle(.segmented).controlSize(.small).fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 6) {
                label.fixedSize()
                Spacer(minLength: 8)
                strategyMenu
            }
        }
    }

    /// Too many strategies for segments: the active name plus an up-down chevron, set like the slider / 中文：策略多到放不下分段时：显示当前策略名加上下箭头，
    /// values below rather than as a wide grey button. The menu lists every strategy with a checkmark. / 中文：样式与下方滑杆的数值一致，而不是一个宽大的灰色按钮；菜单列出全部策略并勾选当前项。
    private var strategyMenu: some View {
        Menu {
            strategyControl.pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(snapshot.strategies.first { $0.id == selectedStrategyID }?.displayName ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var strategyControl: some View {
        Picker(NSLocalizedString("popover.strategy", comment: ""), selection: Binding(
            get: { selectedStrategyID },
            set: { newID in
                guard newID != selectedStrategyID else { return }
                withAnimation(.snappy) { selectedStrategyID = newID }
                DispatchQueue.main.async {
                    viewModel.setActiveStrategy(newID)
                }
            }
        )) {
            ForEach(snapshot.strategies) { strategy in
                Text(strategy.displayName).tag(strategy.id)
            }
        }
        .labelsHidden()
        // A segmented control keeps the widths of the titles it was built with, so a renamed strategy / 中文：分段控件沿用创建时的标题宽度，策略改名后
        // was clipped. Rebuilding it when any name changes re-measures the segments. / 中文：会被截断；任一名称变化时重建控件，重新测量各段宽度。
        .id(snapshot.strategies.map(\.displayName))
    }

    // MARK: - Manual / 中文：手动

    private var manualSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.numberOfFans > 1 {
                Toggle(isOn: Binding(
                    get: { snapshot.perFanManualControl },
                    set: { viewModel.setPerFanManualControl($0) }
                )) {
                    Text(NSLocalizedString("fan.separate_targets", comment: ""))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.text1)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if snapshot.perFanManualControl && snapshot.numberOfFans > 1 {
                ForEach(0..<snapshot.numberOfFans, id: \.self) { i in
                    perFanRow(index: i)
                }
            } else {
                LabeledSlider(
                    label: NSLocalizedString("fan.speed", comment: ""),
                    value: Binding(
                        get: { manualDraft ?? Double(snapshot.manualSpeed) },
                        set: { newValue in
                            manualDraft = newValue
                            scheduleApply(Int(newValue))
                        }
                    ),
                    range: rpmRange,
                    step: 50,
                    format: { "\(Int($0.rounded())) rpm" }
                )
                .onChange(of: snapshot.manualSpeed) { _, new in
                    if let d = manualDraft, Int(d) == new { manualDraft = nil }
                }
            }
        }
    }

    private func perFanRow(index: Int) -> some View {
        let mn = Double(snapshot.minRPM(atFan: index))
        let mx = Double(Swift.max(snapshot.maxRPM(atFan: index), snapshot.minRPM(atFan: index) + 1))
        let current: Double = {
            if let d = perFanDraft[index] { return d }
            if index < snapshot.manualSpeeds.count {
                return Double(snapshot.manualSpeeds[index])
            }
            return Double(snapshot.manualSpeed)
        }()
        return LabeledSlider(
            label: String(format: NSLocalizedString("fan.number", comment: ""), index + 1),
            value: Binding(
                get: { current },
                set: { v in
                    perFanDraft[index] = v
                    schedulePerFanApply(index: index, value: Int(v))
                }
            ),
            range: mn...mx,
            step: 50,
            format: { "\(Int($0.rounded())) rpm" }
        )
    }

    // MARK: - Helpers / 中文：辅助方法

    private var rpmRange: ClosedRange<Double> {
        let lo = Double(snapshot.unifiedMinRPM)
        let hi = Double(Swift.max(snapshot.unifiedMaxRPM, snapshot.unifiedMinRPM + 1))
        return lo...hi
    }

    private func scheduleApply(_ value: Int) {
        manualApplyTask?.cancel()
        manualApplyTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { viewModel.setManualSpeed(value) }
        }
    }

    private func schedulePerFanApply(index: Int, value: Int) {
        perFanApplyTasks[index]?.cancel()
        perFanApplyTasks[index] = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.setManualSpeedForFan(index: index, speed: value)
                perFanDraft[index] = nil
            }
        }
    }
}

// MARK: - LabeledSlider / 中文：带标签滑杆

/// Visual style for a labeled slider. / 中文：带标签滑杆的视觉风格.
/// - `neutral`: standard slider with a soft tint, for rpm / count / index. / 中文：标准滑杆 + 柔和着色，用于转速 / 计数 / 索引.
/// - `thermal`: gradient track spanning the temperature color range. / 中文：贯穿温度色谱的渐变轨道.
enum SliderAccent {
    case neutral
    case thermal
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var accent: SliderAccent = .neutral
    /// Draw a tick per step. Only for a handful of meaningful notches — on / 中文：每个步进画一个刻度。仅用于少量有意义的档位——
    /// fine-grained ranges (rpm in 50s, °C in 1s) the ticks would merge into / 中文：细粒度范围（按 50 rpm、1 °C 步进）下刻度会连成
    /// a dense dotted rail, so those snap silently instead. / 中文：密密的点阵，因此改为无刻度静默吸附。
    var showsTicks: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                Spacer()
                Text(format(value))
                    .font(Theme.num(11.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .contentTransition(.numericText())
            }
            SnappingSlider(value: $value, range: range, step: step, showsTicks: showsTicks)
                .tint(sliderTint)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
        }
    }

    /// Thermal sliders glide through the temperature color range as the value / 中文：温度滑杆的着色随取值在温度色范围内滑动 (cool→critical)，
    /// moves; neutral sliders use a soft mono tint. The Slider's shape stays / 中文：非温度滑杆使用统一的温和单色着色。
    /// the system default so all sliders read as the same control. / 中文：滑杆外形完全沿用系统控件，所有滑杆视觉一致.
    private var sliderTint: Color {
        switch accent {
        case .thermal: return Theme.thermalColor(forTemperature: value, scheme: scheme)
        case .neutral: return Theme.sliderTint(scheme)
        }
    }
}

/// System slider that lands on `step` multiples, with or without ticks. / 中文：落在 `step` 整数倍上的系统滑杆，可选是否显示刻度。
/// Ticks are drawn here rather than via `Slider(step:)`: the macOS 26 ticked / 中文：刻度在这里自绘而不用 `Slider(step:)`：macOS 26 带刻度的
/// slider sometimes renders its unfilled track near-black on the first / 中文：滑杆在启动后首次打开 popover 时偶发把未填充轨道画成近黑色，
/// popover open after launch, unlike the plain sliders beside it. / 中文：与旁边的普通滑杆不一致。
struct SnappingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var showsTicks: Bool = false

    /// Half the macOS 26 knob width — the knob's center, and so each tick, / 中文：macOS 26 滑块宽度的一半——滑块中心（也就是各刻度）
    /// stays this far inside both track ends. / 中文：距轨道两端都保持这个距离。
    private static let knobInset: CGFloat = 10.5

    var body: some View {
        let slider = Slider(value: Binding(
            get: { value },
            set: { value = Self.snap($0, to: step, in: range) }
        ), in: range)
        if showsTicks {
            slider
                .padding(.bottom, 1.5)
                .background(alignment: .bottom) { ticks.offset(y: -1) }
        } else {
            slider
        }
    }

    private var ticks: some View {
        let count = step > 0 ? Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1 : 0
        // The knob sits on its own tick; hide it as the system slider does. / 中文：滑块压住的那颗刻度隐藏，与系统滑杆一致。
        let current = step > 0 ? Int(((value - range.lowerBound) / step).rounded()) : -1
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                if i > 0 { Spacer(minLength: 0) }
                Circle()
                    .fill(Theme.text3)
                    .frame(width: 2, height: 2)
                    .opacity(i == current ? 0 : 1)
            }
        }
        .padding(.horizontal, Self.knobInset - 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Rounds to the nearest step counted from the range's lower bound, the / 中文：从范围下界起按步进取最近值，
    /// same grid a stepped `Slider` uses. / 中文：与带 step 的 `Slider` 使用同一网格。
    static func snap(_ raw: Double, to step: Double, in range: ClosedRange<Double>) -> Double {
        guard step > 0 else { return raw }
        let snapped = range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step
        return Swift.min(Swift.max(snapped, range.lowerBound), range.upperBound)
    }
}
