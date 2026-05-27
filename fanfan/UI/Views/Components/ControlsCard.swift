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
    var autoAggressiveness: Double
    var powerStrategy: PowerStrategy
    var perFanManualControl: Bool
    var manualSpeed: Int
    var manualSpeeds: [Int]
    var fanMinSpeeds: [Int]
    var fanMaxSpeeds: [Int]
    var unifiedMinRPM: Int
    var unifiedMaxRPM: Int

    func minRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMinSpeeds.count else {
            return FanRPMBounds.fallbackMinWhenSMCUnreadable
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
    @State private var selectedMode: ControlMode = .manual

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if selectedMode == .automatic {
                autoSliders
            } else if selectedMode == .manual {
                manualSliders
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .themedCard(scheme)
        .onAppear {
            selectedMode = snapshot.controlMode
        }
        .onChange(of: snapshot.controlMode) { _, newMode in
            selectedMode = newMode
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
        HStack(spacing: 6) {
            Text(String(format: NSLocalizedString("controls.header", comment: ""),
                        modeLabel(selectedMode).uppercased()))
                .font(Theme.label(10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(Theme.text3(scheme))

            Spacer()

            Picker("", selection: Binding(
                get: { selectedMode },
                set: { newMode in
                    guard newMode != selectedMode else { return }
                    selectedMode = newMode
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
            .frame(width: 168)
            .labelsHidden()
        }
    }

    // MARK: - Auto / 中文：自动

    private var autoSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            strategyPicker
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
            LabeledSlider(
                label: NSLocalizedString("popover.response", comment: ""),
                value: Binding(
                    get: { Double(responseIndex(for: snapshot.autoAggressiveness)) },
                    set: { viewModel.setAutoAggressiveness(responseStep($0)) }
                ),
                range: 0...Double(responseSteps.count - 1), step: 1,
                format: { responseLabel(for: responseStep($0)) }
            )
        }
    }

    /// One-tap efficiency strategy over the three auto sliders. Hand-tuning any / 中文：覆盖三个自动滑杆的一键能效策略。手动调过任一
    /// slider flips the strategy to `.custom`, which matches no segment — so the / 中文：滑杆会把策略切到 `.custom`，它不匹配任何分段——
    /// segmented control then reads as "no preset selected". / 中文：于是分段控件显示为“未选中预设”。
    private var strategyPicker: some View {
        HStack {
            Text(NSLocalizedString("popover.strategy", comment: ""))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.text1(scheme))
            Spacer()
            Picker("", selection: Binding(
                get: { snapshot.powerStrategy },
                set: { newStrategy in
                    guard newStrategy != snapshot.powerStrategy else { return }
                    DispatchQueue.main.async {
                        viewModel.setPowerStrategy(newStrategy)
                    }
                }
            )) {
                Text(NSLocalizedString("popover.strategy.power_saving", comment: "")).tag(PowerStrategy.powerSaving)
                Text(NSLocalizedString("popover.strategy.balanced",     comment: "")).tag(PowerStrategy.balanced)
                Text(NSLocalizedString("popover.strategy.performance",  comment: "")).tag(PowerStrategy.performance)
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            .labelsHidden()
        }
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
                        .foregroundColor(Theme.text1(scheme))
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

    private func responseLabel(for v: Double) -> String {
        if v <= 0.3 { return NSLocalizedString("popover.response.min_override",  comment: "") }
        if v <= 0.8 { return NSLocalizedString("popover.response.quiet",         comment: "") }
        if v <= 1.2 { return NSLocalizedString("popover.response.balanced",      comment: "") }
        if v <= 1.8 { return NSLocalizedString("popover.response.auto",          comment: "") }
        if v <= 2.3 { return NSLocalizedString("popover.response.performance",   comment: "") }
        if v <= 2.7 { return NSLocalizedString("popover.response.aggressive",    comment: "") }
        return NSLocalizedString("popover.response.max_override", comment: "")
    }

    /// One representative aggressiveness value per response label — the slider / 中文：One representative aggressiveness 值 per response label — the 滑杆
    /// snaps to exactly these notches instead of a continuous 0...3 range. / 中文：精确吸附到这些档位，而不是使用连续的 0...3 范围。
    private let responseSteps: [Double] = [0.0, 0.6, 1.0, 1.5, 2.0, 2.5, 3.0]

    /// Maps a stored aggressiveness value back to its notch index, using the / 中文：Maps a stored aggressiveness 值 back to its notch index, using the
    /// same thresholds as `responseLabel(for:)` so the round-trip is stable. / 中文：使用与 `responseLabel(for:)` 相同的阈值，确保往返转换稳定。
    private func responseIndex(for v: Double) -> Int {
        if v <= 0.3 { return 0 }
        if v <= 0.8 { return 1 }
        if v <= 1.2 { return 2 }
        if v <= 1.8 { return 3 }
        if v <= 2.3 { return 4 }
        if v <= 2.7 { return 5 }
        return 6
    }

    /// Resolves a slider position (0...6) to its representative value. / 中文：Resolves a 滑杆 position (0...6) to its representative 值.
    private func responseStep(_ sliderValue: Double) -> Double {
        let i = min(max(Int(sliderValue.rounded()), 0), responseSteps.count - 1)
        return responseSteps[i]
    }

    private func modeLabel(_ mode: ControlMode) -> String {
        switch mode {
        case .manual:
            return NSLocalizedString("popover.mode.manual", comment: "")
        case .automatic:
            return NSLocalizedString("popover.mode.auto", comment: "")
        case .system:
            return NSLocalizedString("popover.mode.system", comment: "")
        }
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
    let step: Double.Stride
    let format: (Double) -> String
    var accent: SliderAccent = .neutral

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Theme.text1(scheme))
                Spacer()
                Text(format(value))
                    .font(Theme.num(11.5, weight: .semibold))
                    .foregroundColor(Theme.text1(scheme))
            }
            Slider(value: $value, in: range, step: step)
                .tint(sliderTint)
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
