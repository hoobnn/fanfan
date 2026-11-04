//
//  File: FanStrategy.swift / 文件：FanStrategy.swift
//  Target: fanfan / 目标：fanfan
//
//  Description: Named auto-mode strategies, each owning an editable fan curve, / 描述：具名的自动模式策略，每个策略持有一条可编辑的风扇曲线，
//  the legacy three-parameter form kept only for reading older settings, and the / 中文：旧版三参数形式仅用于读取旧设置，
//  single function that turns a curve into a target speed. / 中文：以及把曲线换算为目标转速的唯一函数。
//

import Foundation

/// One control point: fan speed as a fraction of the usable RPM span at a temperature. / 中文：一个控制点：某温度下转速占可用转速区间的比例。
struct CurvePoint: Codable, Equatable {
    /// °C, kept within `FanCurve.temperatureRange`. / 中文：摄氏度，限定在 `FanCurve.temperatureRange` 内。
    var temp: Double
    /// 0...1 of [floor, hardware max]. A fraction, not RPM, so a curve fits every machine's limits. / 中文：[下界, 硬件上限] 区间内的占比；存占比而非转速，使曲线适配各机器的转速边界。
    var fraction: Double
}

/// Piecewise-linear fan curve. Points stay sorted by temperature, and the fraction never falls as / 中文：分段线性的风扇曲线。控制点按温度排序，
/// temperature rises, so an edit can never make the fan slow down while the chip heats up. / 中文：转速占比随温度升高而不下降，因此编辑永远不会出现“越热转速越低”。
struct FanCurve: Codable, Equatable {
    static let temperatureRange: ClosedRange<Double> = 40...100
    static let pointCountRange: ClosedRange<Int> = 2...8
    /// Grid the editor snaps to. / 中文：编辑器吸附的网格。
    static let temperatureStep = 1.0
    static let fractionStep = 0.01

    private(set) var points: [CurvePoint]

    init(points: [CurvePoint]) {
        self.points = Self.normalizedPoints(points)
    }

