//
//  File: SystemMonitor.swift / 文件：SystemMonitor.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: SMC-backed system temperature and fan telemetry monitor. / 描述：基于 SMC 的系统温度与风扇遥测监控。
//

import Foundation
import Combine
import IOKit

// MARK: - Data Structures / 中文：数据结构

struct TemperatureReading {
    let cpu: Double?
    let gpu: Double?
}

struct FanReading {
    let id: Int
    let speed: Int
    let minSpeed: Int
    let maxSpeed: Int
}

struct SensorReading: Identifiable, Equatable {
    let id: String       // SMC key
    let name: String     // Human-readable name
    let temperature: Double
    let category: SensorCategory

    static func == (lhs: SensorReading, rhs: SensorReading) -> Bool {
        lhs.id == rhs.id && abs(lhs.temperature - rhs.temperature) < 0.1
    }
}

struct SensorSection: Identifiable, Equatable {
    let category: SensorCategory
    let sensors: [SensorReading]
    let maxTemperature: Double

    var id: SensorCategory { category }

    static func sections(from sensors: [SensorReading]) -> [SensorSection] {
        let grouped = Dictionary(grouping: sensors, by: \.category)
        return SensorCategory.allCases.compactMap { category in
            guard let categorySensors = grouped[category] else { return nil }
            return SensorSection(
                category: category,
                sensors: categorySensors,
                maxTemperature: categorySensors.map(\.temperature).max() ?? 0
            )
        }
    }
}

enum SensorCategory: String, CaseIterable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case system = "System"
    case ambient = "Ambient"

    /// Localized label for section headers. Falls back to the raw English name. / 中文：分区标题的本地化标签；缺失时回退到原始英文名称。
    var displayName: String {
        NSLocalizedString("sensor.category.\(rawValue.lowercased())",
                          value: rawValue, comment: "")
    }

    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .battery: return "battery.100"
        case .system: return "desktopcomputer"
        case .ambient: return "thermometer.sun"
        }
    }
}

// MARK: - SMC Types (Compatible with actual Apple SMC) / 中文：SMC 类型（兼容真实 Apple SMC）

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

// SMC key as 4-character code (FourCharCode) / 中文：SMC 键的 4 字符代码（FourCharCode）
private func fourCharCodeFrom(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, char) in string.utf8.prefix(4).enumerated() {
        result |= UInt32(char) << (8 * (3 - index))
    }
    return result
}

