//
//  File: ThermalRecorderTests.swift / 文件：ThermalRecorderTests.swift
//  Target: fanfanTests / 目标：fanfanTests
//

import XCTest
@testable import fanfan

final class ThermalRecorderTests: XCTestCase {
    func testCSVLeavesMissingReadingsEmptyAndQuotesStrategy() throws {
        let samples = [
            ThermalSample(time: Date(timeIntervalSince1970: 0), maxTemperature: 57.04, cpuTemperature: 44,
                          gpuTemperature: nil, fanSpeeds: [1350, 0], targetRPM: 0, mode: .automatic,
                          strategy: "Quiet, \"night\"", powerWatts: nil),
            // Firmware in control and one fan missing: no target, short fan list. / 中文：固件控制且缺一个风扇：无目标转速，风扇列表变短。
            ThermalSample(time: Date(timeIntervalSince1970: 2), maxTemperature: nil, cpuTemperature: nil,
                          gpuTemperature: nil, fanSpeeds: [1200], targetRPM: nil, mode: .system,
                          strategy: "", powerWatts: 12.345),
        ]
        let data = ThermalRecorder.csvData(for: samples, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "time,temp_max_c,temp_cpu_c,temp_gpu_c,fan1_rpm,fan2_rpm,target_rpm,mode,strategy,power_w",
            #"1970-01-01T00:00:00Z,57.0,44.0,,1350,0,0,automatic,"Quiet, ""night""","#,
            "1970-01-01T00:00:02Z,,,,1200,,,system,,12.3",
            "",
        ])
    }
}
