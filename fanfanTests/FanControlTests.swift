//
//  File: FanControlTests.swift / 文件：FanControlTests.swift
//  Target: fanfanTests / 目标：fanfanTests
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Unit tests for fan control behavior. / 描述：风扇控制行为的单元测试。
//

import XCTest
@testable import fanfan

@MainActor
final class FanControlTests: XCTestCase {
    private let fanDefaultsKeys = [
        "fanControlMode",
        "perFanManualControl",
        "manualFanSpeed",
        "manualFanSpeedsPerFan",
        "autoThreshold",
        "autoMaxSpeed",
        "autoAggressiveness",
        "powerStrategy",
        "pidKpCustom",
        "pidKiCustom",
        "pidKdCustom"
    ]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedDefaults = fanDefaultsKeys.reduce(into: [:]) { result, key in
            result[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in fanDefaultsKeys {
            if let value = savedDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedDefaults.removeAll()
        super.tearDown()
    }

    
    func testControlModeEnum() {
        XCTAssertEqual(ControlMode.manual, ControlMode.manual)
        XCTAssertEqual(ControlMode.automatic, ControlMode.automatic)
        XCTAssertNotEqual(ControlMode.manual, ControlMode.automatic)
    }
    
    func testFanControllerInitialization() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)
        
        XCTAssertEqual(controller.mode, .automatic)
        XCTAssertGreaterThanOrEqual(controller.manualSpeed, FanRPMBounds.absoluteWriteMinRPM)
        XCTAssertLessThanOrEqual(controller.manualSpeed, FanRPMBounds.absoluteWriteMaxRPM)
    }
    
