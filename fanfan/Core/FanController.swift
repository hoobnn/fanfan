//
//  File: FanController.swift / 文件：FanController.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: SMC fan control with per-fan targets and hardware-derived RPM limits. / 描述：支持单风扇目标值和硬件 RPM 边界的 SMC 风扇控制。
//

import Foundation
import Combine
import IOKit

enum ControlMode: String, CaseIterable {
    case manual
    case automatic
    case system
}

/// Auto-mode efficiency strategy — a one-tap preset over the three core auto / 中文：自动模式能效策略——对三个核心自动参数
/// parameters. Each case carries its target temperature, response notch, and / 中文：的一键预设。每个档位带有目标温度、响应档位，
/// the fraction of the hardware RPM span to use as the ceiling. `.custom` is the / 中文：以及作为转速上限的硬件转速区间占比。`.custom`
/// state a hand-dragged slider lands in — it carries no preset values. / 中文：是手动拖动滑块后落入的状态——不携带任何预设值。
enum PowerStrategy: String, CaseIterable {
    case powerSaving
    case balanced
    case performance
    case custom

    /// Target temperature the PID loop steers toward (°C). / 中文：PID 控制环逼近的目标温度（°C）。
    var targetTemp: Double? {
        switch self {
        case .powerSaving: return 75
        case .balanced:    return 60
        case .performance: return 50
        case .custom:      return nil
        }
    }

    /// Response aggressiveness notch (matches the response slider steps). / 中文：响应强度档位（对应响应滑杆档位）。
    var aggressiveness: Double? {
        switch self {
        case .powerSaving: return 0.6
        case .balanced:    return 1.5
        case .performance: return 2.5
        case .custom:      return nil
        }
    }

    /// Fraction of the [min, max] hardware RPM span used as the auto ceiling. / 中文：作为自动转速上限的 [min, max] 硬件转速区间占比。
    var maxSpeedFraction: Double? {
        switch self {
        case .powerSaving: return 0.35
        case .balanced:    return 0.65
        case .performance: return 1.0
        case .custom:      return nil
        }
    }
}

class FanController: ObservableObject {
    @Published var mode: ControlMode = .automatic
    /// Unified manual target (single slider / legacy settings). / 中文：Unified 手动 目标 (single 滑杆 / legacy 设置).
    @Published var manualSpeed: Int = 2000
    /// When `perFanManualControl` is true, each index maps to `F%dTg` for fan `d`. / 中文：When `per风扇手动控制` is true, each index maps to `F%dTg` for 风扇 `d`.
    @Published var manualSpeeds: [Int] = []
    @Published var perFanManualControl: Bool = false

    @Published var autoThreshold: Double = 55.0
    @Published var autoMaxSpeed: Int = 3600
    @Published var autoAggressiveness: Double = 1.5  // 0.0 = always min, 1.5 = temp-based, 3.0 = always max

    // PID gain overrides — nil means use the formula derived from aggressiveness. / 中文：PID 增益覆盖值；nil 表示使用由响应强度推导出的公式。
    // Exposed in the advanced/debug settings pane. / 中文：Exposed in the advanced/debug 设置 pane.
    @Published var pidKpCustom: Double? = nil
    @Published var pidKiCustom: Double? = nil
    @Published var pidKdCustom: Double? = nil

    // MARK: - Power strategy / 中文：能效策略
    // A one-tap preset over the three core auto parameters (target temp, max / 中文：对三个核心自动参数（目标温度、最高转速、
    // speed, response). It always applies — there is no plugged/battery branch — / 中文：响应）的一键预设。它始终生效——不再区分接电/电池——
    // and `.custom` means the user dragged a slider so no preset is highlighted. / 中文：`.custom` 表示用户拖动过滑块，因而没有预设被高亮。
    @Published var powerStrategy: PowerStrategy = .balanced

    @Published var isControlEnabled = false
    @Published var lastWriteSuccess = false
    @Published var statusMessage: String = ""
    /// Largest target RPM last applied (used for auto-mode hysteresis). / 中文：Largest 目标 RPM last applied (used for auto-模式 滞回).
    @Published var lastAppliedSpeed: Int = 0

    private weak var systemMonitor: SystemMonitor?
    private var autoControlTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Smart Scheduling State / 中文：Smart Scheduling State 分区

    /// Temperature history for trend prediction (last N samples) / 中文：温度 历史记录 for trend prediction (last N 采样s)
    private var tempHistory: [Double] = []
    private let tempHistoryMaxCount: Int = 10
    private var lastTempSampleTime: Date = Date()

