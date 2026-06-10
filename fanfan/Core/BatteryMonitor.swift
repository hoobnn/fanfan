//
//  File: BatteryMonitor.swift / 文件：BatteryMonitor.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Battery and power information using IOKit. / 描述：使用 IOKit 读取电池和电源信息。
//

import Foundation
import IOKit.ps
import Combine

struct BatteryInfo: Equatable {
    var percentage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var cycleCount: Int = 0
    var health: Int = 100  // Maximum capacity %
    var condition: String = "Normal"
    var temperature: Double? = nil  // in Celsius
    var voltage: Double? = nil  // in Volts
    var amperage: Int? = nil  // in mA (negative = discharging)
    var timeRemaining: Int? = nil  // minutes
    var designCapacity: Int? = nil  // mAh
    var maxCapacity: Int? = nil  // mAh (actual current max)
    var currentCapacity: Int? = nil  // mAh
    var fullyCharged: Bool = false
    
    var healthDescription: String {
        if health >= 80 {
            return "Good"
        } else if health >= 60 {
            return "Fair"
        } else {
            return "Poor"
        }
    }
    
    var formattedTimeRemaining: String? {
        guard let time = timeRemaining, time > 0 else { return nil }
        let hours = time / 60
        let minutes = time % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    // Power in Watts (calculated from voltage and amperage) / 中文：功率（瓦特），由电压和电流计算
    var powerWatts: Double? {
        guard let voltage = voltage, let amp = amperage else { return nil }
        // voltage is in V, amperage in mA / 中文：电压单位为 V，电流单位为 mA
        // Power = V * A = V * (mA/1000) / 中文：功率 = V * A = V * (mA/1000)
        return abs(voltage * Double(amp) / 1000.0)
    }
}

class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    
    @Published var batteryInfo = BatteryInfo()
    @Published var hasBattery = false
    
    private var timer: Timer?
    
    init() {
        updateBatteryInfo()
    }
    
    func startMonitoring() {
        timer?.invalidate()
        updateBatteryInfo()
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.updateBatteryInfo()
        }
        // Battery data drifts slowly; a generous tolerance lets the kernel / 中文：电池数据变化缓慢；宽松的 tolerance 让内核
        // batch this wake with other work. / 中文：把该唤醒与其他工作合并。
        timer.tolerance = 2.0
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    func updateBatteryInfo() {
        // Use IOKit to get battery info / 中文：使用 IOKit 获取电池信息
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        guard sources.count > 0 else {
            DispatchQueue.main.async {
                if self.hasBattery {
                    self.hasBattery = false
                }
            }
            return
        }
        
        DispatchQueue.main.async {
            if !self.hasBattery {
                self.hasBattery = true
            }
        }
        
        for ps in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as? [String: Any] else {
                continue
            }
            
            var newInfo = BatteryInfo()
            
            // Basic info from IOPowerSources / 中文：来自 IOPowerSources 的基础信息
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                newInfo.percentage = capacity
            }
            
            if let isCharging = info[kIOPSIsChargingKey] as? Bool {
                newInfo.isCharging = isCharging
            }
            
            if let powerSource = info[kIOPSPowerSourceStateKey] as? String {
                newInfo.isPluggedIn = (powerSource == kIOPSACPowerValue)
            }
            
            if let fullyCharged = info[kIOPSIsChargedKey] as? Bool {
                newInfo.fullyCharged = fullyCharged
            }
            
