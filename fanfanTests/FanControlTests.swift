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
        "powerStrategy",
        "powerStrategyPresetLayout",
        "strategyPreset.powerSaving",
        "strategyPreset.balanced",
        "strategyPreset.performance",
        "fanStrategies",
        "activeStrategyID",
        "scheduleEntries",
        "scheduleLastAppliedStamp",
        "autoAggressiveness"
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

    func testHighTemperatureAllowsManualSelectionDuringExistingEpisode() {
        for initialMode in [ControlMode.automatic, .system, .manual] {
            var policy = FanControlViewModel.HighTemperatureModeSwitch()
            XCTAssertEqual(policy.shouldSwitch(temperature: 92, mode: initialMode,
                                               enabled: false, alertThreshold: 85),
                           initialMode == .manual)
            for temperature in [92.0, 96, 89, 90, 85, 94] {
                XCTAssertFalse(policy.shouldSwitch(temperature: temperature, mode: .manual,
                                                   enabled: false, alertThreshold: 85))
            }
            XCTAssertFalse(policy.shouldSwitch(temperature: 84, mode: .manual,
                                               enabled: false, alertThreshold: 85))
            XCTAssertTrue(policy.shouldSwitch(temperature: 90, mode: .manual,
                                              enabled: false, alertThreshold: 85))
        }
    }

    func testOptionalHighTemperatureSwitchRearmsAndCriticalEscalates() {
        var policy = FanControlViewModel.HighTemperatureModeSwitch()
        XCTAssertFalse(policy.shouldSwitch(temperature: 85, mode: .manual,
                                           enabled: true, alertThreshold: 85))
        XCTAssertTrue(policy.shouldSwitch(temperature: 86, mode: .manual,
                                          enabled: true, alertThreshold: 85))
        XCTAssertFalse(policy.shouldSwitch(temperature: 88, mode: .manual,
                                           enabled: true, alertThreshold: 85))
        XCTAssertTrue(policy.shouldSwitch(temperature: 90, mode: .manual,
                                          enabled: true, alertThreshold: 85))
        XCTAssertFalse(policy.shouldSwitch(temperature: 95, mode: .manual,
                                           enabled: true, alertThreshold: 85))
        XCTAssertFalse(policy.shouldSwitch(temperature: 79, mode: .manual,
                                           enabled: true, alertThreshold: 85))
        XCTAssertTrue(policy.shouldSwitch(temperature: 86, mode: .manual,
                                          enabled: true, alertThreshold: 85))
    }

    func testDisabledHighTemperatureSwitchAndInvalidSamples() {
        var policy = FanControlViewModel.HighTemperatureModeSwitch()
        XCTAssertFalse(policy.shouldSwitch(temperature: 89, mode: .manual,
                                           enabled: false, alertThreshold: 85))
        XCTAssertTrue(policy.shouldSwitch(temperature: 90, mode: .manual,
                                          enabled: false, alertThreshold: 85))
        for temperature in [Double.nan, .infinity, -.infinity, 0, -10] {
            XCTAssertFalse(policy.shouldSwitch(temperature: temperature, mode: .manual,
                                               enabled: false, alertThreshold: 85))
        }
        XCTAssertFalse(policy.shouldSwitch(temperature: 92, mode: .manual,
                                           enabled: false, alertThreshold: 85))
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
    
    func testStrategiesStartWithTheBuiltIns() {
        let controller = FanController(systemMonitor: SystemMonitor())

        // A fresh install lists the three built-ins and starts on balanced. / 中文：全新安装列出三个内置策略，默认均衡。
        XCTAssertEqual(controller.strategies.map(\.id), FanStrategy.builtInIDs)
        XCTAssertEqual(controller.activeStrategyID, FanStrategy.balancedID)
    }

    func testSelectingAStrategyAppliesItsCurve() {
        let controller = FanController(systemMonitor: SystemMonitor())

        // The live ramp start follows the strategy's curve. / 中文：实时爬升起点跟随策略的曲线。
        controller.setActiveStrategy(FanStrategy.powerSavingID)
        XCTAssertEqual(controller.activeStrategyID, FanStrategy.powerSavingID)
        XCTAssertEqual(controller.autoThreshold, 80, accuracy: 0.001)

        controller.setActiveStrategy(FanStrategy.performanceID)
        XCTAssertEqual(controller.autoThreshold, 60, accuracy: 0.001)
    }

    func testSliderEditsReshapeTheActiveCurveAndResetRestoresIt() {
        let controller = FanController(systemMonitor: SystemMonitor())
        controller.setActiveStrategy(FanStrategy.balancedID)

        // Moving the ramp start shifts the curve and keeps the strategy selected, marked as adjusted. / 中文：移动爬升起点会平移曲线，策略仍保持选中并标记为已调整。
        controller.setAutoThreshold(70)
        XCTAssertEqual(controller.activeStrategyID, FanStrategy.balancedID)
        XCTAssertTrue(controller.activeStrategy.isModified)
        XCTAssertEqual(controller.autoThreshold, 70, accuracy: 0.001)

        // The adjustment survives a relaunch. / 中文：调整在重启后依然保留。
        let reloaded = FanController(systemMonitor: SystemMonitor())
        XCTAssertEqual(reloaded.activeStrategyID, FanStrategy.balancedID)
        XCTAssertEqual(reloaded.autoThreshold, 70, accuracy: 0.001)

        reloaded.resetStrategyCurve(for: FanStrategy.balancedID)
        XCTAssertEqual(reloaded.strategy(id: FanStrategy.balancedID)?.curve, FanStrategy.shippedCurve(for: FanStrategy.balancedID))
        XCTAssertFalse(reloaded.activeStrategy.isModified)
    }

    func testUserStrategyCanBeAddedRenamedAndDeleted() {
        let controller = FanController(systemMonitor: SystemMonitor())

        let id = controller.addStrategy(name: "Office")
        XCTAssertEqual(controller.strategy(id: id)?.displayName, "Office")
        XCTAssertNotEqual(controller.activeStrategyID, id, "Adding must not activate the new strategy")

        controller.renameStrategy(id, to: "  Quiet  ")
        XCTAssertEqual(controller.strategy(id: id)?.displayName, "Quiet")

        // A user strategy cannot be renamed to nothing. / 中文：用户策略不能改名为空。
        controller.renameStrategy(id, to: "   ")
        XCTAssertEqual(controller.strategy(id: id)?.displayName, "Quiet")

        controller.setActiveStrategy(id)
        controller.deleteStrategy(id)
        XCTAssertNil(controller.strategy(id: id))
        XCTAssertEqual(controller.activeStrategyID, FanStrategy.balancedID)

        // Built-ins cannot be deleted. / 中文：内置策略不可删除。
        controller.deleteStrategy(FanStrategy.balancedID)
        XCTAssertNotNil(controller.strategy(id: FanStrategy.balancedID))
    }

    func testBuiltInRenameWithEmptyNameRestoresTitle() {
        let controller = FanController(systemMonitor: SystemMonitor())

        controller.renameStrategy(FanStrategy.balancedID, to: "Mine")
        XCTAssertEqual(controller.strategy(id: FanStrategy.balancedID)?.displayName, "Mine")

        controller.renameStrategy(FanStrategy.balancedID, to: "")
        XCTAssertNil(controller.strategy(id: FanStrategy.balancedID)?.name)
        XCTAssertFalse(controller.strategy(id: FanStrategy.balancedID)?.displayName.isEmpty ?? true)
    }

    func testLegacyTiersMigrateToTheTierHoldingTheirValues() {
        XCTAssertEqual(FanController.migratedStrategy(.powerSaving, fromLayout: 0), .balanced)
        XCTAssertEqual(FanController.migratedStrategy(.balanced, fromLayout: 0), .performance)
        XCTAssertEqual(FanController.migratedStrategy(.performance, fromLayout: 0), .custom)
        XCTAssertEqual(FanController.migratedStrategy(.powerSaving, fromLayout: 2), .powerSaving)
    }

    func testLegacyCustomBecomesAUserStrategyThatStaysActive() {
        let defaults = UserDefaults.standard
        defaults.set("custom", forKey: "powerStrategy")
        defaults.set(68.0, forKey: "autoThreshold")
        defaults.set(1.0, forKey: "autoAggressiveness")

        // Upgrading must keep the values the user was running, not fall back to balanced. / 中文：升级必须保留用户正在使用的参数，而不是回退到均衡。
        let controller = FanController(systemMonitor: SystemMonitor())
        XCTAssertFalse(controller.activeStrategy.isBuiltIn)
        XCTAssertEqual(controller.activeStrategy.curve.rampStartTemp, 68, accuracy: 0.001)
        XCTAssertEqual(controller.autoThreshold, 68, accuracy: 0.001)
    }

    func testLegacyParametersConvertToTheSameCurveTheOldLawDrew() {
        // The old law: flat until the target, then `span × aggressiveness / 10` RPM per °C, capped at the ceiling. / 中文：旧定律：目标温度前保持下界，之后每 °C 增加 `span × 响应强度 / 10` RPM，并封顶。
        let floor = 1000.0
        let span = 4000.0
        let curve = StrategyPreset(targetTemp: 70, aggressiveness: 1.5, maxSpeedFraction: 0.5).curve
        for temp in stride(from: 40.0, through: 100.0, by: 1.0) {
            let legacy = floor + min(0.5 * span, max(0, span * 1.5 / 10 * (temp - 70)))
            XCTAssertEqual(floor + curve.fraction(at: temp) * span, legacy, accuracy: 1, "at \(temp) °C")
        }
    }

    func testLayoutThreeStrategiesWithPresetsDecodeToTheirCurves() throws {
        // Settings saved by the previous build stored `preset`, not `curve`. / 中文：上一版保存的设置存的是 `preset` 而非 `curve`。
        let json = #"[{"id":"balanced","preset":{"targetTemp":75,"aggressiveness":0.6,"maxSpeedFraction":0.35}}]"#
        let decoded = try JSONDecoder().decode([FanStrategy].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.curve, FanStrategy.shippedCurve(for: FanStrategy.balancedID))
    }

    func testCurveNormalizationKeepsOrderAndNeverFalls() {
        let curve = FanCurve(points: [
            CurvePoint(temp: 80, fraction: 0.6),
            CurvePoint(temp: 50, fraction: 0.4),
            CurvePoint(temp: 65, fraction: 0.1),
            CurvePoint(temp: 120, fraction: 2)
        ])
        XCTAssertEqual(curve.points.map(\.temp), [40, 50, 65, 80, 100])
        XCTAssertEqual(curve.points.map(\.fraction), [0.4, 0.4, 0.4, 0.6, 1.0])
    }

    func testCurveEndsArePinnedAtTheRangeBoundsWithoutChangingTheCurve() {
        let raw = FanCurve(points: [CurvePoint(temp: 60, fraction: 0), CurvePoint(temp: 80, fraction: 0.5)])
        XCTAssertEqual(raw.points.first, CurvePoint(temp: 40, fraction: 0))
        XCTAssertEqual(raw.points.last, CurvePoint(temp: 100, fraction: 0.5))
        XCTAssertEqual(raw.fraction(at: 70), 0.25, accuracy: 0.000001)

        // The ends keep their temperature; only the speed moves. / 中文：首尾点温度不动，只改转速。
        XCTAssertEqual(raw.movingPoint(at: 0, to: CurvePoint(temp: 55, fraction: 0)).points.first?.temp, 40)
        XCTAssertEqual(raw.movingPoint(at: 3, to: CurvePoint(temp: 90, fraction: 0.8)).points.last,
                       CurvePoint(temp: 100, fraction: 0.8))

        // Shifting moves the ramp but not the ends, and repeated shifts do not pile up points. / 中文：平移移动爬升段但不动首尾，反复平移也不会堆积控制点。
        var shifted = raw
        for _ in 0..<5 { shifted = shifted.shiftedTemps(by: 2) }
        XCTAssertEqual(shifted.points.map(\.temp), [40, 70, 90, 100])
        XCTAssertEqual(shifted.rampStartTemp, 70, accuracy: 0.000001)
        XCTAssertEqual(shifted.shiftedTemps(by: -40).points.first?.temp, 40)
        XCTAssertEqual(shifted.shiftedTemps(by: 40).points.last?.temp, 100)
    }

    func testCurveEditingKeepsTemperaturesDistinctAndPushesNeighbourSpeeds() {
        let curve = FanCurve(points: [CurvePoint(temp: 40, fraction: 0.1),
                                      CurvePoint(temp: 70, fraction: 0.4),
                                      CurvePoint(temp: 90, fraction: 0.8)])
        let moved = curve.movingPoint(at: 1, to: CurvePoint(temp: 100, fraction: 1))
        XCTAssertEqual(moved.points[1], CurvePoint(temp: 89, fraction: 1))
        XCTAssertEqual(moved.points[0], curve.points[0])
        XCTAssertEqual(moved.points[2], CurvePoint(temp: 90, fraction: 1))
        let lower = curve.movingPoint(at: 1, to: CurvePoint(temp: 20, fraction: -1))
        XCTAssertEqual(lower.points[1], CurvePoint(temp: 41, fraction: 0))
        XCTAssertEqual(lower.points[0], CurvePoint(temp: 40, fraction: 0))
        XCTAssertEqual(lower.points[2], curve.points[2])
        XCTAssertEqual(curve.movingPoint(at: 99, to: CurvePoint(temp: 50, fraction: 1)), curve)
    }

    func testInsertingCurvePointPreservesInterpolationAndRejectsCrowdedPoints() {
        let curve = FanCurve(points: [CurvePoint(temp: 40, fraction: 0),
                                      CurvePoint(temp: 93, fraction: 0.8)])
        let inserted = curve.insertingPoint(at: 61.2)
        XCTAssertEqual(inserted.points.count, 4)
        XCTAssertEqual(inserted.points[1].temp, 61)
        for temp in stride(from: 40.0, through: 100.0, by: 0.5) {
            XCTAssertEqual(inserted.fraction(at: temp), curve.fraction(at: temp), accuracy: 0.000001)
        }
        XCTAssertEqual(inserted.insertingPoint(at: 61), inserted)
        let full = FanCurve(points: [40.0, 48, 56, 64, 72, 80, 88, 100].enumerated().map {
            CurvePoint(temp: $0.element, fraction: Double($0.offset) / 10)
        })
        XCTAssertEqual(full.points.count, FanCurve.pointCountRange.upperBound)
        XCTAssertEqual(full.insertingPoint(at: 50), full)
    }

    func testPrecisionCurveEditingPreservesTheUntouchedAxis() {
        let curve = FanCurve(points: [CurvePoint(temp: 40, fraction: 0),
                                      CurvePoint(temp: 80.833333, fraction: 0.333333),
                                      CurvePoint(temp: 100, fraction: 0.7)])
        let rpmEdit = curve.movingPoint(at: 1, to: CurvePoint(temp: curve.points[1].temp, fraction: 0.34))
        XCTAssertEqual(rpmEdit.points[1].temp, curve.points[1].temp)
        let tempEdit = curve.movingPoint(at: 1, to: CurvePoint(temp: 82, fraction: curve.points[1].fraction))
        XCTAssertEqual(tempEdit.points[1].fraction, curve.points[1].fraction)
    }

    func testEditingLegacyFractionalPointsDoesNotReorderNeighbours() {
        let curve = FanCurve(points: [CurvePoint(temp: 60, fraction: 0),
                                      CurvePoint(temp: 60.5, fraction: 0.35),
                                      CurvePoint(temp: 100, fraction: 0.7)])
        let moved = curve.movingPoint(at: 2, to: CurvePoint(temp: 40, fraction: 0.1))
        XCTAssertEqual(moved.points[2].temp, 60.5)
        XCTAssertEqual(moved.points[1], curve.points[1])
        XCTAssertEqual(moved.points[3], curve.points[3])
        XCTAssertEqual(curve.insertingPoint(at: 61), curve)
    }

    func testNormalizedStrategiesRestoresMissingBuiltInsAndDropsDuplicates() {
        let user = FanStrategy.user(
            name: "Office",
            curve: FanCurve(points: [CurvePoint(temp: 50, fraction: 0.2), CurvePoint(temp: 90, fraction: 0.8)])
        )
        let stored = [
            user,
            user,
            FanStrategy(id: FanStrategy.balancedID, name: nil,
                        curve: FanCurve(points: [CurvePoint(temp: 999, fraction: 9)]))
        ]

        let normalized = FanController.normalizedStrategies(stored)
        XCTAssertEqual(normalized.map(\.id), FanStrategy.builtInIDs + [user.id])
        XCTAssertEqual(normalized[0].curve, FanStrategy.shippedCurve(for: FanStrategy.powerSavingID))
        XCTAssertEqual(normalized[1].curve.points.last?.temp, FanCurve.temperatureRange.upperBound)
        XCTAssertEqual(normalized[1].curve.topFraction, 1)
    }

    func testCurveTargetFollowsTheCurveAndProtectionLiftsTheFloor() {
        let curve = FanCurve(points: [CurvePoint(temp: 40, fraction: 0.1), CurvePoint(temp: 100, fraction: 0.35)])
        func target(_ temp: Double, safety: Double) -> ResponseCurve.Target {
            ResponseCurve.target(curveTemp: temp, safetyTemp: safety, curve: curve,
                                 floor: 1000, hardwareMax: 5000, protectionFraction: 0.8)
        }

        // Between the points the speed is interpolated; the ceiling comes from the curve's top. / 中文：点之间按线性插值；上限取自曲线的最高点。
        let mid = target(70, safety: 70)
        XCTAssertEqual(mid.rpm, 1900, accuracy: 0.5)
        XCTAssertEqual(mid.userCeiling, 2400)

        // Protection raises a minimum speed above the onset, even on a curve that stays low. / 中文：超过起始温度后，即使曲线很低，保护也会抬升最低转速。
        XCTAssertEqual(target(40, safety: 90).rpm, 2500, accuracy: 1)
        // At the critical temperature the protection maximum takes over. / 中文：临界温度时，直接取保护上限。
        XCTAssertEqual(target(40, safety: 95).rpm, 4000, accuracy: 0.5)
    }

    func testScheduleResolverFindsTheLatestTriggerAndHonoursDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }

        // 2026-11-04 is a Wednesday; 11-07 Saturday; 11-08 Sunday. / 中文：2026-11-04 为周三，11-07 为周六，11-08 为周日。
        let morning = ScheduleEntry(id: UUID(), hour: 9, minute: 0, days: .everyDay, mode: .automatic, strategyID: FanStrategy.performanceID)
        let weekendNight = ScheduleEntry(id: UUID(), hour: 22, minute: 30, days: .weekends, mode: .system, strategyID: nil)
        let entries = [morning, weekendNight]

        XCTAssertEqual(ScheduleResolver.latestTrigger(in: entries, now: at(4, 12, 0), calendar: calendar)?.entry.id, morning.id)

        // Before today's 09:00 the previous day's 09:00 is the latest. / 中文：今天 09:00 之前，最近的触发点是昨天 09:00。
        let beforeMorning = ScheduleResolver.latestTrigger(in: entries, now: at(4, 8, 0), calendar: calendar)
        XCTAssertEqual(beforeMorning?.entry.id, morning.id)
        XCTAssertEqual(beforeMorning?.date, at(3, 9, 0))

        // Weekend-only entry fires on Saturday night, not on a weekday night. / 中文：仅周末的条目在周六晚触发，工作日晚上不触发。
        XCTAssertEqual(ScheduleResolver.latestTrigger(in: entries, now: at(7, 23, 0), calendar: calendar)?.entry.id, weekendNight.id)
        XCTAssertEqual(ScheduleResolver.latestTrigger(in: entries, now: at(4, 23, 0), calendar: calendar)?.entry.id, morning.id)

        // Monday morning before 09:00: last trigger is Sunday night. / 中文：周一 09:00 前，最近触发点是周日晚。
        XCTAssertEqual(ScheduleResolver.latestTrigger(in: entries, now: at(9, 8, 0), calendar: calendar)?.entry.id, weekendNight.id)

        XCTAssertNil(ScheduleResolver.latestTrigger(in: [], now: at(4, 12, 0), calendar: calendar))
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

    /// The protection limit caps the critical override, but never below the
    /// user's own ceiling.
    func testCriticalOverrideStopsAtProtectionLimit() {
        XCTAssertEqual(
            FanController.clampFanTarget(
                3_600, fanMin: 1_200, fanMax: 6_500,
                autoCeiling: 3_600, isCritical: true, protectionFraction: 0.8
            ),
            5_200
        )
        XCTAssertEqual(
            FanController.clampFanTarget(
                6_000, fanMin: 1_200, fanMax: 6_500,
                autoCeiling: 6_000, isCritical: true, protectionFraction: 0.5
            ),
            6_000
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
}
