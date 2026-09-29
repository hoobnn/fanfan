//
//  File: TemperatureDisplayFilter.swift / 文件：TemperatureDisplayFilter.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/9/24. / 创建者：haobin，日期：2026/9/24。
//  Description: Turns raw per-key SMC readings into the numbers the UI shows. / 描述：把逐键原始 SMC 读数转换为界面显示值。
//

import Foundation

/// Display-side filtering, kept apart from the control EMA so the UI tracks / 中文：显示侧滤波，与控制用 EMA 分离，使界面
/// the real temperature within about a tick instead of lagging tens of / 中文：约一个周期内跟上真实温度，而不是在负载结束后
/// seconds behind it once load stops. / 中文：滞后数十秒。
///
/// Per key, every tick: / 中文：每个键、每个周期：
/// 1. median of the last `medianWindow` raw samples — drops single-read spikes / 中文：1. 最近 `medianWindow` 个原始样本取中位数——去掉单次尖峰
///    without the lag of an exponential filter; / 中文：且没有指数滤波的滞后；
/// 2. integer rounding with `roundingHysteresis`, so a value hovering at a / 中文：2. 带 `roundingHysteresis` 回差的取整，
///    rounding boundary does not flicker between two numbers. / 中文：避免在取整边界附近来回跳。
///
/// Because a group's headline is the max of its rows, the overview number and / 中文：组的标题值就是各行最大值，
/// the sensor page header come out identical by construction. / 中文：因此概览与传感器页标题在定义上相等。
struct TemperatureDisplayFilter {
    static let roundingHysteresis = 0.3

    let medianWindow: Int
    private var samples: [String: [Double]] = [:]
    private var shown: [String: Double] = [:]

    init(medianWindow: Int) {
        self.medianWindow = max(1, medianWindow)
    }

    /// Feed one group's raw readings for this tick; returns display values for / 中文：输入本周期一组原始读数，返回本周期读到的
    /// the keys read this tick. Unchanged readings alone do not prove failure. / 中文：各键显示值；数值不变本身不能证明传感器失效。
    mutating func update(_ raw: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, value) in raw {
            var window = samples[key, default: []]
            window.append(value)
            if window.count > medianWindow {
                window.removeFirst(window.count - medianWindow)
            }
            samples[key] = window
            let stable = Self.stabilized(Self.median(window), previous: shown[key])
            shown[key] = stable
            result[key] = stable
        }
        return result
    }

    /// Forget all history, e.g. after the source went stale. / 中文：清空历史，例如数据源失效之后。
    mutating func reset() {
        samples = [:]
        shown = [:]
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Integer with hysteresis: keep the previously shown integer until the / 中文：带回差的整数：新值离上次显示的整数
    /// value moves more than 0.5 + `roundingHysteresis` away from it. / 中文：超过 0.5 + `roundingHysteresis` 才切换。
    static func stabilized(_ value: Double, previous: Double?) -> Double {
        if let previous, abs(value - previous) < 0.5 + roundingHysteresis {
            return previous
        }
        return value.rounded()
    }
}

/// Keep the last complete display snapshot through brief read failures, then / 中文：短暂读取失败时沿用完整的显示快照，
/// clear both headline and rows when the source becomes stale. / 中文：数据源过期时同时清空概览值与列表行。
struct TemperatureDisplaySource {
    private var filter: TemperatureDisplayFilter
    private var lastReadings: [String: Double] = [:]

    init(medianWindow: Int) {
        filter = TemperatureDisplayFilter(medianWindow: medianWindow)
    }

    mutating func update(_ raw: [String: Double], isFresh: Bool) -> [String: Double] {
        guard isFresh else {
            filter.reset()
            lastReadings = [:]
            return [:]
        }
        let readings = filter.update(raw)
        if !readings.isEmpty { lastReadings = readings }
        return lastReadings
    }
}
