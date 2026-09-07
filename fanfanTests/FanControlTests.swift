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

    func testHelperReadinessPollingCoversLaunchdThrottle() {
        var elapsed = 0.0
        var checks = 0

        let ready = PermissionsManager.waitUntil(
            timeout: 20,
            pollInterval: 0.25,
            now: { elapsed },
            sleep: { elapsed += $0 }
        ) {
            checks += 1
            return elapsed >= 10
        }

        XCTAssertTrue(ready)
        XCTAssertEqual(elapsed, 10, accuracy: 0.001)
        XCTAssertEqual(checks, 41)
    }

    func testHelperReadinessPollingStopsAtDeadline() {
        var elapsed = 0.0

        let ready = PermissionsManager.waitUntil(
            timeout: 2,
            pollInterval: 0.25,
            now: { elapsed },
            sleep: { elapsed += $0 },
            check: { false }
        )

        XCTAssertFalse(ready)
        XCTAssertEqual(elapsed, 2, accuracy: 0.001)
    }

    func testStaleHelperCheckCannotOverwriteInstallResult() {
        XCTAssertTrue(PermissionsManager.shouldApplyStatusResult(
            generation: 4,
            currentGeneration: 4,
            isInstalling: false
        ))
        XCTAssertFalse(PermissionsManager.shouldApplyStatusResult(
            generation: 3,
            currentGeneration: 4,
            isInstalling: false
        ))
        XCTAssertFalse(PermissionsManager.shouldApplyStatusResult(
            generation: 4,
            currentGeneration: 4,
            isInstalling: true
        ))
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

    // MARK: - Spin-down convergence / 中文：降速收敛

    /// Replays a full descent. The dead-band (450) is wider than one ramp step
    /// (250), so gating every step on the band stranded the fan above target
    /// once the remaining gap fell into the 250..<450 window.
    func testSpinDownReachesTargetInsteadOfStallingInsideDeadBand() {
        let spinUp = 200, spinDown = 450, rampUp = 800, rampDown = 250
        var current = 3000
        let target = 2000
        var underWay = false

        for _ in 0..<40 {
            let decision = FanController.deadBandDecision(
                delta: target - current,
                spinDownUnderWay: underWay,
                spinUpHysteresisRPM: spinUp,
                spinDownHysteresisRPM: spinDown
            )
            underWay = decision.spinDownUnderWay
            guard decision.apply else { break }
            let step = FanController.rampStep(
                from: current, to: target,
                rampUpStep: rampUp, rampDownStep: rampDown
            )
            current = step.next
            underWay = step.spinDownUnderWay
        }

        XCTAssertEqual(current, target, "spin-down must converge, not stall above target")
        XCTAssertFalse(underWay, "reaching the target ends the descent")
    }

    /// The band must still absorb small dips, or the anti-pumping design is lost.
    func testSmallDipDoesNotStartSpinDown() {
        let decision = FanController.deadBandDecision(
            delta: -300,                 // below the 450 band
            spinDownUnderWay: false,
            spinUpHysteresisRPM: 200,
            spinDownHysteresisRPM: 450
        )
        XCTAssertFalse(decision.apply)
        XCTAssertFalse(decision.spinDownUnderWay)
    }

    /// A spin-up cancels an in-flight descent so the next dip is gated again.
    func testSpinUpClearsInFlightSpinDown() {
        let decision = FanController.deadBandDecision(
            delta: 250,
            spinDownUnderWay: true,
            spinUpHysteresisRPM: 200,
            spinDownHysteresisRPM: 450
        )
        XCTAssertTrue(decision.apply)
        XCTAssertFalse(decision.spinDownUnderWay)
    }

    // MARK: - Critical-temperature ceiling / 中文：临界温度上限

    /// Replays the descent out of a critical spike. The ramp-down clamp used to
    /// cap on the hardware maximum alone, so every intermediate step ran above
    /// the user ceiling for the whole descent — minutes of over-ceiling RPM.
    func testDescentFromCriticalNeverExceedsUserCeiling() {
        let fanMin = 1_200, fanMax = 6_500
        let autoCeiling = 3_600          // the user's configured maximum
        var current = fanMax             // parked at full speed by the spike
        let target = autoCeiling

        for _ in 0..<200 {
            let step = FanController.rampStep(
                from: current, to: target,
                rampUpStep: 800, rampDownStep: 250
            )
            current = FanController.clampFanTarget(
                step.next,
                fanMin: fanMin,
                fanMax: fanMax,
                autoCeiling: autoCeiling,
                isCritical: false        // the spike is over
            )
            XCTAssertLessThanOrEqual(
                current, autoCeiling,
                "no step of the descent may run above the user ceiling"
            )
            if current == target { break }
        }

        XCTAssertEqual(current, target, "the descent must still reach the ceiling")
    }

    // MARK: - Thermal-protection soft ceiling / 中文：高温保护软上限

    /// Below the onset the user's ceiling is absolute — protection must never
    /// cost RPM headroom during ordinary use.
    func testCeilingIsAbsoluteBelowProtectionOnset() {
        for temp in [40.0, 70.0, 84.9, 85.0] {
            XCTAssertEqual(
                FanController.softCeiling(
                    userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: temp
                ),
                3_600,
                "\(temp) °C is below the band; the user ceiling must hold exactly"
            )
        }
    }

    /// Inside the band the ceiling rises monotonically and stays bounded, so
    /// protection buys the RPM the temperature calls for — not full speed.
    func testCeilingRisesMonotonicallyAcrossProtectionBand() {
        let userCeiling = 3_600, hardwareMax = 6_500
        var previous = userCeiling

        for tenth in 850...950 {
            let ceiling = FanController.softCeiling(
                userCeiling: userCeiling,
                hardwareMax: hardwareMax,
                safetyTemperature: Double(tenth) / 10
            )
            XCTAssertGreaterThanOrEqual(ceiling, previous, "the ceiling must never dip")
            XCTAssertLessThanOrEqual(ceiling, hardwareMax)
            previous = ceiling
        }

        XCTAssertEqual(previous, hardwareMax, "the band must end at the hardware maximum")
    }

    /// The midpoint must be a genuine intermediate, not a disguised jump to full
    /// speed — that gradation is the whole point of the band.
    func testCeilingMidBandIsIntermediateNotFullSpeed() {
        let ceiling = FanController.softCeiling(
            userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: 90
        )
        XCTAssertGreaterThan(ceiling, 3_600)
        XCTAssertLessThan(ceiling, 6_500)
        // smoothstep is symmetric, so the midpoint sits halfway up the span.
        XCTAssertEqual(ceiling, 5_050)
    }

    /// At and above critical the ceiling is the hardware maximum.
    func testCeilingReachesHardwareMaxAtCritical() {
        XCTAssertEqual(
            FanController.softCeiling(
                userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: 95
            ),
            6_500
        )
        XCTAssertEqual(
            FanController.softCeiling(
                userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: 110
            ),
            6_500
        )
    }

    /// A ceiling already at or above the hardware maximum has nothing to lift,
    /// and protection must not somehow push past the hardware.
    func testCeilingAtHardwareMaxIsUnchangedByProtection() {
        XCTAssertEqual(
            FanController.softCeiling(
                userCeiling: 6_500, hardwareMax: 6_500, safetyTemperature: 92
            ),
            6_500
        )
        XCTAssertEqual(
            FanController.softCeiling(
                userCeiling: 9_000, hardwareMax: 6_500, safetyTemperature: 92
            ),
            6_500
        )
    }

    /// Cooling retraces the same curve, so the ceiling comes back down on its
    /// own — the descent needs no special case.
    func testCeilingRetractsSymmetricallyOnCooling() {
        // The ceiling is a function of temperature alone, so cooling back
        // through the band returns the same ceilings the heating pass produced.
        let ascending = stride(from: 86.0, through: 94.0, by: 1.0).map {
            FanController.softCeiling(
                userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: $0
            )
        }
        let descending = stride(from: 94.0, through: 86.0, by: -1.0).map {
            FanController.softCeiling(
                userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: $0
            )
        }
        XCTAssertEqual(ascending, descending.reversed(), "no hysteresis in the ceiling itself")
        XCTAssertEqual(
            FanController.softCeiling(
                userCeiling: 3_600, hardwareMax: 6_500, safetyTemperature: 84
            ),
            3_600,
            "back below the onset the user ceiling is absolute again"
        )
    }

    // MARK: - Real hardware / 中文：真实硬件参数

    /// The other cases use a round 6500 that belongs to no particular Mac. These
    /// pin the behaviour to real SMC values, read off a MacBook Pro Mac16,7
    /// (M4 Pro, two fans): F0Mn/F1Mn 1350, F0Mx/F1Mx 5777. The fallback constant
    /// for an unreadable F%dMx is 5200, so a machine-shaped ceiling is not the
    /// same number as the placeholder and is worth asserting separately.
    /// 中文：其余用例用的 6500 不属于任何真机。这些用例锁定真实 SMC 值：
    /// MacBook Pro Mac16,7（M4 Pro，双风扇），Mn 1350 / Mx 5777。
    private enum M4Pro {
        static let fanMin = 1_350
        static let fanMax = 5_777
        static let userCeiling = 3_600
    }

    func testSoftCeilingOnRealM4ProLimits() {
        func ceiling(at temp: Double) -> Int {
            FanController.softCeiling(
                userCeiling: M4Pro.userCeiling,
                hardwareMax: M4Pro.fanMax,
                safetyTemperature: temp
            )
        }

        // Ordinary use must cost nothing: the configured ceiling holds exactly.
        XCTAssertEqual(ceiling(at: 70), M4Pro.userCeiling)
        XCTAssertEqual(ceiling(at: 85), M4Pro.userCeiling)

        // Mid-band buys a real intermediate rather than jumping to full speed —
        // the old binary switch went straight to 5777 at 90 °C.
        let atNinety = ceiling(at: 90)
        XCTAssertEqual(atNinety, 4_689)
        XCTAssertLessThan(atNinety, M4Pro.fanMax)

        // Only the throttle-adjacent end reaches the hardware maximum.
        XCTAssertEqual(ceiling(at: 95), M4Pro.fanMax)
    }

    /// End to end on real limits: a spike to the hardware maximum, then a cooled
    /// descent. This is the bug the user hit — a 3600 ceiling that the fan ran
    /// past for the whole ramp down.
    func testDescentOnRealM4ProLimitsStaysAtCeilingOnceCool() {
        let ceiling = FanController.softCeiling(
            userCeiling: M4Pro.userCeiling,
            hardwareMax: M4Pro.fanMax,
            safetyTemperature: 70          // cooled back to ordinary use
        )
        XCTAssertEqual(ceiling, M4Pro.userCeiling)

        var current = M4Pro.fanMax         // parked at full speed by the spike
        for _ in 0..<200 {
            let step = FanController.rampStep(
                from: current, to: ceiling,
                rampUpStep: 800, rampDownStep: 250
            )
            current = FanController.clampFanTarget(
                step.next,
                fanMin: M4Pro.fanMin,
                fanMax: M4Pro.fanMax,
                autoCeiling: ceiling,
                isCritical: false
            )
            XCTAssertLessThanOrEqual(
                current, M4Pro.userCeiling,
                "on real M4 Pro limits no descent step may exceed the 3600 setting"
            )
            if current == ceiling { break }
        }
        XCTAssertEqual(current, ceiling)
    }

    /// The safety channel is the one sanctioned way past the ceiling, and it
    /// stops at the fan's own hardware maximum.
    func testCriticalTemperatureOverridesCeilingUpToHardwareMax() {
        XCTAssertEqual(
            FanController.clampFanTarget(
                3_600, fanMin: 1_200, fanMax: 6_500,
                autoCeiling: 3_600, isCritical: true
            ),
            6_500
        )
    }

    /// Below the ceiling nothing changes, and the fan floor still wins.
    func testClampFanTargetHonoursFloorAndCeiling() {
        XCTAssertEqual(
            FanController.clampFanTarget(
                2_000, fanMin: 1_200, fanMax: 6_500,
                autoCeiling: 3_600, isCritical: false
            ),
            2_000
        )
        XCTAssertEqual(
            FanController.clampFanTarget(
                800, fanMin: 1_200, fanMax: 6_500,
                autoCeiling: 3_600, isCritical: false
            ),
            1_200
        )
        // A ceiling above this fan's hardware maximum cannot lift it.
        XCTAssertEqual(
            FanController.clampFanTarget(
                9_000, fanMin: 1_200, fanMax: 4_800,
                autoCeiling: 6_000, isCritical: false
            ),
            4_800
        )
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