private func stringFrom(fourCharCode: UInt32) -> String {
    let bytes = [
        UInt8((fourCharCode >> 24) & 0xFF),
        UInt8((fourCharCode >> 16) & 0xFF),
        UInt8((fourCharCode >> 8) & 0xFF),
        UInt8(fourCharCode & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

// SMC Version structure / 中文：SMC 版本结构
private struct SMCKeyData_vers_t {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

// SMC Limit Data / 中文：SMC 限制数据
private struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

// SMC Key Info structure / 中文：SMC 键信息结构
private struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

// Main SMC structure - must match kernel's SMCParamStruct exactly / 中文：主 SMC 结构，必须与内核的 SMCParamStruct 完全匹配
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_pLimitData_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// SMC selector (kSMCUserClientOpen = 0, kSMCHandleYPCEvent = 2, etc.) / 中文：SMC selector（kSMCUserClientOpen = 0、kSMCHandleYPCEvent = 2 等）
private let KERNEL_INDEX_SMC: UInt32 = 2

// SMC commands / 中文：SMC 命令
private let SMC_CMD_READ_BYTES: UInt8 = 5
private let SMC_CMD_WRITE_BYTES: UInt8 = 6
private let SMC_CMD_READ_INDEX: UInt8 = 8
private let SMC_CMD_READ_KEYINFO: UInt8 = 9

// MARK: - System Monitor Class / 中文：系统监控类

class SystemMonitor: ObservableObject {
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    @Published var allSensors: [SensorReading] = []
    @Published var fanSpeeds: [Int] = []
    @Published var fanMinSpeeds: [Int] = []
    @Published var fanMaxSpeeds: [Int] = []
    @Published var numberOfFans: Int = 0
    @Published var isMonitoring = false
    @Published var hasAccess = false
    @Published var lastError: String?

    private var smcConnection: io_connect_t = 0
    private var monitoringTimer: Timer?
    private var monitoringInterval: TimeInterval {
        let val = UserDefaults.standard.double(forKey: "monitoringInterval")
        return val > 0 ? val : 2.0
    }
    private let readingsQueue = DispatchQueue(label: "app.fanfan.smc-readings", qos: .userInitiated)
    private var keyInfoCache: [UInt32: SMCKeyData_keyInfo_t] = [:]

    // Temperature sensor keys - ordered by priority / 中文：温度传感器键，按优先级排序
    private let cpuTempKeys = ["TC0P", "TCXC", "TC0E", "TC0F", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C"]
    private let gpuTempKeys = ["TGDD", "TG0P", "TG0D", "TG0E", "TG0F"]
    private let appleChipTempKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0b"]

    // Comprehensive sensor key map: SMC key -> (display name, category) / 中文：完整传感器键映射：SMC 键 ->（显示名称、类别）
    private let sensorKeyMap: [(String, String, SensorCategory)] = [
        // CPU / 中文：CPU
        ("TC0P", "CPU Proximity", .cpu),
        ("TC0E", "CPU Die", .cpu),
        ("TC0F", "CPU Die", .cpu),
        ("TC0D", "CPU Diode", .cpu),
        ("TCXC", "CPU Core", .cpu),
        ("TC1C", "CPU Core 1", .cpu),
        ("TC2C", "CPU Core 2", .cpu),
        ("TC3C", "CPU Core 3", .cpu),
        ("TC4C", "CPU Core 4", .cpu),
        ("TC5C", "CPU Core 5", .cpu),
        ("TC6C", "CPU Core 6", .cpu),
        ("TC7C", "CPU Core 7", .cpu),
        ("TC8C", "CPU Core 8", .cpu),
        ("Tp01", "CPU P-Cluster", .cpu),
        ("Tp05", "CPU E-Cluster", .cpu),
        ("Tp09", "CPU Proximity", .cpu),
        ("Tp0D", "CPU", .cpu),
        ("Tp0b", "CPU", .cpu),
        ("Tp0T", "CPU", .cpu),
        // GPU / 中文：GPU
        ("TGDD", "GPU Die", .gpu),
        ("TG0P", "GPU Proximity", .gpu),
        ("TG0D", "GPU Diode", .gpu),
        ("TG0E", "GPU", .gpu),
        ("TG0F", "GPU", .gpu),
        ("TG1D", "GPU Die 2", .gpu),
        // Memory / 中文：内存
        ("TM0P", "Memory Proximity", .memory),
        ("TM00", "DIMM 1", .memory),
        ("TM01", "DIMM 2", .memory),
        ("TM02", "DIMM 3", .memory),
        ("TM03", "DIMM 4", .memory),
        ("TM08", "Memory", .memory),
        // Storage / 中文：存储
        ("TH0P", "HDD Proximity", .storage),
        ("TH1P", "HDD 2", .storage),
        ("TN0D", "SSD Diode", .storage),
        ("TN0P", "SSD Proximity", .storage),
        ("TN1P", "NAND", .storage),
        // Battery / 中文：电池
        ("TB0T", "Battery Sensor 1", .battery),
        ("TB1T", "Battery Sensor 2", .battery),
        ("TB2T", "Battery Sensor 3", .battery),
        ("TB3T", "Battery", .battery),
        // System / Ambient / 中文：系统 / 环境
        ("TA0P", "Ambient", .ambient),
        ("TA1P", "Ambient 2", .ambient),
        ("Ts0P", "Palm Rest", .system),
        ("Ts1P", "Palm Rest 2", .system),
        ("Ts2P", "Bottom Case", .system),
        ("TI0P", "Thunderbolt", .system),
        ("TI1P", "Thunderbolt 2", .system),
        ("TW0P", "Airport Card", .system),
    ]

    // Discovered valid sensor keys (populated on first full scan) / 中文：已发现的有效传感器键（首次完整扫描时填充）
    private var discoveredSensorKeys: [(String, String, SensorCategory)] = []
    private var discoveredGpuKeys: [String] = []
    private var hasDoneFullScan = false

    /// Tiered polling: the full sensor list (`scanAllSensors`) is expensive — / 中文：分级采样：完整传感器列表（`scanAllSensors`）开销较大——
    /// 30+ IOKit round-trips on Macs with rich SMC catalogues. The fast tier / 中文：在 SMC 传感器丰富的机型上要做 30+ 次 IOKit 往返。快速档
    /// (CPU/GPU temp, fan RPM) runs every `monitoringInterval`; the slow tier / 中文：（CPU/GPU 温度、风扇转速）按 `monitoringInterval` 跑；慢速档
    /// (full sensor scan) runs at most every `slowSensorScanInterval`. / 中文：（完整传感器扫描）最多每 `slowSensorScanInterval` 一次。
    private var lastSensorScanTime: Date?
    private var slowSensorScanInterval: TimeInterval {
        max(6.0, monitoringInterval * 3)
    }

    /// Gates the slow-tier full sensor scan to when the popover is on screen. / 中文：把慢档全传感器扫描限制在 popover 显示期间。
    /// The sensor list and the SSD / battery sensor temps it feeds are only / 中文：它喂养的传感器列表与 SSD / 电池温度仅在 popover
    /// visible then; while closed the fast tier (CPU/GPU temp + fan RPM, needed / 中文：打开时可见；关闭时快档（CPU/GPU 温度 + 风扇转速，
    /// by the menu-bar icon and auto control) keeps running but the ~30 IOKit / 中文：供菜单栏图标与自动控制使用）继续跑，但每 6 秒
    /// round-trips of the scan are skipped. Accessed only on `readingsQueue`. / 中文：约 30 次 IOKit 往返的扫描被跳过。仅在 `readingsQueue` 访问。
    private var sensorScanActive = false

    /// Fan `Mn` / `Mx` SMC keys are hardware-fixed limits; reading them every / 中文：风扇 `Mn` / `Mx` SMC 键是硬件固化上下限；每个 tick 重读
    /// tick wastes IOKit traffic. Cache once per fan-count and invalidate only / 中文：浪费 IOKit。按风扇数缓存一次，只有风扇数变化时
    /// when the fan count changes (e.g. hot-pluggable behavior on some chassis). / 中文：才失效（例如某些机型支持热插拔风扇）。
    private var cachedFanLimits: (count: Int, mins: [Int], maxes: [Int])?

    // Keys that have a curated (friendly, localizable) name in sensorKeyMap. / 中文：在 sensorKeyMap 中有精选友好且可本地化名称的键。
    private lazy var curatedSensorKeys: Set<String> = Set(sensorKeyMap.map { $0.0 })

    // EMA smoothing for temperature readings / 中文：温度读数的 EMA 平滑
    private var smoothedCpuTemp: Double?
    private var smoothedGpuTemp: Double?
    private let smoothingAlpha: Double = 0.1

    // Cached effective SMC keys / 中文：缓存的有效 SMC 键
    private var cachedCpuKey: String?
    private var cachedGpuKey: String?

    // Consecutive read failure tracking / 中文：连续读取失败跟踪
    private var cpuReadFailures: Int = 0
    private var gpuReadFailures: Int = 0
    private let maxConsecutiveFailures: Int = 10
    
    init() {
        // Try to connect on init / 中文：初始化时尝试连接
        _ = openSMCConnection()
    }
    
    deinit {
        stopMonitoring()
        closeSMCConnection()
    }
    
    // MARK: - SMC Connection Management / 中文：SMC 连接管理
    
    private func openSMCConnection() -> Bool {
        if smcConnection != 0 {
            DispatchQueue.main.async { self.hasAccess = true }
            return true
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            DispatchQueue.main.async {
                self.lastError = "AppleSMC service not found"
                self.hasAccess = false
            }
            return false
        }

        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &smcConnection)

        if result == kIOReturnSuccess {
            DispatchQueue.main.async {
                self.hasAccess = true
                self.lastError = nil
            }
            return true
        } else {
            let errorString = describeIOReturn(result)
            DispatchQueue.main.async {
                self.lastError = "Failed to open SMC connection: \(errorString)"
                self.hasAccess = false
            }
            return false
        }
    }
    
    private func closeSMCConnection() {
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
    }
    
    private func describeIOReturn(_ result: IOReturn) -> String {
        switch Int32(bitPattern: UInt32(result)) {
        case kIOReturnSuccess: return "Success"
        case kIOReturnError: return "General error"
        case kIOReturnNoMemory: return "No memory"
        case kIOReturnNoResources: return "No resources"
        case kIOReturnBadArgument: return "Bad argument"
        case kIOReturnNotPrivileged: return "Not privileged (needs root)"
        case kIOReturnNotOpen: return "Not open"
        case kIOReturnNotFound: return "Not found"
        case kIOReturnNotReadable: return "Not readable"
        case kIOReturnNotWritable: return "Not writable"
        default: return "Error code: \(result)"
        }
    }
    
    func checkAccess() -> Bool {
        if smcConnection == 0 {
            _ = openSMCConnection()
        }
        return hasAccess
    }
    
    func getDataType(key: String) -> String? {
        // Ensure connection / 中文：确保连接
        if smcConnection == 0 { _ = openSMCConnection() }
        
        let keyCode = fourCharCodeFrom(key)
        
        // Use cached if available / 中文：可用时使用缓存
        if let info = keyInfoCache[keyCode] {
            return stringFrom(fourCharCode: info.dataType).trimmingCharacters(in: .whitespaces)
        }
        
        // Otherwise try to fetch it / 中文：否则尝试重新获取
        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = SMC_CMD_READ_KEYINFO
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        let result = IOConnectCallStructMethod(smcConnection, KERNEL_INDEX_SMC, &input, MemoryLayout<SMCParamStruct>.size, &output, &outputSize)
        
        if result == kIOReturnSuccess && output.result == 0 {
            // Validate dataSize to avoid corrupt/out-of-range values / 中文：校验 dataSize，避免损坏或越界值
            let dataSize = output.keyInfo.dataSize
            if dataSize == 0 || dataSize > 32 {
                print("SMC: Invalid dataSize (\(dataSize)) for key \(key)")
                return nil
            }
            keyInfoCache[keyCode] = output.keyInfo
            return stringFrom(fourCharCode: output.keyInfo.dataType).trimmingCharacters(in: .whitespaces)
        }
        
        return nil
    }
    
    // MARK: - Monitoring Control / 中文：监控控制
    
    func startMonitoring() {
        guard openSMCConnection() else {
            print("SMC: Cannot start monitoring - no connection")
            return
        }

        stopMonitoring()
        DispatchQueue.main.async { self.isMonitoring = true }

        // Initial read / 中文：初始读取
        updateReadings()

        // Start periodic timer on main thread / 中文：在主线程启动周期性定时器
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: self.monitoringInterval, repeats: true) { [weak self] _ in
                self?.updateReadings()
            }
            RunLoop.current.add(timer, forMode: .common)
            self.monitoringTimer = timer
        }
    }

    private func detectFanCount() -> Int {
        var count = 0
        for i in 0..<8 {
            let key = String(format: "F%dAc", i)
            if readSMCValue(key: key) != nil {
                count += 1
            } else {
                break
            }
        }
        return count
    }
    
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        DispatchQueue.main.async { self.isMonitoring = false }
    }

    /// Driven by the popover's appear/disappear so the slow sensor scan only / 中文：由 popover 的 appear/disappear 驱动，使慢档传感器扫描
    /// runs while its data is on screen. Re-activating clears the throttle so / 中文：仅在其数据可见时运行。重新激活时清除节流，
    /// the freshly opened popover gets a fresh scan on the next tick. / 中文：让刚打开的 popover 在下一个 tick 拿到新鲜扫描。
    func setSensorScanActive(_ active: Bool) {
        readingsQueue.async { [weak self] in
            guard let self = self else { return }
            if active && !self.sensorScanActive {
                self.lastSensorScanTime = nil
            }
            self.sensorScanActive = active
        }
    }
    
    // MARK: - Fan Detection / 中文：风扇检测
    
    private func detectFans() {
        var count = 0
        for i in 0..<8 {
            let key = String(format: "F%dAc", i)
            if let _ = readSMCValue(key: key) {
                count += 1
            } else {
                break
            }
        }
        
        DispatchQueue.main.async {
            self.numberOfFans = count
            print("SMC: Detected \(count) fan(s)")
        }
    }
    
    // MARK: - Reading Updates / 中文：读数更新
    
    private func updateReadings() {
        readingsQueue.async { [weak self] in
            guard let self = self else { return }

            // One-time SMC key enumeration so GPU and sensor keys are known / 中文：One-time SMC 键 enumeration so GPU and 传感器 键s are known
            // before the first temperature read. / 中文：before the first 温度 读取.
            self.ensureFullScan()

            // Fast tier: CPU / GPU temperature + fan RPM, every tick. / 中文：快速档：每个 tick 都读 CPU / GPU 温度 + 风扇转速。
            let rawCpuTemp = self.readCpuTemperature()
            let rawGpuTemp = self.readGpuTemperature()
            let cpuTemp = self.smoothTemperature(raw: rawCpuTemp, smoothed: &self.smoothedCpuTemp)
            let gpuTemp = self.smoothTemperature(raw: rawGpuTemp, smoothed: &self.smoothedGpuTemp)

            let detectedFanCount = self.numberOfFans > 0 ? self.numberOfFans : self.detectFanCount()
            let (speeds, minSpeeds, maxSpeeds) = self.readFanData(fanCount: detectedFanCount)

            // Slow tier: full sensor list. `scanAllSensors` does up to ~30 IOKit / 中文：慢速档：完整传感器列表。`scanAllSensors` 要做 ~30 次
            // round-trips on rich-catalogue Macs, so cap it to `slowSensorScan- / 中文：IOKit 往返（在传感器丰富的机型上），因此最多每
            // Interval`. Intervening ticks keep the previously published list. / 中文：`slowSensorScanInterval` 跑一次；中间 tick 沿用上一份。
            let now = Date()
            let needsSensorScan: Bool = {
                // Skip entirely while the popover (the only consumer) is closed. / 中文：唯一消费方 popover 关闭时整段跳过。
                guard self.sensorScanActive else { return false }
                guard let last = self.lastSensorScanTime else { return true }
                return now.timeIntervalSince(last) >= self.slowSensorScanInterval
            }()
            let scannedSensors: [SensorReading]? = needsSensorScan ? self.scanAllSensors() : nil
            if needsSensorScan { self.lastSensorScanTime = now }

            DispatchQueue.main.async {
                if self.cpuTemperature != cpuTemp { self.cpuTemperature = cpuTemp }
                if self.gpuTemperature != gpuTemp { self.gpuTemperature = gpuTemp }
                if let scannedSensors, self.allSensors != scannedSensors {
                    self.allSensors = scannedSensors
                }
                if self.fanSpeeds != speeds { self.fanSpeeds = speeds }
                if self.fanMinSpeeds != minSpeeds { self.fanMinSpeeds = minSpeeds }
                if self.fanMaxSpeeds != maxSpeeds { self.fanMaxSpeeds = maxSpeeds }

                let effectiveFanCount = max(detectedFanCount, speeds.count)
                if self.numberOfFans != effectiveFanCount {
                    self.numberOfFans = effectiveFanCount
                }
            }
        }
    }

    /// Reads actual/target RPM every tick; `Mn` / `Mx` come from [[cachedFanLimits]]. / 中文：每个 tick 读 actual/target RPM；`Mn` / `Mx` 走 [[cachedFanLimits]] 缓存。
    private func readFanData(fanCount: Int) -> (speeds: [Int], mins: [Int], maxes: [Int]) {
        var speeds: [Int] = []
        for i in 0..<fanCount {
            let actualKey = String(format: "F%dAc", i)
            let targetKey = String(format: "F%dTg", i)
            // Try actual speed first, fall back to target if 0 / 中文：先尝试实际转速，为 0 时回退到目标转速
            if let speed = readSMCFanSpeed(key: actualKey), speed > 0 {
                speeds.append(validateFanRPM(speed))
            } else if let target = readSMCFanSpeed(key: targetKey), target > 0 {
                speeds.append(validateFanRPM(target))
            }
        }

        if let cached = cachedFanLimits, cached.count == fanCount {
            return (speeds, cached.mins, cached.maxes)
        }

        var minSpeeds: [Int] = []
        var maxSpeeds: [Int] = []
        var allReadsSucceeded = true
        for i in 0..<fanCount {
            let minKey = String(format: "F%dMn", i)
            let maxKey = String(format: "F%dMx", i)
            if let m = readSMCFanSpeed(key: minKey) {
                minSpeeds.append(validateFanRPM(m))
            } else {
                minSpeeds.append(FanRPMBounds.fallbackMinWhenSMCUnreadable)
                allReadsSucceeded = false
            }
            if let m = readSMCFanSpeed(key: maxKey) {
                maxSpeeds.append(validateFanRPM(m))
            } else {
                maxSpeeds.append(-1)
                allReadsSucceeded = false
            }
        }
        let positiveMaxima = maxSpeeds.filter { $0 > 0 }
        let peerMax = positiveMaxima.max()
        for i in maxSpeeds.indices where maxSpeeds[i] <= 0 {
            maxSpeeds[i] = peerMax ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
        }
        // Only cache when every `Mn`/`Mx` read came back from SMC. Transient / 中文：只有当每个 `Mn`/`Mx` 都从 SMC 真实读到才缓存。
        // failures (startup race, wake-from-sleep, SMC reconnect) used to / 中文：临时失败（启动期、唤醒、SMC 重连）以前每 tick 重读，
        // self-heal on the next tick — caching fallback values would freeze / 中文：会自然恢复；如果把 fallback 写进缓存，
        // them in place until the fan count changes (i.e. effectively never). / 中文：直到风扇数量变化（实际上永远不会）才解锁。
        if allReadsSucceeded {
            cachedFanLimits = (fanCount, minSpeeds, maxSpeeds)
        }
        return (speeds, minSpeeds, maxSpeeds)
    }

    // MARK: - Full Sensor Scan / 中文：完整传感器扫描

    /// One-time discovery: enumerate every SMC key the Mac exposes, keep the / 中文：One-time discovery: enumerate every SMC 键 the Mac exposes, keep the
    /// ones that read as real temperatures, and categorize them. Falls back to / 中文：ones that 读取 as real 温度s, and categorize them. Falls back to
    /// probing the curated key map if enumeration is unavailable. / 中文：probing the curated 键 map if enumeration is unavailable.
    private func ensureFullScan() {
        guard !hasDoneFullScan else { return }

        var discovered = enumerateTemperatureSensors()
        if discovered.isEmpty {
            // Enumeration failed — fall back to probing the curated list. / 中文：枚举失败时回退为探测精选列表。
            for (key, name, category) in sensorKeyMap {
                if let temp = readSMCValue(key: key), temp > 0, temp < 150 {
                    discovered.append((key, name, category))
                }
            }
        }

        let filtered = filterSensors(discovered)
        discoveredSensorKeys = filtered
        discoveredGpuKeys = filtered.filter { $0.2 == .gpu }.map { $0.0 }
        hasDoneFullScan = true
        print("SMC: Discovered \(discovered.count) temperature sensors, kept \(filtered.count) after filtering (\(discoveredGpuKeys.count) GPU)")
    }

    /// Cap on how many sensors to keep per category — the SMC exposes far more / 中文：Cap on how many 传感器s to keep per category — the SMC exposes far more
    /// keys than is useful for a simple temperature viewer. / 中文：键s than is useful for a simple 温度 viewer.
    private let maxSensorsPerCategory = 4

    /// Trim the discovered set to a tidy, stable subset: curated (friendly-named) / 中文：将发现结果裁剪成稳定的小集合：优先保留精选的友好命名传感器
    /// sensors win, the rest fill up to a per-category cap in deterministic / 中文：传感器s win, the rest fill up to a per-category cap in deterministic
    /// order. Runs once at discovery so the sensor list never flickers. / 中文：order. Runs once at discovery so the 传感器 list never flickers.
    private func filterSensors(
        _ sensors: [(String, String, SensorCategory)]
    ) -> [(String, String, SensorCategory)] {
        var result: [(String, String, SensorCategory)] = []
        for category in SensorCategory.allCases {
            let inCategory = sensors.filter { $0.2 == category }
            guard !inCategory.isEmpty else { continue }
            let curated = inCategory.filter { curatedSensorKeys.contains($0.0) }
            let generic = inCategory
                .filter { !curatedSensorKeys.contains($0.0) }
                .sorted { $0.0 < $1.0 }
            result.append(contentsOf: (curated + generic).prefix(maxSensorsPerCategory))
        }
        return result
    }

    /// Read every sensor found during the one-time full scan. Display names are / 中文：读取 every 传感器 found during the one-time full scan. Display names are
    /// localized here (not baked in) so a language change takes effect live: / 中文：在这里本地化而不是提前固化，因此语言切换可以即时生效：
    /// curated keys look up `sensor.<KEY>` (English name as fallback), unknown / 中文：curated 键s look up `传感器.<KEY>` (English name as 回退), unknown
    /// keys fall back to a localized "<Category> Sensor". / 中文：键s fall back to a localized "<Category> 传感器".
    private func scanAllSensors() -> [SensorReading] {
        ensureFullScan()

        var sensors: [SensorReading] = []
        for (key, name, category) in discoveredSensorKeys {
            guard let temp = readSMCValue(key: key), temp > 0, temp < 150 else { continue }
            let displayName: String
            if curatedSensorKeys.contains(key) {
                displayName = NSLocalizedString("sensor.\(key)", value: name, comment: "")
            } else {
                displayName = String(format: NSLocalizedString("sensor.generic", comment: ""),
                                     category.displayName)
            }
            sensors.append(SensorReading(id: key, name: displayName,
                                         temperature: temp, category: category))
        }
        return sensors
    }

    // MARK: - SMC Key Enumeration / 中文：SMC 键枚举

    /// Total number of keys the SMC exposes (via the `#KEY` meta-key). / 中文：SMC 暴露的键总数（通过 `#KEY` 元键读取）。
    private func readSMCKeyCount() -> Int {
        guard let count = readSMCValue(key: "#KEY") else { return 0 }
        return Int(count)
    }

    /// Read the SMC key name at a given enumeration index. / 中文：读取指定枚举索引上的 SMC 键名。
    private func readSMCKey(atIndex index: Int) -> String? {
        guard smcConnection != 0 else { return nil }

        var input = SMCParamStruct()
        input.data8 = SMC_CMD_READ_INDEX
        input.data32 = UInt32(index)

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size

        let result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess, output.result == 0, output.key != 0 else {
            return nil
        }
        return stringFrom(fourCharCode: output.key)
    }

    /// Enumerate all SMC keys and return the ones that read as real / 中文：Enumerate all SMC 键s and return the ones that 读取 as real
    /// temperatures, categorized by key prefix. Curated names take priority so / 中文：温度s, categorized by 键 prefix. Curated names take priority so
    /// known sensors keep their friendly labels; everything else (including / 中文：known 传感器s keep their friendly labels; everything else (including
    /// Apple Silicon's lowercase `Tg..` GPU keys) is discovered automatically. / 中文：Apple Sil图标's lowercase `Tg..` GPU 键s) is discovered 自动ally.
    private func enumerateTemperatureSensors() -> [(String, String, SensorCategory)] {
        let count = readSMCKeyCount()
        guard count > 0, count < 8192 else { return [] }

        let curated = Dictionary(
            sensorKeyMap.map { ($0.0, ($0.1, $0.2)) },
            uniquingKeysWith: { first, _ in first }
        )

        var found: [(String, String, SensorCategory)] = []
        var seen = Set<String>()

        for i in 0..<count {
            guard let key = readSMCKey(atIndex: i) else { continue }
            guard key.hasPrefix("T"), !seen.contains(key) else { continue }
            guard let temp = readSMCValue(key: key), temp > 0, temp < 150 else { continue }
            seen.insert(key)

            if let (name, category) = curated[key] {
                found.append((key, name, category))
            } else {
                let (name, category) = Self.categorize(key: key)
                found.append((key, name, category))
            }
        }
        return found
    }

    /// Heuristic categorization, by key prefix, for keys not in the curated map. / 中文：对不在精选映射中的键按前缀进行启发式分类。
    private static func categorize(key: String) -> (String, SensorCategory) {
        let category: SensorCategory
        if key.hasPrefix("TC") || key.hasPrefix("Tp") {
            category = .cpu
        } else if key.hasPrefix("TG") || key.hasPrefix("Tg") {
            category = .gpu
        } else if key.hasPrefix("TM") {
            category = .memory
        } else if key.hasPrefix("TH") || key.hasPrefix("TN") {
            category = .storage
        } else if key.hasPrefix("TB") {
            category = .battery
        } else if key.hasPrefix("TA") {
            category = .ambient
        } else {
            category = .system
        }
        return ("\(category.rawValue) Sensor", category)
    }

    // MARK: - Temperature Smoothing (EMA) / 中文：温度平滑（EMA）

    private func smoothTemperature(raw: Double?, smoothed: inout Double?) -> Double? {
        guard let raw = raw, raw > 0, raw < 150 else { return smoothed }
        guard let current = smoothed else {
            smoothed = raw
            return raw
        }
        // Asymmetric smoothing: fast rise (alpha=0.7), slow fall (alpha=0.3) / 中文：非对称平滑：快速升温（alpha=0.7），缓慢降温（alpha=0.3）
        let alpha = raw > current ? 0.25 : smoothingAlpha
        let result = alpha * raw + (1 - alpha) * current
        smoothed = result
        return result
    }

    // MARK: - Cached Key Reading / 中文：缓存键读取

    private func readCpuTemperature() -> Double? {
        // Try cached key first — only switch on complete failure / 中文：优先尝试缓存键，仅在完全失败时切换
        if let key = cachedCpuKey {
            if let temp = readSMCTemperature(key: key), temp > 0, temp < 150 {
                cpuReadFailures = 0
                return temp
            }
            // Cached key failed — count failures before switching / 中文：缓存键失败时先累计失败次数再切换
            cpuReadFailures += 1
            if cpuReadFailures < 3 {
                // Transient failure, keep using same key next cycle / 中文：瞬时失败，下个周期继续使用同一个键
                return nil
            }
            cachedCpuKey = nil
        }
        // Full scan to find a new key / 中文：完整扫描以寻找新键
        let keys = cpuTempKeys + appleChipTempKeys
        for key in keys {
            if let temp = readSMCTemperature(key: key), temp > 0, temp < 150 {
                cachedCpuKey = key
                cpuReadFailures = 0
                return temp
            }
        }
        if cpuReadFailures >= maxConsecutiveFailures {
            DispatchQueue.main.async {
                self.lastError = "CPU temperature read failed \(self.cpuReadFailures) times"
            }
        }
        return nil
    }

    private func readGpuTemperature() -> Double? {
        if let key = cachedGpuKey {
            if let temp = readSMCTemperature(key: key), temp > 0, temp < 150 {
                gpuReadFailures = 0
                return temp
            }
            gpuReadFailures += 1
            if gpuReadFailures < 3 { return nil }
            cachedGpuKey = nil
        }
        // Intel keys first, then any GPU keys found by SMC enumeration — / 中文：Intel 键s first, then any GPU 键s found by SMC enumeration —
        // Apple Silicon GPU sensors use lowercase `Tg..` keys not listed here. / 中文：Apple Sil图标 GPU 传感器s use lowercase `Tg..` 键s not listed here.
        for key in gpuTempKeys + discoveredGpuKeys {
            if let temp = readSMCTemperature(key: key), temp > 0, temp < 150 {
                cachedGpuKey = key
                gpuReadFailures = 0
                return temp
            }
        }
        return nil
    }

    // MARK: - Reading Validation / 中文：读数校验

    private func validateFanRPM(_ rpm: Int) -> Int {
        max(0, min(FanRPMBounds.absoluteWriteMaxRPM, rpm))
    }
    
    // MARK: - SMC Data Parsing / 中文：SMC 数据解析
    
    // Type codes / 中文：类型代码
    private let DATA_TYPE_FLT = fourCharCodeFrom("flt ")
    private let DATA_TYPE_SP78 = fourCharCodeFrom("sp78")
    private let DATA_TYPE_FPE2 = fourCharCodeFrom("fpe2")
    private let DATA_TYPE_UINT8 = fourCharCodeFrom("ui8 ")
    private let DATA_TYPE_UINT16 = fourCharCodeFrom("ui16")
    private let DATA_TYPE_UINT32 = fourCharCodeFrom("ui32")
    private let DATA_TYPE_SINT16 = fourCharCodeFrom("si16")
    
    private func parseSMCBytes(_ bytes: SMCBytes, dataType: UInt32, dataSize: UInt32) -> Double? {
        // Read straight from the tuple. The previous version allocated a / 中文：直接从元组读取。旧版本每次调用都分配一个
        // 32-element `[UInt8]` on every call but only ever used the first four / 中文：32 元素的 `[UInt8]`，却只用到前 4 个字节——
        // bytes — wasted churn on a path that runs for every SMC key each tick. / 中文：在每个 tick 都为每个 SMC 键跑的热路径上纯属浪费。
        switch dataType {
        case DATA_TYPE_FLT:
            if dataSize == 4 {
                // Little-endian on Apple Silicon / Intel: byte 0 is the LSB. / 中文：Apple Silicon / Intel 均小端：字节 0 是最低有效字节。
                let bits = UInt32(bytes.0) | (UInt32(bytes.1) << 8)
                         | (UInt32(bytes.2) << 16) | (UInt32(bytes.3) << 24)
                return Double(Float32(bitPattern: bits))
            }

        case DATA_TYPE_SP78:
            if dataSize == 2 {
                // Fixed Point 7.8 (Signed) / 中文：7.8 定点数（有符号）
                // First bit is sign, next 7 are integer part, last 8 are fractional / 中文：第一位是符号位，后 7 位是整数部分，最后 8 位是小数部分
                let val = (Int(bytes.0) << 8) | Int(bytes.1)
                return Double(Int16(bitPattern: UInt16(val))) / 256.0
            }

        case DATA_TYPE_FPE2:
            if dataSize == 2 {
                // Fixed Point 14.2 (Unsigned) / 中文：14.2 定点数（无符号）
                // First 14 bits are integer part, last 2 are fractional / 中文：前 14 位是整数部分，后 2 位是小数部分
                // Calculation: (Byte0 << 6) + (Byte1 >> 2) / 中文：计算方式：(Byte0 << 6) + (Byte1 >> 2)
                let val = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
                return Double(val)
            }

        case DATA_TYPE_UINT8:
            if dataSize == 1 {
                return Double(bytes.0)
            }

        case DATA_TYPE_UINT16:
            if dataSize == 2 {
                let val = (Int(bytes.0) << 8) + Int(bytes.1)
                return Double(val)
            }

        case DATA_TYPE_UINT32:
            if dataSize == 4 {
                let val = (UInt32(bytes.0) << 24) | (UInt32(bytes.1) << 16) | (UInt32(bytes.2) << 8) | UInt32(bytes.3)
                return Double(val)
            }

        case DATA_TYPE_SINT16:
            if dataSize == 2 {
                let val = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
                return Double(Int16(bitPattern: val))
            }

        default:
            // Check for potential fallback or unknown type / 中文：检查潜在回退或未知类型
            if dataSize == 2 {
                let val = (Int(bytes.0) << 8) + Int(bytes.1)
                return Double(val)
            }
        }

        return nil
    }
    
    // MARK: - SMC Read Operations / 中文：SMC 读取操作
    
    // Generic read that handles types automatically / 中文：自动处理类型的通用读取
    func readSMCValue(key: String) -> Double? {
        guard smcConnection != 0 else { return nil }
        
        let keyCode = fourCharCodeFrom(key)
        
        // 1. Get Key Info / 中文：1. 获取键信息
        var keyInfo: SMCKeyData_keyInfo_t
        if let cached = keyInfoCache[keyCode] {
            keyInfo = cached
        } else {
            var input = SMCParamStruct()
            input.key = keyCode
            input.data8 = SMC_CMD_READ_KEYINFO
            
            var output = SMCParamStruct()
            let inputSize = MemoryLayout<SMCParamStruct>.size
            var outputSize = MemoryLayout<SMCParamStruct>.size
            
            let result = IOConnectCallStructMethod(
                smcConnection,
                KERNEL_INDEX_SMC,
                &input,
                inputSize,
                &output,
                &outputSize
            )
            
            if result != kIOReturnSuccess || output.result != 0 {
                // print("SMC: Key info failed for \(key)") / 中文：调试输出示例。
                return nil
            }
            
            keyInfo = output.keyInfo
            // Validate keyInfo.dataSize / 中文：校验 keyInfo.dataSize
            if keyInfo.dataSize == 0 || keyInfo.dataSize > 32 {
                print("SMC: Invalid keyInfo.dataSize (\(keyInfo.dataSize)) for key \(key)")
                return nil
            }
            keyInfoCache[keyCode] = keyInfo
        }
        
        // 2. Read Data / 中文：2. 读取数据
        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = SMC_CMD_READ_BYTES
        
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.size
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        let result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            inputSize,
            &output,
            &outputSize
        )
        
        if result != kIOReturnSuccess || output.result != 0 {
            return nil
        }
        
        // Validate data size before parsing / 中文：解析前校验数据大小
        if keyInfo.dataSize == 0 || keyInfo.dataSize > 32 {
            print("SMC: Invalid read size \(keyInfo.dataSize) for key \(key)")
            return nil
        }
        
        // 3. Parse Data / 中文：3. 解析数据
        return parseSMCBytes(output.bytes, dataType: keyInfo.dataType, dataSize: keyInfo.dataSize)
    }

    private func readSMCTemperature(key: String) -> Double? {
        return readSMCValue(key: key)
    }
    
    private func readSMCFanSpeed(key: String) -> Int? {
        if let val = readSMCValue(key: key) {
            return Int(val)
        }
        return nil
    }
    
    // MARK: - SMC Write Operations / 中文：SMC 写入操作
    
    func writeSMCKey(_ key: String, value: Double) -> Bool {
        guard smcConnection != 0 else {
            print("SMC Write: No connection")
            return false
        }
        
        let keyCode = fourCharCodeFrom(key)
        
        // Get key info first / 中文：先获取键信息
        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = SMC_CMD_READ_KEYINFO
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        var result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        
        guard result == kIOReturnSuccess && output.result == 0 else {
            print("SMC Write: Failed to get key info for \(key)")
            return false
        }
        
        let keyInfo = output.keyInfo
        keyInfoCache[keyCode] = keyInfo
        
        // Prepare write / 中文：准备写入
        input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = SMC_CMD_WRITE_BYTES
        
        // Encode value based on type / 中文：按类型编码数值
        switch keyInfo.dataType {
        case DATA_TYPE_FLT:
            if keyInfo.dataSize == 4 {
                var floatVal = Float32(value)
                withUnsafeBytes(of: &floatVal) { buffer in
                    // SMC expects bytes, usually we write them directly / 中文：SMC 需要字节，通常直接写入
                    // But we might need to handle endianness? / 中文：但可能需要处理字节序？
                    // Verify: flt on SMC is usually native float? No, usually it's standard IEEE 754 / 中文：确认：SMC 的 flt 通常不是原生 float，而是标准 IEEE 754
                    // But passing through IOConnectCallStructMethod struct might require specific alignment / 中文：但通过 IOConnectCallStructMethod 结构传递时可能需要特定对齐
                    // Let's assume standard copy / 中文：这里假设使用标准拷贝
                    if buffer.count >= 4 {
                        input.bytes.0 = buffer[0]
                        input.bytes.1 = buffer[1]
                        input.bytes.2 = buffer[2]
                        input.bytes.3 = buffer[3]
                    }
                }
            } else {
                print("SMC Write: flt type but size is \(keyInfo.dataSize)")
                return false
            }
            
        case DATA_TYPE_FPE2:
            // Fixed Point 14.2 (Unsigned) / 中文：14.2 定点数（无符号）
            // (UInt8(self >> 6), UInt8((self << 2) ^ ((self >> 6) << 8))) / 中文：SMCKit 参考编码表达式。
            let intVal = Int(value)
            input.bytes.0 = UInt8(intVal >> 6)
            input.bytes.1 = UInt8((intVal << 2) & 0xFF) // Simplified from SMCKit logic, verify if needed
            // SMCKit: UInt8((self << 2) ^ ((self >> 6) << 8)) / 中文：SMCKit 写法：UInt8((self << 2) ^ ((self >> 6) << 8))
            // Let's use strict SMCKit logic: / 中文：这里采用严格的 SMCKit 逻辑：
            // byte1 = (self << 2) is the lower 6 bits moved up / 中文：byte1 = (self << 2) 表示低 6 位上移
            // the XOR part seems complex, let's stick to standard 14.2 encoding: / 中文：XOR 部分较复杂，这里沿用标准 14.2 编码：
            // High byte: top 8 bits of 14-bit integer / 中文：高字节：14 位整数的高 8 位
            // Low byte: bottom 6 bits of 14-bit integer << 2 / 中文：低字节：14 位整数的低 6 位左移 2 位
            
            // Re-evaluating SMCKit logic: / 中文：重新评估 SMCKit 逻辑：
            // (self >> 6) is high byte. / 中文：(self >> 6) 是高字节。
            // (self << 2) puts bottom 6 bits into top of low byte / 中文：(self << 2) 将低 6 位放入低字节的高位
            // ^ ((self >> 6) << 8) -> this part cancels out high bits if they remained? / 中文：^ ((self >> 6) << 8) -> 这部分可能用于抵消残留高位？
            // Actually, if we just cast to UInt8, high bits are truncated. / 中文：实际上，如果直接转为 UInt8，高位会被截断。
            // So input.bytes.0 = UInt8(intVal >> 6) is correct for high byte. / 中文：因此 input.bytes.0 = UInt8(intVal >> 6) 作为高字节是正确的。
            // For low byte: (intVal & 0x3F) << 2. / 中文：低字节为：(intVal & 0x3F) << 2。
            input.bytes.1 = UInt8((intVal & 0x3F) << 2)
            
        case DATA_TYPE_SP78:
            // Internal 7.8 -> val * 256 / 中文：内部 7.8 格式 -> val * 256
            let intVal = Int16(value * 256.0)
            let uintVal = UInt16(bitPattern: intVal)
            input.bytes.0 = UInt8((uintVal >> 8) & 0xFF)
            input.bytes.1 = UInt8(uintVal & 0xFF)
            
        case DATA_TYPE_UINT8:
            input.bytes.0 = UInt8(value)
            
        case DATA_TYPE_UINT16:
            let intVal = UInt16(value)
            input.bytes.0 = UInt8((intVal >> 8) & 0xFF)
            input.bytes.1 = UInt8(intVal & 0xFF)
            
        case DATA_TYPE_UINT32:
            let intVal = UInt32(value)
            input.bytes.0 = UInt8((intVal >> 24) & 0xFF)
            input.bytes.1 = UInt8((intVal >> 16) & 0xFF)
            input.bytes.2 = UInt8((intVal >> 8) & 0xFF)
            input.bytes.3 = UInt8(intVal & 0xFF)
            
        default:
            // Fallback: try as uint16/uint8 based on value / 中文：回退：根据数值尝试 uint16/uint8
            if keyInfo.dataSize == 1 {
                input.bytes.0 = UInt8(value)
            } else if keyInfo.dataSize == 2 {
                let intVal = UInt16(value)
                input.bytes.0 = UInt8((intVal >> 8) & 0xFF)
                input.bytes.1 = UInt8(intVal & 0xFF)
            } else {
                print("SMC Write: Unknown type \(stringFrom(fourCharCode: keyInfo.dataType))")
                return false
            }
        }
        
        output = SMCParamStruct()
        outputSize = MemoryLayout<SMCParamStruct>.size
        
        result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        
        // Note: result might be kIOReturnNotPrivileged if not root / 中文：注意：非 root 时结果可能是 kIOReturnNotPrivileged
        if result == kIOReturnSuccess {
            print("SMC Write: Successfully wrote \(key) = \(value)")
            return true
        } else {
            print("SMC Write: Failed to write \(key): \(describeIOReturn(result))")
            return false
        }
    }
    
    // MARK: - Alternative Methods (for Apple Silicon) / 中文：替代方案（用于 Apple Silicon）
    
    func readTemperatureUsingPowermetrics() async -> Double? {
        // powermetrics requires root privileges / 中文：powermetrics 需要 root 权限
        // This is a fallback for Apple Silicon Macs where SMC may not work directly / 中文：这是 Apple Silicon Mac 上 SMC 不能直接工作时的回退方案
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["--samplers", "smc", "-n", "1", "-i", "100"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse temperature from powermetrics output / 中文：从 powermetrics 输出解析温度
                // Format: "CPU die temperature: XX.XX C" / 中文：格式："CPU die temperature: XX.XX C"
                let pattern = #"CPU die temperature:\s*([\d.]+)"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range(at: 1), in: output),
                   let temp = Double(output[range]) {
                    return temp
                }
            }
        } catch {
            print("Powermetrics error: \(error)")
        }
        
        return nil
    }
}