    private enum CodingKeys: String, CodingKey { case points }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = Self.normalizedPoints(try container.decode([CurvePoint].self, forKey: .points))
    }

    /// Clamps, sorts and monotonises the points, and keeps the count within bounds. / 中文：夹取、排序并使转速占比单调不降，同时把点数限制在范围内。
    static func normalizedPoints(_ raw: [CurvePoint]) -> [CurvePoint] {
        var sorted = raw.map {
            CurvePoint(temp: clamp($0.temp, temperatureRange), fraction: clamp($0.fraction, 0...1))
        }
        sorted.sort { $0.temp < $1.temp }

        var running = 0.0
        for index in sorted.indices {
            running = max(running, sorted[index].fraction)
            sorted[index].fraction = running
        }

        // Too many points: drop interior ones so both ends survive. / 中文：点数过多时删除中间点，保留两端。
        while sorted.count > pointCountRange.upperBound {
            sorted.remove(at: sorted.count / 2)
        }
        // Too few points: a flat curve through the one given value. / 中文：点数不足时，用给定的那一个值补成水平线。
        if sorted.isEmpty {
            return [CurvePoint(temp: temperatureRange.lowerBound, fraction: 0),
                    CurvePoint(temp: temperatureRange.upperBound, fraction: 0)]
        }
        if sorted.count == 1 {
            let only = sorted[0].fraction
            return [CurvePoint(temp: temperatureRange.lowerBound, fraction: only),
                    CurvePoint(temp: temperatureRange.upperBound, fraction: only)]
        }
        return sorted
    }

    /// Speed fraction at `temp`, held flat beyond the first and last points. / 中文：某温度下的转速占比；超出首尾点时保持端点的值。
    func fraction(at temp: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temp <= first.temp { return first.fraction }
        if temp >= last.temp { return last.fraction }
        for (a, b) in zip(points, points.dropFirst()) where temp <= b.temp {
            let width = b.temp - a.temp
            guard width > 0 else { return b.fraction }
            return a.fraction + (temp - a.temp) / width * (b.fraction - a.fraction)
        }
        return last.fraction
    }

    /// Editing keeps a full degree between neighbours, including legacy fractional temperatures.
    func temperatureBounds(for index: Int) -> ClosedRange<Double> {
        guard points.indices.contains(index) else { return Self.temperatureRange }
        let lower = index == 0 ? Self.temperatureRange.lowerBound : min(points[index].temp, ceil(points[index - 1].temp + Self.temperatureStep))
        let upper = index == points.count - 1 ? Self.temperatureRange.upperBound : max(points[index].temp, floor(points[index + 1].temp - Self.temperatureStep))
        return lower...upper
    }

    /// Moves one point. Its temperature stays between its neighbours. Its speed can go anywhere: / 中文：移动一个控制点。温度保持在相邻两点之间；转速可以任意调整：
    /// raising it lifts any later point that would sit lower, lowering it drops any earlier point / 中文：调高时把后面更低的点一起抬高，调低时把前面更高的点一起压低，
    /// that would sit higher, so the curve never falls and the point never sticks at a neighbour. / 中文：曲线始终不下降，控制点也不会卡在相邻点的高度上。
    func movingPoint(at index: Int, to point: CurvePoint) -> FanCurve {
        guard points.indices.contains(index) else { return self }
        var snapped = Self.snapped(point)
        // Precision controls change one axis; retain legacy/interpolated values on the other.
        if point.temp == points[index].temp { snapped.temp = point.temp }
        if point.fraction == points[index].fraction { snapped.fraction = point.fraction }
        let fraction = Self.clamp(snapped.fraction, 0...1)
        var copy = points
        copy[index] = CurvePoint(temp: Self.clamp(snapped.temp, temperatureBounds(for: index)), fraction: fraction)
        for later in copy.indices where later > index {
            copy[later].fraction = max(copy[later].fraction, fraction)
        }
        for earlier in copy.indices where earlier < index {
            copy[earlier].fraction = min(copy[earlier].fraction, fraction)
        }
        return FanCurve(points: copy)
    }

    /// Inserting an interpolated point preserves the curve exactly, without rounding its speed.
    func insertingPoint(at temperature: Double) -> FanCurve {
        guard points.count < Self.pointCountRange.upperBound else { return self }
        let temp = Self.snapped(CurvePoint(temp: temperature, fraction: 0)).temp
        guard points.allSatisfy({ abs($0.temp - temp) >= Self.temperatureStep }) else { return self }
        return FanCurve(points: points + [CurvePoint(temp: temp, fraction: fraction(at: temp))])
    }

    /// Highest fraction on the curve. / 中文：曲线上的最高转速占比。
    var topFraction: Double { points.last?.fraction ?? 0 }

    /// Temperature where the curve leaves the floor, i.e. where the fan starts to ramp. / 中文：曲线离开下界的温度，即风扇开始爬升的温度。
    var rampStartTemp: Double {
        points.last(where: { $0.fraction <= 0.0005 })?.temp ?? points.first?.temp ?? FanCurve.temperatureRange.lowerBound
    }

    /// Moves every point along the temperature axis, clamped to the valid range. / 中文：整体平移所有控制点的温度，并夹取到有效范围内。
    func shiftedTemps(by delta: Double) -> FanCurve {
        FanCurve(points: points.map { CurvePoint(temp: $0.temp + delta, fraction: $0.fraction) })
    }

    /// Rescales the fractions so the highest point becomes `top`. A flat-zero curve has nothing to scale, so only its last point is raised. / 中文：按比例缩放转速占比，使最高点变为 `top`；全零曲线无法按比例缩放，只抬高最后一个点。
    func scaledTop(to top: Double) -> FanCurve {
        let target = Self.clamp(top, 0...1)
        let old = topFraction
        guard old > 0 else {
            var copy = points
            if let last = copy.indices.last { copy[last].fraction = target }
            return FanCurve(points: copy)
        }
        let factor = target / old
        return FanCurve(points: points.map { CurvePoint(temp: $0.temp, fraction: $0.fraction * factor) })
    }

    /// The curve the old three-parameter law drew: flat at the floor until `targetTemp`, then a ramp of / 中文：旧三参数定律对应的曲线：到 `targetTemp` 前保持下界，
    /// `aggressiveness / 10` per °C, capped at `maxSpeedFraction`. Converting this way is exact. / 中文：之后以每 °C `aggressiveness / 10` 的斜率爬升，封顶于 `maxSpeedFraction`。这样转换是精确的。
    static func legacy(targetTemp: Double, aggressiveness: Double, maxSpeedFraction: Double) -> FanCurve {
        let target = clamp(targetTemp, 40...90)
        let top = clamp(maxSpeedFraction, 0...1)
        let slope = clamp(aggressiveness, 0...3) / 10
        var points = [CurvePoint(temp: temperatureRange.lowerBound, fraction: 0),
                      CurvePoint(temp: target, fraction: 0)]
        if slope > 0 {
            let knee = target + top / slope
            if knee < temperatureRange.upperBound {
                points.append(CurvePoint(temp: knee, fraction: top))
                points.append(CurvePoint(temp: temperatureRange.upperBound, fraction: top))
            } else {
                points.append(CurvePoint(temp: temperatureRange.upperBound, fraction: min(top, slope * (temperatureRange.upperBound - target))))
            }
        } else {
            points.append(CurvePoint(temp: temperatureRange.upperBound, fraction: 0))
        }
        return FanCurve(points: points)
    }

    /// Hand-edited control points stay on a 1 °C / 0.01 grid. / 中文：手动编辑的控制点落在 1 °C / 0.01 的网格上。
    static func snapped(_ point: CurvePoint) -> CurvePoint {
        CurvePoint(
            temp: clamp((point.temp / temperatureStep).rounded() * temperatureStep, temperatureRange),
            fraction: clamp((point.fraction / fractionStep).rounded() * fractionStep, 0...1)
        )
    }

    fileprivate static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