    /// Exponential moving average of temperature feeding the control loop. / 中文：喂给控制环的温度指数滑动平均。
    /// SMC temps jitter several °C between 2 s samples; filtering the input is / 中文：SMC 温度在 2 秒采样间会抖动好几摄氏度；先滤波，
    /// the single biggest lever against noise-driven fan hunting. nil = re-seed. / 中文：是抑制噪声驱动风扇抖动最有效的手段。nil 表示重新播种。
    private var smoothedTemp: Double?
    /// EMA weight per new sample → τ ≈ 2 s / α ≈ 6 s smoothing window. / 中文：每个新采样的 EMA 权重 → 平滑窗口时间常数约 6 秒。
    private let tempSmoothingFactor: Double = 0.3

    /// Hysteresis and noise optimization. The audible "pumping" (loud→soft→loud) / 中文：滞回与噪声优化。可听到的“忽大忽小”
    /// comes from the fan chasing every transient down then back up, so the / 中文：来自风扇追逐每一次瞬时回落又升高，因此
    /// dead-band is asymmetric: easy to spin up, reluctant to spin back down. / 中文：死区是非对称的：升速容易，降速迟缓。
    private let spinUpHysteresisRPM: Int = 200
    private let spinDownHysteresisRPM: Int = 450
    /// A spin-up this large bypasses the hold window (rapid-heating safety); / 中文：超过此幅度的升速可越过保持窗口（快速升温的安全兜底）；
    /// spin-downs never break the hold — that is what stops the pumping. / 中文：降速永远不会打断保持——这正是消除忽大忽小的关键。
    private let spinUpSafetyOverrideRPM: Int = 500
    private var lastSpeedChangeTime: Date = Date()
    private let minimumHoldSeconds: TimeInterval = 8.0
    /// Asymmetric slew: ramp up briskly, glide down slowly so the ear never / 中文：非对称变化率：升速干脆，降速缓慢滑落，
    /// catches an abrupt drop in fan noise. / 中文：让耳朵察觉不到风扇噪声的突然回落。
    private let rampUpStep: Int = 800
    private let rampDownStep: Int = 250
    private var rampTargetSpeed: Int = 0

    // MARK: - PID State / 中文：PID 状态

    private var pidIntegral: Double = 0
    private var pidLastError: Double = 0
    private var pidLastUpdateTime: Date = Date()
    /// Anti-windup clamp on the integral term, in RPM-seconds-equivalent units. / 中文：Anti-windup 夹取 on the integral term, in RPM-seconds-equivalent units.
    /// Tuned so Ki * pidIntegralMaxAbs ≈ full RPM range at typical gains. / 中文：Tuned so Ki * pidIntegralMaxAbs ≈ full RPM range at typical gains.
    private let pidIntegralMaxAbs: Double = 600

    /// Default proportional gain: each °C of error contributes / 中文：默认比例增益：每 1°C 误差都会贡献转速修正。
    /// (range × aggressiveness / 10) RPM. At aggressiveness=1.5, range=3200 / 中文：(range × aggressiveness / 10) RPM. At aggressiveness=1.5, range=3200
    /// → Kp ≈ 480 RPM/°C → 5°C overshoot drives +2400 RPM immediately. / 中文：→ Kp ≈ 480 RPM/°C → 5°C overshoot drives +2400 RPM immediately.
    private var pidKp: Double {
        if let custom = pidKpCustom { return custom }
        let range = Double(unifiedMaxClamp - unifiedMinClamp)
        return range * autoAggressiveness / 10.0
    }

    /// Integral time constant ~60 s: long enough to absorb sensor noise, / 中文：Integral time constant ~60 s: long enough to absorb 传感器 noise,
    /// short enough that the loop converges to the target within ~2 min. / 中文：short enough that the loop converges to the 目标 within ~2 min.
    private var pidKi: Double {
        if let custom = pidKiCustom { return custom }
        return pidKp / 60.0
    }

    /// Derivative time constant ~2 s: predicts where temperature is heading / 中文：微分时间常数约 2 秒：预测温度走向，
    /// over the next few cycles, lets fans pre-empt sustained ramps. Kept / 中文：让风扇提前应对持续升温。相比早期的 ×3，
    /// lower than before because the EMA-filtered input no longer needs a / 中文：增益调低——温度已做 EMA 滤波，
    /// big derivative gain to fight sensor jitter (and a big one amplified it). / 中文：不再需要大微分增益对抗传感器抖动（大增益反而放大抖动）。
    private var pidKd: Double {
        if let custom = pidKdCustom { return custom }
        return pidKp * 2.0
    }

    private func resetPIDState() {
        pidIntegral = 0
        pidLastError = 0
        pidLastUpdateTime = Date()
        smoothedTemp = nil  // re-seed the EMA on the next sample / 中文：下次采样时重新播种 EMA
    }

    /// Response curve presets / 中文：响应曲线预设。
    enum ResponsePreset: String, CaseIterable {
        case silent, balanced, performance, custom