    func testFanControllerManualSpeed() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)

        controller.setMode(.manual)
        
        controller.setManualSpeed(3000)
        XCTAssertEqual(controller.manualSpeed, 3000)
        
        // Test clamping (no SMC data yet → unified limits fall back to `FanRPMBounds`) / 中文：测试夹取逻辑（尚无 SMC 数据时，统一限制回退到 `FanRPMBounds`）
        controller.setManualSpeed(10000)
        XCTAssertLessThanOrEqual(controller.manualSpeed, FanRPMBounds.fallbackMaxWhenSMCUnreadable)
        
        controller.setManualSpeed(500)
        XCTAssertGreaterThanOrEqual(controller.manualSpeed, FanRPMBounds.fallbackMinWhenSMCUnreadable)
    }
    
    func testFanControllerModeSwitch() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)
        
        XCTAssertEqual(controller.mode, .automatic)
        
        controller.setMode(.manual)
        XCTAssertEqual(controller.mode, .manual)

        controller.setMode(.automatic)
        XCTAssertEqual(controller.mode, .automatic)
    }
    
    func testPowerStrategyDefault() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)

        // A fresh install starts on the balanced strategy. / 中文：全新安装默认为均衡策略。
        XCTAssertEqual(controller.powerStrategy, .balanced)
    }

    func testPowerStrategyAppliesPreset() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)

        // Selecting a named strategy fills the core auto parameters from its / 中文：选择具名策略会用该档预设
        // preset (target temp + response notch). / 中文：填好核心自动参数（目标温度 + 响应档位）。
        controller.setPowerStrategy(.powerSaving)
        XCTAssertEqual(controller.powerStrategy, .powerSaving)
        XCTAssertEqual(controller.autoThreshold, PowerStrategy.powerSaving.targetTemp!)
        XCTAssertEqual(controller.autoAggressiveness, PowerStrategy.powerSaving.aggressiveness!)

        controller.setPowerStrategy(.performance)
        XCTAssertEqual(controller.autoThreshold, PowerStrategy.performance.targetTemp!)
        XCTAssertEqual(controller.autoAggressiveness, PowerStrategy.performance.aggressiveness!)
    }

    func testManualTuneFlipsStrategyToCustom() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)

        controller.setPowerStrategy(.balanced)
        XCTAssertEqual(controller.powerStrategy, .balanced)

        // Hand-tuning any auto slider leaves the named presets behind. / 中文：手动调任一自动滑块即离开具名预设。
        controller.setAutoThreshold(63)
        XCTAssertEqual(controller.powerStrategy, .custom)
    }

    func testPowerStrategyPersists() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)

        controller.setPowerStrategy(.performance)
        XCTAssertEqual(controller.powerStrategy, .performance)

        // A freshly constructed controller reads the persisted value. / 中文：新建的控制器会读取已持久化的值。
        let reloaded = FanController(systemMonitor: SystemMonitor())
        XCTAssertEqual(reloaded.powerStrategy, .performance)
    }

    func testUserDefaultsManager() {
        let manager = UserDefaultsManager.shared
        
        // Test control mode / 中文：测试控制模式
        manager.controlMode = .automatic
        XCTAssertEqual(manager.controlMode, .automatic)
        
        manager.controlMode = .manual
        XCTAssertEqual(manager.controlMode, .manual)
        
        // Test manual speed / 中文：测试手动转速
        manager.manualFanSpeed = 2500
        XCTAssertEqual(manager.manualFanSpeed, 2500)
        
        // Test auto threshold / 中文：测试自动阈值
        manager.autoThreshold = 65.0
        XCTAssertEqual(manager.autoThreshold, 65.0)
        
        // Test auto max speed / 中文：测试自动最大转速
        manager.autoMaxSpeed = 5000
        XCTAssertEqual(manager.autoMaxSpeed, 5000)
    }
    
    func testFanControlViewModelInitialization() {
        let viewModel = FanControlViewModel()
        
        XCTAssertNotNil(viewModel)
        XCTAssertEqual(viewModel.controlMode, .automatic)
        XCTAssertEqual(viewModel.fanSpeeds.count, 0)
    }
    
    func testTemperatureLevelClassification() {
        // No / invalid temperature → nil / 中文：无温度或温度无效时返回 nil
        XCTAssertNil(TemperatureLevel.of(nil))
        XCTAssertNil(TemperatureLevel.of(0))

        // Cool (< 50) / 中文：偏凉（< 50）
        XCTAssertEqual(TemperatureLevel.of(45.0), .cool)

        // Normal (50–68) / 中文：正常（50–68）
        XCTAssertEqual(TemperatureLevel.of(65.0), .normal)

        // Warm (68–80) / 中文：偏热（68–80）
        XCTAssertEqual(TemperatureLevel.of(75.0), .warm)

        // Hot (80–90) / 中文：高温（80–90）
        XCTAssertEqual(TemperatureLevel.of(85.0), .hot)

        // Critical (>= 90) / 中文：严重高温（>= 90）
        XCTAssertEqual(TemperatureLevel.of(100.0), .critical)
    }
    
    func testMaxTemperatureCalculation() {
        let viewModel = FanControlViewModel()
        
        viewModel.cpuTemperature = 50.0
        viewModel.gpuTemperature = 60.0
        XCTAssertEqual(viewModel.getMaxTemperature(), 60.0)
        
        viewModel.cpuTemperature = 70.0
        viewModel.gpuTemperature = 65.0
        XCTAssertEqual(viewModel.getMaxTemperature(), 70.0)
    }

    func testBatteryAmperageNormalizationHandlesTwosComplement() {
        XCTAssertEqual(BatteryMonitor.normalizedAmperage(-2_000), -2_000)
        XCTAssertEqual(
            BatteryMonitor.normalizedAmperage(Int(0xFFFF_F830)),
            -2_000
        )
        XCTAssertEqual(
            BatteryMonitor.normalizedAmperage(UInt64(bitPattern: Int64(-2_000))),
            -2_000
        )
    }

    func testDaemonPingRequiresMatchingProtocolVersion() {
        XCTAssertEqual(SMCDaemonClient.pingVersion(from: "OK pong 2 idle"), 2)
        XCTAssertEqual(SMCDaemonClient.pingVersion(from: "OK pong 2 active"), 2)
        XCTAssertEqual(SMCDaemonClient.pingVersion(from: "OK pong 2 restoring"), 2)
        XCTAssertNil(SMCDaemonClient.pingVersion(from: "OK pong"))
        XCTAssertNil(SMCDaemonClient.pingVersion(from: "OK pong 2 trailing"))
        XCTAssertNil(SMCDaemonClient.pingVersion(from: "OKAY pong 2 idle"))
    }

    func testVersionComparisonHandlesUnevenComponents() {
        XCTAssertTrue(UpdateChecker.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(UpdateChecker.isVersion("1.1.9", newerThan: "1.2.0"))
    }

    func testPrivilegedInstallerEscaping() {
        let path = "/tmp/fan fan's \\\"bundle\\\""
        XCTAssertEqual(
            PermissionsManager.shellQuoted(path),
            "'/tmp/fan fan'\\''s \\\"bundle\\\"'"
        )
        XCTAssertEqual(
            PermissionsManager.appleScriptEscaped("a\\b\"c"),
            "a\\\\b\\\"c"
        )
    }

    func testUnifiedFanRangeUsesIntersection() {
        let viewModel = FanControlViewModel()
        viewModel.fanMinSpeeds = [1_000, 1_400]
        viewModel.fanMaxSpeeds = [5_500, 4_800]

        XCTAssertEqual(viewModel.effectiveUnifiedMinRPM, 1_400)
        XCTAssertEqual(viewModel.effectiveUnifiedMaxRPM, 4_800)
    }

    func testSensorSummaryPrefersHottestExplicitDevice() {
        let sensors = [
            SensorReading(id: "TH0P", name: "HDD Proximity", temperature: 35, category: .storage),
            SensorReading(id: "TN0D", name: "SSD Diode", temperature: 65, category: .storage),
            SensorReading(id: "TN1P", name: "NAND", temperature: 58, category: .storage),
            SensorReading(id: "TB0T", name: "Battery 1", temperature: 34, category: .battery),
            SensorReading(id: "TB1T", name: "Battery 2", temperature: 39, category: .battery)
        ]

        XCTAssertEqual(FanControlViewModel.ssdTemperature(in: sensors), 65)
        XCTAssertEqual(FanControlViewModel.batterySensorTemperature(in: sensors), 39)
    }

    func testPIDOverrideStartsFromExactEffectiveGains() {
        let controller = FanController(systemMonitor: SystemMonitor())
        let gains = (
            controller.effectivePIDKp,
            controller.effectivePIDKi,
            controller.effectivePIDKd
        )

        controller.setPIDGains(kp: gains.0, ki: gains.1, kd: gains.2)

        XCTAssertEqual(controller.effectivePIDKp, gains.0)
        XCTAssertEqual(controller.effectivePIDKi, gains.1)
        XCTAssertEqual(controller.effectivePIDKd, gains.2)
    }
}