/// A named bundle holding one fan curve. Built-in strategies keep their fixed ids so stored settings map / 中文：具名策略，持有一条风扇曲线。内置策略沿用固定 id，
/// onto them directly; user strategies get a UUID. / 中文：以便已存储设置直接对应；用户策略使用 UUID。
struct FanStrategy: Codable, Identifiable, Equatable {
    static let powerSavingID = "powerSaving"
    static let balancedID = "balanced"
    static let performanceID = "performance"
    static let builtInIDs = [powerSavingID, balancedID, performanceID]

    /// Fallback when the active strategy id no longer exists. / 中文：活动策略 id 失效时的回退对象。
    static let fallbackID = balancedID

    let id: String
    /// Custom display name. nil for a built-in means "use the localized title". / 中文：自定义显示名。内置策略为 nil 时使用本地化标题。
    var name: String?
    var curve: FanCurve

    init(id: String, name: String?, curve: FanCurve) {
        self.id = id
        self.name = name
        self.curve = curve
    }

    private enum CodingKeys: String, CodingKey { case id, name, curve }
    /// Layout-3 settings stored `preset` instead of `curve`; read it so those settings convert. / 中文：布局 3 的设置存的是 `preset` 而非 `curve`；读取它以完成转换。
    private enum LegacyKeys: String, CodingKey { case preset }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let stored = try container.decodeIfPresent(FanCurve.self, forKey: .curve) {
            curve = stored
        } else if let legacy = try decoder.container(keyedBy: LegacyKeys.self)
                    .decodeIfPresent(StrategyPreset.self, forKey: .preset) {
            curve = legacy.curve
        } else {
            curve = Self.shippedCurve(for: id) ?? StrategyPreset.balancedFallback.curve
        }
    }

    var isBuiltIn: Bool { Self.builtInIDs.contains(id) }
    var isPowerSaving: Bool { id == Self.powerSavingID }

    /// Shipped curve for a built-in strategy; nil for user strategies. / 中文：内置策略的出厂曲线；用户策略为 nil。
    var shippedCurve: FanCurve? { Self.shippedCurve(for: id) }

    /// True when a built-in has been reshaped away from its shipped curve. / 中文：内置策略的曲线已被改离出厂曲线时为 true。
    var isModified: Bool { shippedCurve.map { $0 != curve } ?? false }

    /// Name shown in menus and lists. / 中文：菜单与列表中显示的名称。
    var displayName: String {
        if let name, !name.isEmpty { return name }
        switch id {
        case Self.powerSavingID: return NSLocalizedString("popover.strategy.power_saving", comment: "")
        case Self.balancedID:    return NSLocalizedString("popover.strategy.balanced", comment: "")
        case Self.performanceID: return NSLocalizedString("popover.strategy.performance", comment: "")
        default:                 return id
        }
    }

    static func shippedCurve(for id: String) -> FanCurve? {
        switch id {
        case powerSavingID: return StrategyPreset(targetTemp: 80, aggressiveness: 0.6, maxSpeedFraction: 0.2).curve
        case balancedID:    return StrategyPreset(targetTemp: 75, aggressiveness: 0.6, maxSpeedFraction: 0.35).curve
        case performanceID: return StrategyPreset(targetTemp: 60, aggressiveness: 1.5, maxSpeedFraction: 0.65).curve
        default:            return nil
        }
    }

    /// The built-in strategies with their shipped curves, in display order. / 中文：出厂曲线的内置策略，按显示顺序排列。
    static var builtIns: [FanStrategy] {
        builtInIDs.map { FanStrategy(id: $0, name: nil, curve: shippedCurve(for: $0)!) }
    }

    /// A new user strategy with a fresh id. / 中文：生成一个带新 id 的用户策略。
    static func user(name: String, curve: FanCurve) -> FanStrategy {
        FanStrategy(id: UUID().uuidString, name: name, curve: curve)
    }
}