        var aggressiveness: Double {
            switch self {
            case .silent: return 0.5
            case .balanced: return 1.5
            case .performance: return 2.5
            case .custom: return -1 // uses stored value
            }
        }
    }

    init(systemMonitor: SystemMonitor) {
        self.systemMonitor = systemMonitor
        loadSettings()

        systemMonitor.$fanMaxSpeeds
            .combineLatest(systemMonitor.$fanMinSpeeds, systemMonitor.$numberOfFans)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, fanCount in
                guard let self = self, fanCount > 0 else { return }
                self.onHardwareLimitsUpdated()
            }
            .store(in: &cancellables)

        systemMonitor.$numberOfFans
            .receive(on: DispatchQueue.main)
            .filter { $0 > 0 }
            .first()
            .sink { [weak self] _ in
                print("FanController: Fans detected, applying initial settings")
                self?.applyInitialSettings()
            }
            .store(in: &cancellables)
    }

    deinit {
        stopAutoControl()
        restoreAutomaticControlSync()
    }

    // MARK: - Hardware-derived clamps / 中文：Hardware-derived clamps 分区

    private var unifiedMinClamp: Int {
        systemMonitor?.fanMinSpeeds.min() ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
    }

    private var unifiedMaxClamp: Int {
        systemMonitor?.fanMaxSpeeds.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
    }

    private func minRPM(for index: Int) -> Int {
        guard let monitor = systemMonitor,
              index >= 0,
              index < monitor.fanMinSpeeds.count else {
            return FanRPMBounds.fallbackMinWhenSMCUnreadable
        }
        return monitor.fanMinSpeeds[index]
    }

    private func maxRPM(for index: Int) -> Int {
        guard let monitor = systemMonitor,
              index >= 0,
              index < monitor.fanMaxSpeeds.count else {
            return FanRPMBounds.fallbackMaxWhenSMCUnreadable
        }
        return monitor.fanMaxSpeeds[index]
    }

    private func clampToFan(_ speed: Int, index: Int) -> Int {
        max(minRPM(for: index), min(maxRPM(for: index), speed))
    }

    private func clampUnified(_ speed: Int) -> Int {
        max(unifiedMinClamp, min(unifiedMaxClamp, speed))
    }

    private func onHardwareLimitsUpdated() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        ensureManualSpeedsSize()
        manualSpeed = clampUnified(manualSpeed)
        autoMaxSpeed = clampUnified(autoMaxSpeed)
        if !manualSpeeds.isEmpty {
            manualSpeeds = manualSpeeds.enumerated().map { clampToFan($0.element, index: $0.offset) }
        }
        saveSettings()

        if mode == .manual && isControlEnabled {
            applyManualTargets()
        } else if mode == .automatic && isControlEnabled {
            lastAppliedSpeed = 0
            updateAutoControl()
        }
    }

    private func ensureManualSpeedsSize() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        let n = monitor.numberOfFans
        if manualSpeeds.count < n {
            var copy = manualSpeeds
            let template = copy.last ?? manualSpeed
            while copy.count < n {
                let idx = copy.count
                copy.append(clampToFan(template, index: idx))
            }
            manualSpeeds = copy
        } else if manualSpeeds.count > n {
            manualSpeeds = Array(manualSpeeds.prefix(n))
        }
    }

    private func syncManualSpeedsFromUnified() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        manualSpeeds = (0..<monitor.numberOfFans).map { clampToFan(manualSpeed, index: $0) }
    }

    // MARK: - Lifecycle / 中文：生命周期

    private func applyInitialSettings() {
        print("FanController: Applying initial settings - mode: \(mode)")
        switch mode {
        case .manual:
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
        case .automatic:
            startAutoControl()
        case .system:
            stopAutoControl()
            restoreAutomaticControl()
        }
    }

    func reapplySettings() {
        print("FanController: Reapplying settings after wake - mode: \(mode)")
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else {
            print("FanController: No fans detected yet, retrying in 2 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.reapplySettings()
            }
            return
        }

        switch mode {
        case .manual:
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
            print("FanController: Manual mode reapplied")
        case .automatic:
            enableManualMode()
            startAutoControl()
            lastAppliedSpeed = 0
            updateAutoControl()
            print("FanController: Auto mode reapplied")
        case .system:
            stopAutoControl()
            restoreAutomaticControl()
            print("FanController: System mode reapplied")
        }
    }

    /// Toggle independent sliders for each fan (manual mode only). / 中文：Toggle independent 滑杆s for each 风扇 (手动 模式 only).
    func setPerFanManualControl(_ enabled: Bool) {
        perFanManualControl = enabled
        if enabled {
            syncManualSpeedsFromUnified()
        } else {
            if !manualSpeeds.isEmpty {
                let avg = Int(round(Double(manualSpeeds.reduce(0, +)) / Double(manualSpeeds.count)))
                manualSpeed = clampUnified(avg)
            }
            syncManualSpeedsFromUnified()
        }
        saveSettings()
        if mode == .manual && isControlEnabled {
            applyManualTargets()
        }
    }

    func setManualSpeed(_ speed: Int) {
        guard mode == .manual else { return }
        manualSpeed = clampUnified(speed)
        if !perFanManualControl {
            syncManualSpeedsFromUnified()
        }
        if isControlEnabled {
            applyManualTargets()
        }
        saveSettings()
    }

    func setManualSpeed(fanIndex: Int, speed: Int) {
        guard mode == .manual, perFanManualControl else { return }
        ensureManualSpeedsSize()
        guard fanIndex >= 0, fanIndex < manualSpeeds.count else { return }
        var next = manualSpeeds
        next[fanIndex] = clampToFan(speed, index: fanIndex)
        manualSpeeds = next
        saveSettings()
        if isControlEnabled {
            applyManualTargets()
        }
    }

    func setMode(_ newMode: ControlMode) {
        mode = newMode

        if newMode == .automatic {
            restoreAutomaticControl()
            startAutoControl()
        } else if newMode == .manual {
            stopAutoControl()
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
        } else {
            stopAutoControl()
            restoreAutomaticControl()
        }

        saveSettings()
    }

    private func enableManualMode() {
        guard systemMonitor != nil else {
            statusMessage = "No system monitor available"
            return
        }
        isControlEnabled = true
        statusMessage = "Manual control enabled"
        print("Fan Control: Manual control enabled")
    }

    // MARK: - Daemon write dispatch / 中文：守护进程写入调度
    // Blocking socket I/O to the daemon runs on this serial queue, off the main / 中文：与守护进程的阻塞 socket I/O 在此串行队列后台执行，
    // thread, because the first manual write triggers an ~8 s Ftst unlock on / 中文：因为 Apple Silicon 上首次手动写入会触发约 8 秒的
    // Apple Silicon (see fanfan-smcd.c). / 中文：Ftst 解锁（见 fanfan-smcd.c）。
    private let smcQueue = DispatchQueue(label: "com.hoobnn.fanfan.smc-write")
    // Coalesce SET writes so the 2 s auto timer can't pile up a backlog while a / 中文：合并 SET 写入，使 2 秒自动定时器在解锁期间
    // write (possibly the unlock) is in flight: keep only the most recent target / 中文：不会堆积——只保留最新目标，
    // and apply it once free. Both touched on the main thread only. / 中文：空闲后再应用。两者仅在主线程读写。
    private var smcWriteInFlight = false
    private var pendingFanTargets: [Int]? = nil

    func restoreAutomaticControl() {
        guard let monitor = systemMonitor else { return }
        let fanCount = monitor.numberOfFans
        guard fanCount > 0 else { return }

        smcQueue.async { [weak self] in
            guard let self = self else { return }
            var allSuccess = true
            for i in 0..<fanCount {
                if !self.runSmcHelper(args: ["auto", "\(i)"]) {
                    allSuccess = false
                }
            }
            DispatchQueue.main.async {
                if allSuccess {
                    self.isControlEnabled = false
                    self.statusMessage = "Automatic mode restored"
                    print("Fan Control: Automatic mode restored")
                } else {
                    self.statusMessage = "Failed to restore auto mode"
                    print("Fan Control: Failed to restore auto mode")
                }
            }
        }
    }

    /// Synchronous restore for teardown paths (app termination, deinit) that / 中文：用于退出清理路径（app 终止、deinit）的同步恢复——
    /// can't wait on the async queue. Each AUTO is a few ms (mode 0 + Ftst 0, no / 中文：这些路径等不了异步队列。每个 AUTO 仅几毫秒
    /// unlock), so sending them inline is fine and leaves the fans with the / 中文：（写 mode 0 + Ftst 0，无需解锁），内联发送即可，
    /// firmware instead of stuck at the last manual target after quit. / 中文：使退出后风扇交还固件，而非卡在最后的手动转速。
    func restoreAutomaticControlSync() {
        guard let monitor = systemMonitor else { return }
        let fanCount = monitor.numberOfFans
        guard fanCount > 0 else { return }
        for i in 0..<fanCount {
            _ = runSmcHelper(args: ["auto", "\(i)"])
        }
    }

    private func applyManualTargets() {
        guard let monitor = systemMonitor else {
            statusMessage = "No system monitor"
            lastWriteSuccess = false
            return
        }
        guard monitor.numberOfFans > 0 else {
            statusMessage = "No fans detected"
            lastWriteSuccess = false
            return
        }

        ensureManualSpeedsSize()
        var targets: [Int] = []
        for i in 0..<monitor.numberOfFans {
            let raw: Int
            if perFanManualControl, i < manualSpeeds.count {
                raw = manualSpeeds[i]
            } else {
                raw = manualSpeed
            }
            targets.append(clampToFan(raw, index: i))
        }
        applyFanTargets(targets)
    }

    private func applyFanTargets(_ targets: [Int]) {
        guard let monitor = systemMonitor else {
            statusMessage = "No system monitor"
            lastWriteSuccess = false
            return
        }
        guard monitor.numberOfFans > 0, targets.count == monitor.numberOfFans else {
            statusMessage = "Fan target mismatch"
            lastWriteSuccess = false
            return
        }

        // A write (possibly the ~8 s unlock) is already running — remember only / 中文：已有写入在途（可能是约 8 秒解锁）——只记住
        // the latest target and apply it when that one finishes. / 中文：最新目标，待其完成后再应用。
        if smcWriteInFlight {
            pendingFanTargets = targets
            return
        }
        smcWriteInFlight = true
        dispatchFanTargets(targets)
    }

    /// Run a SET batch on the background queue, then apply any target deferred / 中文：在后台队列执行一批 SET，随后应用本次期间
    /// while it was in flight. Must be entered with `smcWriteInFlight == true`. / 中文：被推迟的目标。进入时须满足 `smcWriteInFlight == true`。
    private func dispatchFanTargets(_ targets: [Int]) {
        smcQueue.async { [weak self] in
            guard let self = self else { return }
            var allSuccess = true
            for (i, t) in targets.enumerated() {
                let safe = max(FanRPMBounds.absoluteWriteMinRPM, min(FanRPMBounds.absoluteWriteMaxRPM, t))
                if !self.runSmcHelper(args: ["set", "\(i)", "\(safe)"]) {
                    allSuccess = false
                }
            }
            DispatchQueue.main.async {
                if allSuccess {
                    let parts = targets.enumerated().map { "F\($0.offset): \($0.element)" }.joined(separator: ", ")
                    self.statusMessage = "Fan targets RPM — \(parts)"
                    self.lastWriteSuccess = true
                    print("Fan Control: \(parts)")
                } else {
                    self.statusMessage = "Failed to set fan speed"
                    self.lastWriteSuccess = false
                }
                if let next = self.pendingFanTargets {
                    self.pendingFanTargets = nil
                    self.dispatchFanTargets(next)
                } else {
                    self.smcWriteInFlight = false
                }
            }
        }
    }

    private func runSmcHelper(args: [String]) -> Bool {
        guard let command = args.first else { return false }

        switch command {
        case "set":
            guard args.count == 3,
                  let fanIndex = Int(args[1]),
                  let rpm = Int(args[2]) else {
                return false
            }
            return SMCDaemonClient.setFanSpeed(fanIndex: fanIndex, rpm: rpm)
        case "auto":
            guard args.count == 2,
                  let fanIndex = Int(args[1]) else {
                return false
            }
            return SMCDaemonClient.setFanAuto(fanIndex: fanIndex)
        default:
            return false
        }
    }

    func startAutoControl() {
        stopAutoControl()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Seed ramp from the fan's current real RPM so the first cycles / 中文：Seed ramp from the 风扇's current real RPM so the first cycles
            // don't waste seconds climbing from 0 through the hardware floor. / 中文：避免前几个周期从 0 慢慢爬升到硬件下限而浪费时间。
            if let currentMax = self.systemMonitor?.fanSpeeds.max(), currentMax > 0 {
                self.lastAppliedSpeed = currentMax
            }
            self.resetPIDState()
            self.updateAutoControl()
            self.autoControlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.updateAutoControl()
            }
            RunLoop.current.add(self.autoControlTimer!, forMode: .common)
        }
    }

    func stopAutoControl() {
        autoControlTimer?.invalidate()
        autoControlTimer = nil
    }

    private func updateAutoControl() {
        guard mode == .automatic, let monitor = systemMonitor else { return }

        let rawTemp = max(
            monitor.cpuTemperature ?? 0,
            monitor.gpuTemperature ?? 0
        )

        guard rawTemp > 0, monitor.numberOfFans > 0 else { return }

        // Smooth the raw SMC reading before anything downstream sees it, so / 中文：先对原始 SMC 读数滤波再交给下游，
        // sensor jitter can no longer drive the PID, the trend label, or the / 中文：传感器抖动便无法再驱动 PID、趋势标签
        // load-aware boost. / 中文：或负载感知加速。
        let currentTemp = smoothTemperature(rawTemp)

        // Update temperature history (used by the status-message trend label) / 中文：Update 温度 历史记录 (used by the 状态-message trend label)
        updateTempHistory(currentTemp)

        let autoCeiling = min(autoMaxSpeed, unifiedMaxClamp)
        let autoFloor = unifiedMinClamp

        // 1. PID feedback: drives temperature toward autoThreshold (target temp) / 中文：1. PID feedback: drives 温度 toward auto阈值 (目标 temp)
        let baseSpeed = pidResponse(temp: currentTemp, floor: autoFloor, ceiling: autoCeiling)

        // 2. Load-aware feedforward: pre-empts heat from sustained power draw / 中文：2. 负载-aware feedforward: pre-empts heat from sustained 功率 draw
        let loadAdjustment = loadAwareAdjustment(floor: autoFloor, ceiling: autoCeiling)

        // 3. Combine and clamp into the auto window / 中文：3. Combine and 夹取 into the auto 窗口
        let rawTarget = min(Double(autoCeiling), baseSpeed + loadAdjustment)
        let unifiedTarget = Int(max(Double(autoFloor), rawTarget))

        if !isControlEnabled {
            // Re-engage after firmware was running the fan (e.g., post screen-sleep / 中文：固件接管过风扇后（如屏幕息屏唤醒）重新接管时，
            // restoreAutomaticControl). Re-seed from the real RPM so the hysteresis / 中文：用真实转速重新 seed，让滞回基于风扇当前状态，
            // check tracks the fan's current state, not a stale Swift target that / 中文：而不是接管前那个可能恰好等于新 PID 目标的过期值——
            // could equal the new PID output and block the re-engagement write. / 中文：否则下次写入会被滞回挡住。
            lastAppliedSpeed = monitor.fanSpeeds.max() ?? 0
            enableManualMode()
        }

        // Build per-fan targets / 中文：Build per-风扇 目标s
        var targets: [Int] = []
        for i in 0..<monitor.numberOfFans {
            let mx = maxRPM(for: i)
            let mn = minRPM(for: i)
            let cap = min(mx, autoCeiling)
            targets.append(max(mn, min(unifiedTarget, cap)))
        }

        let representative = targets.max() ?? unifiedTarget

        // 5. Apply with hysteresis and minimum hold time / 中文：5. Apply with 滞回 and minimum hold time
        if shouldApplySpeed(representative) {
            // Ramp transition to avoid sudden noise changes / 中文：使用渐进过渡，避免噪声突然变化。
            let ramped = rampTransition(from: lastAppliedSpeed, to: representative)
            var rampedTargets: [Int] = []
            for i in 0..<monitor.numberOfFans {
                let mx = maxRPM(for: i)
                let mn = minRPM(for: i)
                rampedTargets.append(max(mn, min(ramped, mx)))
            }

            applyFanTargets(rampedTargets)
            lastAppliedSpeed = ramped
            lastSpeedChangeTime = Date()
            rampTargetSpeed = representative

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let parts = rampedTargets.enumerated().map { "F\($0.offset): \($0.element)" }.joined(separator: ", ")
                let trendStr = self.tempTrendDescription()
                self.statusMessage = "Auto — \(parts) \(trendStr)"
            }
        }
    }

    // MARK: - PID Response / 中文：PID 响应

    /// Closed-loop response toward `autoThreshold` (interpreted as target temp). / 中文：Closed-loop response toward `auto阈值` (interpreted as 目标 temp).
    /// Returns an absolute RPM in [floor, ceiling]; downstream clamps still apply. / 中文：Returns an absolute RPM in [floor, ceiling]; downstream 夹取s still apply.
    private func pidResponse(temp: Double, floor: Int, ceiling: Int) -> Double {
        let now = Date()
        let rawDt = now.timeIntervalSince(pidLastUpdateTime)
        let dt = max(0.1, min(5.0, rawDt))  // guard first call / suspended app

        let error = temp - autoThreshold
        let derivative = (error - pidLastError) / dt
        pidIntegral += error * dt
        pidIntegral = max(-pidIntegralMaxAbs, min(pidIntegralMaxAbs, pidIntegral))
        pidLastError = error
        pidLastUpdateTime = now

        let p = pidKp * error
        let i = pidKi * pidIntegral
        let d = pidKd * derivative

        // Center the output around the floor: when temp == target and the / 中文：Center the output around the floor: when temp == 目标 and the
        // integral has settled, the loop sits at the hardware minimum. The / 中文：积分项稳定后，控制环会停在硬件最低转速；
        // integral pulls the baseline up over time if that's not enough. / 中文：如果最低转速不足，积分项会随时间把基线拉高。
        let raw = Double(floor) + p + i + d
        return max(Double(floor), min(Double(ceiling), raw))
    }

    // MARK: - Temperature Trend Prediction / 中文：温度趋势预测

    /// Exponential moving average of the control temperature. First sample / 中文：控制温度的指数滑动平均。首个采样
    /// seeds the filter directly so the loop doesn't lag on engagement. / 中文：直接播种滤波器，避免接管时滞后。
    private func smoothTemperature(_ raw: Double) -> Double {
        guard let prev = smoothedTemp else {
            smoothedTemp = raw
            return raw
        }
        let next = prev + tempSmoothingFactor * (raw - prev)
        smoothedTemp = next
        return next
    }

    private func updateTempHistory(_ temp: Double) {
        let now = Date()
        // Only sample at consistent intervals / 中文：Only 采样 at consistent intervals
        if now.timeIntervalSince(lastTempSampleTime) >= 1.5 {
            tempHistory.append(temp)
            if tempHistory.count > tempHistoryMaxCount {
                tempHistory.removeFirst()
            }
            lastTempSampleTime = now
        }
    }

    private func tempTrendDescription() -> String {
        guard tempHistory.count >= 3 else { return "(stabilizing)" }
        let recent = tempHistory.suffix(3)
        let slope = (recent.last! - recent.first!) / 2.0
        if slope > 1.0 { return "(rising fast)" }
        if slope > 0.2 { return "(rising)" }
        if slope < -1.0 { return "(cooling fast)" }
        if slope < -0.2 { return "(cooling)" }
        return "(stable)"
    }

    // MARK: - Load-Aware Scheduling / 中文：负载感知调度

    /// Adjust fan speed based on power consumption (if available) / 中文：Adjust 风扇 speed based on 功率 consumption (if available)
    private func loadAwareAdjustment(floor: Int, ceiling: Int) -> Double {
        // The power-saving strategy suppresses every feedforward boost — burst / 中文：省电策略关闭所有前馈加速——突发负载和
        // and charging adjustments both spend the power we're trying to save. / 中文：充电加速都会消耗我们正想省下的电。
        if powerStrategy == .powerSaving { return 0 }
        guard let power = BatteryMonitor.shared.batteryInfo.powerWatts, power > 0.1 else {
            return 0
        }
        let range = Double(ceiling - floor)

        // High power + low temp = burst load, preemptively raise fans / 中文：High 功率 + low temp = burst 负载, preemptively raise 风扇s
        let currentTemp = tempHistory.last ?? 0
        if power > 25 && currentTemp < autoThreshold {
            // Burst detected: boost by up to 15% / 中文：检测到突发负载时，最多提升 15%。
            let burstFactor = min(0.15, (power - 25) / 100.0)
            return range * burstFactor
        }

        // Charging adds heat, slightly boost / 中文：充电会增加热量，因此略微提高转速。
        if BatteryMonitor.shared.batteryInfo.isCharging {
            return range * 0.05  // 5% boost while charging
        }

        return 0
    }

    // MARK: - Hysteresis & Noise Optimization / 中文：滞回与噪声优化

    private func shouldApplySpeed(_ target: Int) -> Bool {
        // First application / 中文：首次应用目标值。
        if lastAppliedSpeed == 0 { return true }

        let delta = target - lastAppliedSpeed

        // Minimum hold time check / 中文：检查最小保持时间。
        let elapsed = Date().timeIntervalSince(lastSpeedChangeTime)
        if elapsed < minimumHoldSeconds {
            // Within the hold window only a large *spin-up* gets through, as a / 中文：保持窗口内只有大幅“升速”能通过，
            // rapid-heating safety valve. Spin-downs always wait out the hold — / 中文：作为快速升温的安全阀。降速永远等满保持——
            // letting them break it is exactly what produced the pumping. / 中文：让降速打断保持正是先前忽大忽小的成因。
            return delta >= spinUpSafetyOverrideRPM
        }

        // Asymmetric dead-band: spin up readily, resist spinning back down. / 中文：非对称死区：升速容易，降速迟缓。
        if delta >= 0 {
            return delta >= spinUpHysteresisRPM
        } else {
            return -delta >= spinDownHysteresisRPM
        }
    }

    /// Gradual ramp to avoid sudden RPM jumps. Asymmetric: spin up briskly so / 中文：使用渐进过渡，避免转速突变。非对称：升速干脆，
    /// the machine cools, glide down slowly so the noise drop is inaudible. / 中文：让机器及时降温；降速缓慢，使噪声回落不易被察觉。
    private func rampTransition(from current: Int, to target: Int) -> Int {
        let diff = target - current
        if diff > 0 {
            return diff <= rampUpStep ? target : current + rampUpStep
        } else {
            return -diff <= rampDownStep ? target : current - rampDownStep
        }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard

        if let savedMode = defaults.string(forKey: "fanControlMode") {
            mode = ControlMode(rawValue: savedMode) ?? .automatic
        }

        perFanManualControl = defaults.bool(forKey: "perFanManualControl")

        let savedManualSpeed = defaults.integer(forKey: "manualFanSpeed")
        if savedManualSpeed >= FanRPMBounds.absoluteWriteMinRPM && savedManualSpeed <= FanRPMBounds.absoluteWriteMaxRPM {
            manualSpeed = savedManualSpeed
        }

        if let savedPerFan = defaults.array(forKey: "manualFanSpeedsPerFan") as? [Int], !savedPerFan.isEmpty {
            manualSpeeds = savedPerFan
        }

        let savedThreshold = defaults.double(forKey: "autoThreshold")
        if savedThreshold >= 40 && savedThreshold <= 90 {
            autoThreshold = savedThreshold
        }

        let savedMaxSpeed = defaults.integer(forKey: "autoMaxSpeed")
        if savedMaxSpeed >= FanRPMBounds.absoluteWriteMinRPM && savedMaxSpeed <= FanRPMBounds.absoluteWriteMaxRPM {
            autoMaxSpeed = savedMaxSpeed
        }

        if defaults.object(forKey: "autoAggressiveness") != nil {
            let savedAggressiveness = defaults.double(forKey: "autoAggressiveness")
            if savedAggressiveness >= 0.0 && savedAggressiveness <= 3.0 {
                autoAggressiveness = savedAggressiveness
            }
        }

        pidKpCustom = defaults.object(forKey: "pidKpCustom") as? Double
        pidKiCustom = defaults.object(forKey: "pidKiCustom") as? Double
        pidKdCustom = defaults.object(forKey: "pidKdCustom") as? Double

        if let raw = defaults.string(forKey: "powerStrategy"),
           let strategy = PowerStrategy(rawValue: raw) {
            powerStrategy = strategy
        }
    }

    func resetToSystemControl() {
        print("Fan Control: Resetting to system default...")
        stopAutoControl()
        restoreAutomaticControl()
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: "fanControlMode")
        defaults.set(perFanManualControl, forKey: "perFanManualControl")
        defaults.set(manualSpeed, forKey: "manualFanSpeed")
        defaults.set(manualSpeeds, forKey: "manualFanSpeedsPerFan")
        defaults.set(autoThreshold, forKey: "autoThreshold")
        defaults.set(autoMaxSpeed, forKey: "autoMaxSpeed")
        defaults.set(autoAggressiveness, forKey: "autoAggressiveness")
        defaults.set(powerStrategy.rawValue, forKey: "powerStrategy")

        if let v = pidKpCustom { defaults.set(v, forKey: "pidKpCustom") } else { defaults.removeObject(forKey: "pidKpCustom") }
        if let v = pidKiCustom { defaults.set(v, forKey: "pidKiCustom") } else { defaults.removeObject(forKey: "pidKiCustom") }
        if let v = pidKdCustom { defaults.set(v, forKey: "pidKdCustom") } else { defaults.removeObject(forKey: "pidKdCustom") }
    }

    func setAutoThreshold(_ threshold: Double) {
        autoThreshold = max(40, min(90, threshold))
        powerStrategy = .custom  // hand-tuning a slider leaves the named presets / 中文：手动调滑块即离开具名预设
        saveSettings()
        if mode == .automatic {
            resetPIDState()
            updateAutoControl()
        }
    }

    func setAutoMaxSpeed(_ speed: Int) {
        autoMaxSpeed = clampUnified(speed)
        powerStrategy = .custom
        saveSettings()
        if mode == .automatic {
            resetPIDState()
            updateAutoControl()
        }
    }

    func setAutoAggressiveness(_ value: Double) {
        autoAggressiveness = max(0.0, min(3.0, value))
        powerStrategy = .custom
        saveSettings()
        if mode == .automatic {
            resetPIDState()
            updateAutoControl()
        }
    }

    func setPIDGains(kp: Double?, ki: Double?, kd: Double?) {
        pidKpCustom = kp
        pidKiCustom = ki
        pidKdCustom = kd
        saveSettings()
        if mode == .automatic {
            resetPIDState()
            updateAutoControl()
        }
    }

    /// Apply a named efficiency strategy, filling the three core auto parameters. / 中文：套用具名能效策略，填好三个核心自动参数。
    /// `.custom` is a no-op marker the manual sliders flip into. / 中文：`.custom` 是手动滑块切入的空标记。
    func setPowerStrategy(_ strategy: PowerStrategy) {
        powerStrategy = strategy

        if let temp = strategy.targetTemp {
            autoThreshold = max(40, min(90, temp))
        }
        if let agg = strategy.aggressiveness {
            autoAggressiveness = max(0, min(3, agg))
        }
        if let fraction = strategy.maxSpeedFraction {
            // Map the fraction onto this machine's [min, max] RPM span, snapping / 中文：把占比映射到本机 [min, max] 转速区间，
            // to 50-rpm steps to match the slider. / 中文：吸附到 50 rpm 档位以匹配滑杆。
            let span = Double(unifiedMaxClamp - unifiedMinClamp)
            let target = Double(unifiedMinClamp) + fraction * span
            autoMaxSpeed = clampUnified(Int((target / 50).rounded()) * 50)
        }

        saveSettings()
        if mode == .automatic {
            resetPIDState()
            updateAutoControl()
        }
    }
}
