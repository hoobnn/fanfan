//
//  File: ThermalRecorder.swift / 文件：ThermalRecorder.swift
//  Target: fanfan / 目标：fanfan
//
//  Description: Records temperature and fan speed at a fixed interval and exports them as CSV, so / 描述：按固定间隔记录温度与风扇转速并导出为 CSV，
//  the user can study how the fans responded and tune the curve. / 供用户分析风扇响应、调整曲线。
//

import Combine
import Foundation

/// One row of the recording. Optional readings stay empty in the CSV rather than reading as 0. / 中文：记录中的一行；缺失的读数在 CSV 中留空，而不是写成 0。
struct ThermalSample {
    var time: Date
    var maxTemperature: Double?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var fanSpeeds: [Int]
    /// Target fanfan last wrote; nil while the firmware runs the fans. / 中文：fanfan 最近下发的目标转速；固件控制风扇时为 nil。
    var targetRPM: Int?
    var mode: ControlMode
    var strategy: String
    var powerWatts: Double?
}

@MainActor
final class ThermalRecorder: ObservableObject {
    static let sampleInterval: TimeInterval = 2
    /// Four days at the sample interval; recording stops on its own past this. / 中文：按采样间隔约四天；超过后自动停止记录。
    static let maxSamples = 172_800

    @Published private(set) var isRecording = false
    @Published private(set) var samples: [ThermalSample] = []

    private var timer: Timer?
    private var capture: (() -> ThermalSample)?

    /// Starts a fresh recording; the previous one is discarded. / 中文：开始新的记录，丢弃之前的记录。
    func start(capture: @escaping () -> ThermalSample) {
        stop()
        samples = []
        self.capture = capture
        isRecording = true
        record()
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        capture = nil
        isRecording = false
    }

    var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time.timeIntervalSince(first.time)
    }

    private func record() {
        guard let capture else { return }
        samples.append(capture())
        if samples.count >= Self.maxSamples { stop() }
    }

    // MARK: - CSV / 中文：CSV

    /// UTF-8 with a BOM so Excel reads non-ASCII strategy names correctly. / 中文：带 BOM 的 UTF-8，让 Excel 正确读取非 ASCII 的策略名。
    nonisolated static func csvData(for samples: [ThermalSample], timeZone: TimeZone = .current) -> Data {
        let fanCount = samples.map(\.fanSpeeds.count).max() ?? 0
        var header = ["time", "temp_max_c", "temp_cpu_c", "temp_gpu_c"]
        header += (0..<fanCount).map { "fan\($0 + 1)_rpm" }
        header += ["target_rpm", "mode", "strategy", "power_w"]

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        var lines = [header.joined(separator: ",")]
        for s in samples {
            var row = [
                formatter.string(from: s.time),
                decimal(s.maxTemperature),
                decimal(s.cpuTemperature),
                decimal(s.gpuTemperature),
            ]
            row += (0..<fanCount).map { $0 < s.fanSpeeds.count ? String(s.fanSpeeds[$0]) : "" }
            row += [
                s.targetRPM.map(String.init) ?? "",
                s.mode.rawValue,
                quoted(s.strategy),
                decimal(s.powerWatts),
            ]
            lines.append(row.joined(separator: ","))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private nonisolated static func decimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private nonisolated static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
