//
//  File: FanControlViewModel.swift / 文件：FanControlViewModel.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Fan control state, bindings, and app-facing actions. / 描述：风扇控制状态、绑定和面向应用的操作。
//

import Foundation
import Combine
import SwiftUI
import AppKit
import UserNotifications

@MainActor
class FanControlViewModel: ObservableObject {
    // Temperature readings / 中文：温度读数
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    @Published private(set) var maxTemperature: Double = 0
    @Published var allSensors: [SensorReading] = []
    @Published private(set) var sensorSections: [SensorSection] = []
    @Published private(set) var ssdTemperature: Double?
    @Published private(set) var batterySensorTemperature: Double?
    
    // Fan data / 中文：风扇数据
    @Published var fanSpeeds: [Int] = []
    @Published var fanMinSpeeds: [Int] = []
    @Published var fanMaxSpeeds: [Int] = []
    @Published var numberOfFans: Int = 0
    @Published var currentFanSpeed: Int = 0
    
    // Control state / 中文：控制状态
    @Published var controlMode: ControlMode = .automatic
    @Published var manualSpeed: Int = 2000
    @Published var autoThreshold: Double = 60.0
    @Published var autoMaxSpeed: Int = 4500
    @Published var autoAggressiveness: Double = 1.5

    // Power-strategy mirror (see FanController). / 中文：能效策略镜像（详见 FanController）。
    @Published var powerStrategy: PowerStrategy = .balanced

    // PID gain overrides (nil = use the formula derived from aggressiveness). / 中文：PID 增益覆盖值（nil 表示使用由响应强度推导的公式）。
    @Published var pidKpCustom: Double? = nil
    @Published var pidKiCustom: Double? = nil
    @Published var pidKdCustom: Double? = nil

    /// When true (manual mode), each fan uses its own target RPM from `manualSpeeds`. / 中文：When true (手动 模式), each 风扇 uses its own 目标 RPM from `手动Speeds`.
    @Published var perFanManualControl: Bool = false
    @Published var manualSpeeds: [Int] = []
    
    // Status / 中文：状态
    @Published var isMonitoring = false
    @Published var hasAccess = false
    @Published var lastError: String?
    @Published var statusMessage: String = ""
    @Published var launchAtLogin = false
    @Published var lastWriteSuccess = false
    
    // Settings / 中文：设置
    @Published var statusBarDisplayMode: String = "temperature"
    @Published var enableNotifications = true
    @Published var highTempAlert: Double = 85.0
    @Published var autoSwitchMode = false

    private let systemMonitor = SystemMonitor()
    let fanController: FanController
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.fanController = FanController(systemMonitor: systemMonitor)
        self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled

        // Load settings from UserDefaults / 中文：从 UserDefaults 加载设置
        self.statusBarDisplayMode = UserDefaults.standard.string(forKey: "statusBarDisplayMode") ?? "temperature"
        self.enableNotifications = UserDefaults.standard.object(forKey: "enableNotifications") as? Bool ?? true
        self.highTempAlert = UserDefaults.standard.double(forKey: "highTempAlert") > 0 ? UserDefaults.standard.double(forKey: "highTempAlert") : 85.0
        self.autoSwitchMode = UserDefaults.standard.object(forKey: "autoSwitchMode") as? Bool ?? false

