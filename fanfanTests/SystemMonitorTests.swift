//
//  File: SystemMonitorTests.swift / 文件：SystemMonitorTests.swift
//  Target: fanfanTests / 目标：fanfanTests
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Unit tests for system monitor behavior. / 描述：系统监控行为的单元测试。
//

import XCTest
@testable import fanfan

final class SystemMonitorTests: XCTestCase {
    
    func testSystemMonitorInitialization() {
        let monitor = SystemMonitor()
        
        XCTAssertNotNil(monitor)
        XCTAssertFalse(monitor.isMonitoring)
    }
    
    func testSystemMonitorAccessCheck() {
        let monitor = SystemMonitor()
        
        // This will depend on actual system access / 中文：这取决于实际系统访问权限
        // In a real test environment, you might mock this / 中文：在真实测试环境中可以对这里做 mock
        let hasAccess = monitor.checkAccess()
        
        // Just verify the method doesn't crash / 中文：这里只验证方法不会崩溃
        XCTAssertNotNil(hasAccess)
    }
    
    func testSystemMonitorStartStop() {
        let monitor = SystemMonitor()
        
        XCTAssertFalse(monitor.isMonitoring)
        
        monitor.startMonitoring()
        // Note: In actual implementation, monitoring might start asynchronously / 中文：注意：实际实现中监控可能会异步启动
        // This test verifies the method can be called without crashing / 中文：该测试验证方法调用不会崩溃
        
        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
    }
    
    func testTemperatureReadingStructure() {
        let reading = TemperatureReading(cpu: 65.5, gpu: 72.3)
        
        XCTAssertEqual(reading.cpu, 65.5)
        XCTAssertEqual(reading.gpu, 72.3)
    }
    
    func testFanReadingStructure() {
        let reading = FanReading(id: 0, speed: 2500, minSpeed: 1000, maxSpeed: 6000)

        XCTAssertEqual(reading.id, 0)
        XCTAssertEqual(reading.speed, 2500)
        XCTAssertEqual(reading.minSpeed, 1000)
        XCTAssertEqual(reading.maxSpeed, 6000)
    }

    func testSensorSectionsPreserveCategoryOrderAndMaxTemperature() {
        let sensors = [
            SensorReading(id: "TN0D", name: "SSD", temperature: 41.0, category: .storage),
            SensorReading(id: "TC0P", name: "CPU Proximity", temperature: 58.0, category: .cpu),
            SensorReading(id: "TC1C", name: "CPU Core 1", temperature: 63.0, category: .cpu),
            SensorReading(id: "TG0P", name: "GPU Proximity", temperature: 54.0, category: .gpu)
        ]

        let sections = SensorSection.sections(from: sensors)

        XCTAssertEqual(sections.map(\.category), [.cpu, .gpu, .storage])
        XCTAssertEqual(sections.first?.sensors.map(\.id), ["TC0P", "TC1C"])
        XCTAssertEqual(sections.first?.maxTemperature, 63.0)
    }

    func testEveryKnownTemperatureSourceMustRemainFresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = now.addingTimeInterval(-2)
        let stale = now.addingTimeInterval(-12)

