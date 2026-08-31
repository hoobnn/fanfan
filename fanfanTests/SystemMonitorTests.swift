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
}