            if let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
                newInfo.timeRemaining = timeToEmpty
            } else if let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
                newInfo.timeRemaining = timeToFull
            }
            
            // Get detailed info from IORegistry / 中文：从 IORegistry 获取详细信息
            self.getDetailedBatteryInfo(&newInfo)
            
            DispatchQueue.main.async {
                if self.batteryInfo != newInfo {
                    self.batteryInfo = newInfo
                }
            }
        }
    }
    
    private func getDetailedBatteryInfo(_ info: inout BatteryInfo) {
        // Access AppleSmartBattery for detailed info / 中文：访问 AppleSmartBattery 获取详细信息
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        
        // Cycle Count / 中文：循环次数
        if let cycleCount = getIORegistryProperty(service: service, key: "CycleCount") as? Int {
            info.cycleCount = cycleCount
        }
        
        // Design Capacity (original capacity in mAh) / 中文：设计容量（原始容量，单位 mAh）
        if let designCap = getIORegistryProperty(service: service, key: "DesignCapacity") as? Int {
            info.designCapacity = designCap
        }
        
        // NominalChargeCapacity is what Apple uses for "Maximum Capacity" percentage / 中文：NominalChargeCapacity 是 Apple 用来计算“最大容量”百分比的字段。
        // This matches the value shown in System Information / 中文：这与“系统信息”中显示的值一致。
        if let nominalCap = getIORegistryProperty(service: service, key: "NominalChargeCapacity") as? Int {
            info.maxCapacity = nominalCap
            // Calculate health: this matches Apple's "Maximum Capacity" in System Info / 中文：计算健康度：该值对应“系统信息”里的 Apple“最大容量”。
            if let designCap = info.designCapacity, designCap > 0 {
                info.health = (nominalCap * 100) / designCap
            }
        } else if let rawMaxCap = getIORegistryProperty(service: service, key: "AppleRawMaxCapacity") as? Int {
            // Fallback to AppleRawMaxCapacity if NominalChargeCapacity not available / 中文：如果没有 NominalChargeCapacity，则回退使用 AppleRawMaxCapacity。
            info.maxCapacity = rawMaxCap
            if let designCap = info.designCapacity, designCap > 0 {
                info.health = (rawMaxCap * 100) / designCap
            }
        }
        
        // Current capacity in mAh / 中文：当前容量，单位 mAh
        if let rawCurrentCap = getIORegistryProperty(service: service, key: "AppleRawCurrentCapacity") as? Int {
            info.currentCapacity = rawCurrentCap
        }
        
        // Temperature (in 0.1 Kelvin units, e.g., 3060 = 306.0K = 32.85°C) / 中文：温度以 0.1 Kelvin 为单位，例如 3060 表示 306.0K，即 32.85°C。
        if let temp = getIORegistryProperty(service: service, key: "Temperature") as? Int {
            // Temperature is in deciKelvin (0.1K units) / 中文：温度单位为 deciKelvin（0.1K）
            // Convert: (temp / 10) - 273.15 = Celsius / 中文：转换：(temp / 10) - 273.15 = 摄氏度
            info.temperature = (Double(temp) / 10.0) - 273.15
        }
        
        // Voltage in mV, convert to V / 中文：电压单位为 mV，转换为 V
        if let voltage = getIORegistryProperty(service: service, key: "Voltage") as? Int {
            info.voltage = Double(voltage) / 1000.0  // Convert mV to V
        }
        
        // Amperage - stored as unsigned 64-bit representing negative values when discharging / 中文：电流以无符号 64 位保存，放电时用大整数表示负值。
        // Try multiple casting approaches since IORegistry can return different types / 中文：IORegistry 可能返回不同类型，因此尝试多种转换方式。
        let amperageValue = getIORegistryProperty(service: service, key: "InstantAmperage") 
            ?? getIORegistryProperty(service: service, key: "Amperage")
        
        if let amperage = amperageValue {
            // Try to get the raw value and convert to signed / 中文：尝试获取原始值并转换为有符号整数。
            if let uint64Val = amperage as? UInt64 {
                info.amperage = Int(Int64(bitPattern: uint64Val))
            } else if let int64Val = amperage as? Int64 {
                info.amperage = Int(int64Val)
            } else if let intVal = amperage as? Int {
                // If it's already signed but stored as large positive (overflow) / 中文：如果它本应是有符号值却以较大的正数保存，则按溢出情况处理。
                if intVal > Int(Int32.max) {
                    // This shouldn't happen with proper Int, but handle it / 中文：正常 Int 不应出现这种情况，但这里仍做兼容处理。
                    info.amperage = intVal - Int(UInt64.max) - 1
                } else {
                    info.amperage = intVal
                }
            } else if let nsNumber = amperage as? NSNumber {
                // NSNumber fallback - get the int64 value / 中文：NSNumber 回退：获取 int64 值
                let val = nsNumber.int64Value
                info.amperage = Int(val)
            }
        }
        
        // Battery Condition - matches Apple's System Information criteria / 中文：电池 Condition - matches Apple's System Information criteria
        // "Service Recommended" when Maximum Capacity drops to 80% or below / 中文：当最大容量降到 80% 或以下时显示“建议维修”。
        if let condition = getIORegistryProperty(service: service, key: "BatteryInstalled") as? Bool, !condition {
            info.condition = "Not Installed"
        } else if let permanentFailure = getIORegistryProperty(service: service, key: "PermanentFailureStatus") as? Int, permanentFailure != 0 {
            info.condition = "Service Battery"
        } else if info.health <= 80 {
            info.condition = "Service Recommended"
        } else {
            info.condition = "Normal"
        }
    }
    
    private func getIORegistryProperty(service: io_service_t, key: String) -> Any? {
        let cfKey = key as CFString
        guard let value = IORegistryEntryCreateCFProperty(service, cfKey, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue()
    }
    
    deinit {
        stopMonitoring()
    }
}