/// The three parameters that defined a strategy before it held a curve. Used only to read older settings. / 中文：策略改为持有曲线之前，定义策略的三个参数。仅用于读取旧设置。
struct StrategyPreset: Codable, Equatable {
    /// Temperature where the ramp starts (°C). / 中文：开始爬升的温度（°C）。
    var targetTemp: Double
    /// Ramp steepness notch; 1.0 means 10 % of the span per °C. / 中文：爬升陡度档位；1.0 表示每 °C 爬升区间的 10%。
    var aggressiveness: Double
    /// Ceiling as a fraction of the usable span. / 中文：占可用区间的上限比例。
    var maxSpeedFraction: Double

    static let targetTempRange: ClosedRange<Double> = 40...90
    static let aggressivenessRange: ClosedRange<Double> = 0...3
    static let maxSpeedFractionRange: ClosedRange<Double> = 0...1

    static let balancedFallback = StrategyPreset(targetTemp: 75, aggressiveness: 0.6, maxSpeedFraction: 0.35)

    var curve: FanCurve {
        FanCurve.legacy(targetTemp: targetTemp, aggressiveness: aggressiveness, maxSpeedFraction: maxSpeedFraction)
    }
}

/// The three-tier enum from before strategies became a list. Used only to read / 中文：策略改为列表之前的三档枚举（含 custom），
/// settings written by older versions. / 中文：仅用于读取旧版本写入的设置。
enum LegacyPowerStrategy: String {
    case powerSaving
    case balanced
    case performance
    case custom
}

/// The one place a curve becomes a target speed. The controller and the settings chart both call it, / 中文：把曲线换算为目标转速的唯一位置。控制器与设置里的图表都调用它，
/// so the drawn curve is the curve that runs. / 中文：因此画出来的曲线就是实际运行的曲线。
enum ResponseCurve {
    static let temperatureRange = FanCurve.temperatureRange

    struct Target {
        /// Speed to aim for, before the load-aware boost and the final clamp. / 中文：目标转速（尚未加入负载加速与最终夹取）。
        let rpm: Double
        /// Ceiling after thermal protection has been applied. / 中文：应用高温保护后的上限。
        let ceiling: Int
        /// Ceiling the curve itself asks for, before protection lifts it. / 中文：曲线自身要求的上限，未经保护抬升。
        let userCeiling: Int
    }

    /// `curveTemp` picks the point on the curve (the smoothed reading), and `safetyTemp` drives thermal / 中文：`curveTemp` 决定在曲线上的位置（平滑后的读数），
    /// protection (the raw reading). Above the onset temperature protection both lifts the ceiling and / 中文：`safetyTemp` 驱动高温保护（原始读数）。超过起始温度后，
    /// sets a minimum speed, so a low curve cannot hold the fan down while the chip overheats. / 中文：保护既抬升上限，也设定最低转速，因此再低的曲线也不会在芯片过热时压住风扇。
    nonisolated static func target(
        curveTemp: Double,
        safetyTemp: Double,
        curve: FanCurve,
        floor: Int,
        hardwareMax: Int,
        protectionFraction: Double
    ) -> Target {
        let hardwareMax = max(floor, hardwareMax)
        let span = Double(hardwareMax - floor)
        let protectedMax = FanController.protectionMax(hardwareMax, fraction: protectionFraction)
        let userCeiling = floor + Int((curve.topFraction * span).rounded())
        let ceiling = FanController.softCeiling(
            userCeiling: userCeiling,
            hardwareMax: protectedMax,
            safetyTemperature: safetyTemp
        )
        // Same smoothstep as the ceiling, but starting from the floor: a minimum speed that rises with heat. / 中文：与上限相同的 smoothstep，但从下界起算：随温度升高的最低转速。
        let lift = Double(FanController.softCeiling(
            userCeiling: floor,
            hardwareMax: protectedMax,
            safetyTemperature: safetyTemp
        ))
        let base = Double(floor) + curve.fraction(at: curveTemp) * span
        let rpm = min(Double(ceiling), max(base, lift))
        return Target(rpm: max(Double(floor), rpm), ceiling: ceiling, userCeiling: userCeiling)
    }
}