        XCTAssertFalse(SystemMonitor.temperatureSourcesAreFresh(
            cpuLastValidAt: nil, gpuLastValidAt: nil, now: now, timeout: 10
        ))
        XCTAssertTrue(SystemMonitor.temperatureSourcesAreFresh(
            cpuLastValidAt: fresh, gpuLastValidAt: nil, now: now, timeout: 10
        ))
        XCTAssertTrue(SystemMonitor.temperatureSourcesAreFresh(
            cpuLastValidAt: fresh, gpuLastValidAt: fresh, now: now, timeout: 10
        ))
        XCTAssertFalse(SystemMonitor.temperatureSourcesAreFresh(
            cpuLastValidAt: fresh, gpuLastValidAt: stale, now: now, timeout: 10
        ))
        XCTAssertFalse(SystemMonitor.temperatureSourcesAreFresh(
            cpuLastValidAt: stale, gpuLastValidAt: fresh, now: now, timeout: 10
        ))
    }

    // MARK: - Non-finite SMC payloads / 中文：非有限 SMC 读数

    /// Firmware can return a NaN / infinity `flt ` bit pattern after a wake race
    /// or a dropped SMC link. `Int(Double)` traps on those, which crashed the
    /// app outright rather than degrading, so the conversion must reject them.
    func testFanRPMRejectsNonFiniteReadings() {
        XCTAssertNil(SystemMonitor.fanRPM(fromRawValue: Double.nan))
        XCTAssertNil(SystemMonitor.fanRPM(fromRawValue: Double.infinity))
        XCTAssertNil(SystemMonitor.fanRPM(fromRawValue: -Double.infinity))
        XCTAssertNil(SystemMonitor.fanRPM(fromRawValue: Double.greatestFiniteMagnitude))
    }

    func testFanRPMKeepsOrdinaryReadings() {
        XCTAssertEqual(SystemMonitor.fanRPM(fromRawValue: 0), 0)
        XCTAssertEqual(SystemMonitor.fanRPM(fromRawValue: 2866), 2866)
        XCTAssertEqual(SystemMonitor.fanRPM(fromRawValue: 2999.6), 3000)
    }

    // MARK: - Concurrent SMC state access / 中文：SMC 状态并发访问

    /// `checkAccess` runs on the main thread while every reader runs on
    /// `readingsQueue`; both reach `smcConnection` and `keyInfoCache`. Hammer
    /// the two paths together so Thread Sanitizer sees the interleaving — an
    /// unguarded handle would show up as a race here, and the check-then-open
    /// could leak a second mach port.
    func testConcurrentAccessDoesNotRaceOnSMCState() {
        let monitor = SystemMonitor()
        let iterations = 200
        let done = expectation(description: "concurrent access settled")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<iterations { _ = monitor.checkAccess() }
            done.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<iterations { _ = monitor.readSMCValue(key: "TC0P") }
            done.fulfill()
        }

        wait(for: [done], timeout: 60)
        // Reaching here without a sanitizer abort is the assertion; confirm the
        // monitor is still usable rather than left with a torn handle.
        XCTAssertEqual(monitor.checkAccess(), monitor.checkAccess())
    }

    /// Start/stop cycles reopen the connection while readers are mid-flight.
    func testMonitoringRestartWhileReadingIsSafe() {
        let monitor = SystemMonitor()
        let done = expectation(description: "restart settled")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<50 { _ = monitor.readSMCValue(key: "TC0P") }
            done.fulfill()
        }
        DispatchQueue.main.async {
            for _ in 0..<20 {
                monitor.startMonitoring()
                monitor.stopMonitoring()
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 60)
        XCTAssertFalse(monitor.isMonitoring)
    }

    // MARK: - Die-sensor placeholder filtering / 中文：裸片传感器占位值过滤

    /// Apple Silicon parks inactive die sensors at exactly 40.00 °C rather than
    /// omitting them. Measured on an M4 Pro: at idle all six curated
    /// `appleChipTempKeys` sit at that constant while 53 other `Tp**`/`TC**`
    /// sensors report real values up to ~77 °C. Letting the constant through
    /// pins the control input at 40 °C; a too-loose epsilon would instead throw
    /// away genuine readings that happen to land near 40 °C.
    func testPlaceholderReadingFiltersOnlyTheExactConstant() {
        // The inactive-sensor constant is rejected.
        XCTAssertTrue(SystemMonitor.isPlaceholderReading(40.0))

        // Real readings near 40 °C still count — they carry fractional jitter.
        XCTAssertFalse(SystemMonitor.isPlaceholderReading(40.01))
        XCTAssertFalse(SystemMonitor.isPlaceholderReading(39.98))
        XCTAssertFalse(SystemMonitor.isPlaceholderReading(41.0))

        // Values elsewhere in the plausible band are untouched.
        XCTAssertFalse(SystemMonitor.isPlaceholderReading(3.40))
        XCTAssertFalse(SystemMonitor.isPlaceholderReading(76.94))
    }
}