        // Request notification permission / 中文：请求通知权限
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        setupBindings()
        setupSettingsObservers()
        setupSleepWakeNotifications()
    }
    
    /// Re-arm hysteresis: after a high-temp notification, the temperature must / 中文：重新武装回滞：发出高温通知后，温度需降到
    /// fall this far below the alert threshold before another can fire — / 中文：警报线以下这么多度才允许再次通知——
    /// otherwise a reading hovering at the line would notify on every tick. / 中文：否则在警报线附近徘徊的读数会每个 tick 都通知。
    private static let highTempRearmDelta: Double = 5.0
    private var hasNotifiedHighTemp = false

    private func setupSettingsObservers() {
        // High-temp alert and auto mode switch, both driven by the live CPU / 中文：高温警报与自动切换均由实时 CPU 温度驱动。
        // temperature. (Previously the alert observed `$highTempAlert` — the / 中文：（此前警报监听的是 `$highTempAlert` 这个设置项本身，
        // *setting* — so it only fired if the user dragged the threshold / 中文：因此只有用户在温度已超标时拖动阈值滑杆
        // slider while already over temperature.) / 中文：才会触发。）
        $cpuTemperature
            .compactMap { $0 }
            .sink { [weak self] temp in
                guard let self = self else { return }
                self.handleHighTemperature(temp)
                if self.autoSwitchMode, temp > self.highTempAlert,
                   self.controlMode != .system, self.controlMode != .automatic {
                    print("Auto-switching to automatic mode due to high temperature: \(temp)°C")
                    self.setControlMode(.automatic)
                }
            }
            .store(in: &cancellables)
    }

    /// Edge-triggered high-temp notification with re-arm hysteresis. / 中文：带重新武装回滞的边沿触发高温通知。
    private func handleHighTemperature(_ temp: Double) {
        if temp > highTempAlert {
            guard enableNotifications, !hasNotifiedHighTemp else { return }
            hasNotifiedHighTemp = true
            showHighTempNotification(temp)
        } else if temp < highTempAlert - Self.highTempRearmDelta {
            hasNotifiedHighTemp = false
        }
    }
    
    private func showHighTempNotification(_ temperature: Double) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("alert.high_temp.title", comment: "")
        content.subtitle = String(format: NSLocalizedString("alert.high_temp.subtitle", comment: ""), temperature)
        content.body = NSLocalizedString("alert.high_temp.message", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "high-temp-\(Int(temperature))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func setupBindings() {
        // System monitor bindings with removeDuplicates to prevent unnecessary UI refreshes / 中文：系统监控绑定使用 removeDuplicates，避免不必要的界面刷新。
        systemMonitor.$cpuTemperature
            .removeDuplicates(by: { Self.optionalEqual($0, $1) })
            .receive(on: DispatchQueue.main)
            .assign(to: &$cpuTemperature)

        systemMonitor.$gpuTemperature
            .removeDuplicates(by: { Self.optionalEqual($0, $1) })
            .receive(on: DispatchQueue.main)
            .assign(to: &$gpuTemperature)

        Publishers.CombineLatest($cpuTemperature, $gpuTemperature)
            .map { max($0 ?? 0, $1 ?? 0) }
            .removeDuplicates(by: { abs($0 - $1) < 0.1 })
            .receive(on: DispatchQueue.main)
            .assign(to: &$maxTemperature)

        systemMonitor.$allSensors
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$allSensors)

        $allSensors
            .map(SensorSection.sections)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$sensorSections)

        $allSensors
            .map(Self.ssdTemperature)
            .removeDuplicates(by: { Self.optionalEqual($0, $1) })
            .receive(on: DispatchQueue.main)
            .assign(to: &$ssdTemperature)

        $allSensors
            .map(Self.batterySensorTemperature)
            .removeDuplicates(by: { Self.optionalEqual($0, $1) })
            .receive(on: DispatchQueue.main)
            .assign(to: &$batterySensorTemperature)

        systemMonitor.$fanSpeeds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$fanSpeeds)

        systemMonitor.$fanMinSpeeds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$fanMinSpeeds)

        systemMonitor.$fanMaxSpeeds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$fanMaxSpeeds)

        systemMonitor.$numberOfFans
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$numberOfFans)

        systemMonitor.$isMonitoring
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMonitoring)

        systemMonitor.$hasAccess
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasAccess)

        systemMonitor.$lastError
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastError)

        // Fan controller bindings / 中文：风扇控制器绑定
        fanController.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$controlMode)

        fanController.$manualSpeed
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$manualSpeed)

        fanController.$perFanManualControl
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$perFanManualControl)

        fanController.$manualSpeeds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$manualSpeeds)

        fanController.$autoThreshold
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoThreshold)

        fanController.$autoMaxSpeed
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoMaxSpeed)

        fanController.$autoAggressiveness
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoAggressiveness)

        fanController.$powerStrategy
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$powerStrategy)

        fanController.$pidKpCustom
            .receive(on: DispatchQueue.main)
            .assign(to: &$pidKpCustom)

        fanController.$pidKiCustom
            .receive(on: DispatchQueue.main)
            .assign(to: &$pidKiCustom)

        fanController.$pidKdCustom
            .receive(on: DispatchQueue.main)
            .assign(to: &$pidKdCustom)

        fanController.$statusMessage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$statusMessage)

        fanController.$lastWriteSuccess
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastWriteSuccess)

        // Average reported RPM across detected fans with debounce / 中文：Average reported RPM across detected 风扇s with debounce
        Publishers.CombineLatest($fanSpeeds, $numberOfFans)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] speeds, n in
                guard let self = self else { return }
                guard !speeds.isEmpty, n > 0 else {
                    if self.currentFanSpeed != 0 {
                        self.currentFanSpeed = 0
                    }
                    return
                }
                let slice = min(speeds.count, Int(n))
                let sum = speeds.prefix(slice).reduce(0, +)
                let average = Int(round(Double(sum) / Double(slice)))
                if self.currentFanSpeed != average {
                    self.currentFanSpeed = average
                }
            }
            .store(in: &cancellables)
    }

    private static func optionalEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x - y) < 0.1
        default: return false
        }
    }

    private static func ssdTemperature(in sensors: [SensorReading]) -> Double? {
        sensors.first(where: {
            $0.category == .storage ||
            $0.name.localizedCaseInsensitiveContains("ssd") ||
            $0.name.localizedCaseInsensitiveContains("nand") ||
            $0.id.hasPrefix("TN")
        })?.temperature
    }

    private static func batterySensorTemperature(in sensors: [SensorReading]) -> Double? {
        sensors.first(where: {
            $0.category == .battery ||
            $0.name.localizedCaseInsensitiveContains("battery")
        })?.temperature
    }
    
    // MARK: - Monitoring Control / 中文：监控控制
    
    private func setupSleepWakeNotifications() {
        // Register for sleep notification / 中文：注册睡眠通知
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        // Register for wake notification / 中文：注册唤醒通知
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Register for screen lock notification (screen saver/display sleep) / 中文：注册屏幕锁定通知（屏保/显示器睡眠）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        
        // Register for screen wake notification / 中文：注册屏幕唤醒通知
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        // Register for session unlock notification (user logged back in) / 中文：注册会话解锁通知（用户重新登录）
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        
        // Also register for session active notification / 中文：同时注册会话激活通知
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }
    
    private func removeSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    @objc private func systemWillSleep() {
        DispatchQueue.main.async { [weak self] in
            print("FanControl: System going to sleep/lock - restoring system control")
            self?.fanController.restoreAutomaticControl()
        }
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.async { [weak self] in
            print("FanControl: System woke up - reapplying user settings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.fanController.reapplySettings()
            }
        }
    }
    
    // MARK: - Monitoring Control / 中文：监控控制
    
    func startMonitoring() {
        systemMonitor.startMonitoring()
    }
    
    func stopMonitoring() {
        systemMonitor.stopMonitoring()
    }

    /// Gate the expensive full sensor scan to popover visibility — see / 中文：把开销大的全传感器扫描限制在 popover 可见时——见
    /// `SystemMonitor.setSensorScanActive`. / 中文：`SystemMonitor.setSensorScanActive`。
    func setSensorScanActive(_ active: Bool) {
        systemMonitor.setSensorScanActive(active)
    }

    // MARK: - Fan Control / 中文：Fan Control 分区
    
    func setManualSpeed(_ speed: Int) {
        fanController.setManualSpeed(speed)
    }

    func setPerFanManualControl(_ enabled: Bool) {
        fanController.setPerFanManualControl(enabled)
    }

    func setManualSpeedForFan(index: Int, speed: Int) {
        fanController.setManualSpeed(fanIndex: index, speed: speed)
    }

    /// Lower bound for unified sliders when SMC minima are known. / 中文：Lower bound for unified 滑杆s when SMC minima are known.
    var effectiveUnifiedMinRPM: Int {
        guard !fanMinSpeeds.isEmpty else { return FanRPMBounds.fallbackMinWhenSMCUnreadable }
        return fanMinSpeeds.min() ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
    }

    /// Upper bound for unified sliders when SMC maxima are known. / 中文：Upper bound for unified 滑杆s when SMC maxima are known.
    var effectiveUnifiedMaxRPM: Int {
        guard !fanMaxSpeeds.isEmpty else { return FanRPMBounds.fallbackMaxWhenSMCUnreadable }
        return fanMaxSpeeds.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
    }

    func minRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMinSpeeds.count else { return FanRPMBounds.fallbackMinWhenSMCUnreadable }
        return fanMinSpeeds[index]
    }

    func maxRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMaxSpeeds.count else { return FanRPMBounds.fallbackMaxWhenSMCUnreadable }
        return fanMaxSpeeds[index]
    }
    
    func setControlMode(_ mode: ControlMode) {
        fanController.setMode(mode)
    }
    
    func resetToSystemControl() {
        fanController.resetToSystemControl()
    }

    /// Synchronous restore for app teardown (see FanController). / 中文：用于退出清理的同步恢复（详见 FanController）。
    func restoreAutomaticControlSync() {
        fanController.restoreAutomaticControlSync()
    }

    func setAutoThreshold(_ threshold: Double) {
        fanController.setAutoThreshold(threshold)
    }
    
    func setAutoMaxSpeed(_ speed: Int) {
        fanController.setAutoMaxSpeed(speed)
    }
    
    func setAutoAggressiveness(_ value: Double) {
        fanController.setAutoAggressiveness(value)
    }

    func setPowerStrategy(_ strategy: PowerStrategy) {
        fanController.setPowerStrategy(strategy)
    }

    /// Override individual PID gains (pass nil to fall back to the formula). / 中文：覆盖单个 PID 增益（传入 nil 时回退到公式值）。
    func setPIDGains(kp: Double?, ki: Double?, kd: Double?) {
        fanController.setPIDGains(kp: kp, ki: ki, kd: kd)
    }

    /// Read the gain currently in effect (custom override or formula default). / 中文：读取 the gain currently in effect (custom override or formula default).
    var effectivePIDKp: Double {
        if let v = pidKpCustom { return v }
        let range = Double(max(0, autoMaxSpeed - 1200))  // approx, just for UI default display
        return range * autoAggressiveness / 10.0
    }
    var effectivePIDKi: Double {
        if let v = pidKiCustom { return v }
        return effectivePIDKp / 60.0
    }
    var effectivePIDKd: Double {
        if let v = pidKdCustom { return v }
        return effectivePIDKp * 2.0
    }
    
    // MARK: - Access Control / 中文：访问控制
    
    func checkAccess() -> Bool {
        return systemMonitor.checkAccess()
    }
    
    func requestPermissions() {
        // Permissions are handled via the LaunchDaemon installation. / 中文：权限通过 LaunchDaemon 安装流程处理。
        PermissionsManager.shared.checkInstallation()
    }

    // MARK: - Helper Functions / 中文：辅助函数

    func getMaxTemperature() -> Double {
        return max(cpuTemperature ?? 0, gpuTemperature ?? 0)
    }

    func getFanSpeedPercent() -> Double {
        guard numberOfFans > 0, !fanSpeeds.isEmpty else { return 0 }

        var sum = 0.0
        var count = 0
        let n = min(numberOfFans, fanSpeeds.count, fanMaxSpeeds.count)

        for i in 0..<n {
            let mn = i < fanMinSpeeds.count ? fanMinSpeeds[i] : fanMinSpeeds.first ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
            let mx = fanMaxSpeeds[i]
            guard mx > mn else { continue }
            let p = Double(fanSpeeds[i] - mn) / Double(mx - mn)
            sum += min(1.0, max(0.0, p))
            count += 1
        }

        guard count > 0 else { return 0 }
        let avg = sum / Double(count)
        if avg.isNaN || avg.isInfinite { return 0 }
        return min(1.0, max(0.0, avg))
    }
}
