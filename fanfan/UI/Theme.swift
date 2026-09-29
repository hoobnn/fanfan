//
//  File: Theme.swift / 文件：Theme.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Refined design system and shared visual tokens. / 描述：精细化设计系统与共享视觉令牌。
//

import SwiftUI

// MARK: - Temperature Level / 中文：温度等级

enum TemperatureLevel {
    case cool, normal, warm, hot, critical

    static func of(_ temp: Double?) -> TemperatureLevel? {
        guard let t = temp, t > 0 else { return nil }
        if t < 50  { return .cool }
        if t < 68  { return .normal }
        if t < 80  { return .warm }
        if t < 90  { return .hot }
        return .critical
    }

    var label: String {
        switch self {
        case .cool:     return NSLocalizedString("temperature.cool",     comment: "")
        case .normal:   return NSLocalizedString("temperature.normal",   comment: "")
        case .warm:     return NSLocalizedString("temperature.warm",     comment: "")
        case .hot:      return NSLocalizedString("temperature.hot",      comment: "")
        case .critical: return NSLocalizedString("temperature.critical", comment: "")
        }
    }
}

// MARK: - Theme / 中文：主题

struct Theme {

    // ── Temperature accent (low chroma, harmonized lightness) ──────── / 中文：── 温度 强调色 (low chroma, harmonized lightness) ────────

    /// Raw RGB components for a temperature level — the single source of truth / 中文：温度等级的原始 RGB 分量 — 颜色定义的唯一来源,
    /// for both the discrete `accent(for:)` and the continuous `thermalColor`. / 中文：供离散的 `accent(for:)` 与连续的 `thermalColor` 共用.
    private static func thermalRGB(for level: TemperatureLevel, scheme: ColorScheme) -> (Double, Double, Double) {
        let dark = scheme == .dark
        switch level {
        case .cool:     return dark ? (0.46, 0.68, 0.90) : (0.20, 0.50, 0.74)
        case .normal:   return dark ? (0.42, 0.78, 0.62) : (0.18, 0.58, 0.46)
        case .warm:     return dark ? (0.92, 0.74, 0.36) : (0.74, 0.54, 0.18)
        case .hot:      return dark ? (0.94, 0.58, 0.30) : (0.78, 0.42, 0.16)
        case .critical: return dark ? (0.92, 0.42, 0.36) : (0.74, 0.22, 0.18)
        }
    }

    static func accent(for level: TemperatureLevel?, scheme: ColorScheme) -> Color {
        guard let level = level else { return .secondary }
        let rgb = thermalRGB(for: level, scheme: scheme)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    static func accent(for temp: Double?, scheme: ColorScheme) -> Color {
        accent(for: TemperatureLevel.of(temp), scheme: scheme)
    }

    /// Continuous thermal color — RGB-interpolates between the five level / 中文：连续温度色 — 在五个等级锚点 (cool→critical) 之间
    /// anchors (cool→critical) so a temperature slider's tint glides smoothly / 中文：进行 RGB 插值，让温度滑杆的着色随值平滑滑动,
    /// from blue to red as the value moves, without discrete level jumps. / 中文：从蓝平滑过渡到红，不再有等级跳变.
    static func thermalColor(forTemperature temp: Double, scheme: ColorScheme) -> Color {
        // Anchor each level at the midpoint of its threshold band so the / 中文：把每个等级锚定在其阈值带的中点，让
        // five colors are evenly distributed across the realistic range. / 中文：五种颜色在真实温度区间内均匀分布.
        let stops: [(Double, (Double, Double, Double))] = [
            (40, thermalRGB(for: .cool,     scheme: scheme)),
            (59, thermalRGB(for: .normal,   scheme: scheme)),
            (74, thermalRGB(for: .warm,     scheme: scheme)),
            (85, thermalRGB(for: .hot,      scheme: scheme)),
            (95, thermalRGB(for: .critical, scheme: scheme)),
        ]
        if temp <= stops.first!.0 {
            let c = stops.first!.1
            return Color(red: c.0, green: c.1, blue: c.2)
        }
        if temp >= stops.last!.0 {
            let c = stops.last!.1
            return Color(red: c.0, green: c.1, blue: c.2)
        }
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if temp >= a.0 && temp <= b.0 {
                let t = (temp - a.0) / (b.0 - a.0)
                let r  = a.1.0 * (1 - t) + b.1.0 * t
                let g  = a.1.1 * (1 - t) + b.1.1 * t
                let bl = a.1.2 * (1 - t) + b.1.2 * t
                return Color(red: r, green: g, blue: bl)
            }
        }
        let c = stops.last!.1
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    // ── Text (monochrome) ───────────────────────────────────────────── / 中文：── 文字（单色）─────────────────────────────────────────────

    // Hierarchical styles instead of fixed black/white opacities: they pick up / 中文：用层级样式替代写死的黑/白透明度：在 Liquid Glass
    // vibrancy on the Liquid Glass popover and follow Increase Contrast. / 中文：popover 上获得 vibrancy，并跟随「增强对比度」。
    static let text1 = HierarchicalShapeStyle.primary
    static let text2 = HierarchicalShapeStyle.secondary
    static let text3 = HierarchicalShapeStyle.tertiary
    // `.quaternary` is fill-level and fades out on glass, so the faintest text / 中文：`.quaternary` 是填充级，在玻璃上几乎消失，
    // tier reuses `.tertiary`. / 中文：因此最淡的文字档复用 `.tertiary`。
    static let text4 = HierarchicalShapeStyle.tertiary

    // ── Fills & separators (monochrome) ─────────────────────────────── / 中文：── Fills & separators (单色) ───────────────────────────────

    static func fill2(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    // ── Status colors (used sparingly) ──────────────────────────────── / 中文：── 状态 颜色s (used sparingly) ────────────────────────────────

    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.40, green: 0.78, blue: 0.46)
                        : Color(red: 0.20, green: 0.62, blue: 0.30)
    }
    static func danger(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.92, green: 0.42, blue: 0.36)
                        : Color(red: 0.74, green: 0.22, blue: 0.18)
    }

    // ── Card surface ────────────────────────────────────────────────── / 中文：── 卡片表面 ──────────────────────────────────────────────────

    /// Cards are the content layer sitting on the popover's Liquid Glass, so / 中文：卡片是叠在 popover Liquid Glass 上的内容层，
    /// they stay a translucent tile — never glass themselves (no glass on / 中文：因此只做半透明色块，自身不上玻璃（避免玻璃叠玻璃），
    /// glass) and no drop shadow, like Control Center modules. / 中文：也不加投影，与控制中心模块一致。
    static func cardBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55)
    }

    /// Hairline edge for cards — a faint lit top that keeps tiles separable / 中文：卡片发丝边——顶部微亮，让色块在
    /// on bright wallpapers without reading as a raised panel. / 中文：明亮壁纸上仍可分辨，但不显得凸起。
    static func cardStroke(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color.white.opacity(0.12),
                                      Color.white.opacity(0.03)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color.white.opacity(0.8),
                                      Color.black.opacity(0.04)],
                             startPoint: .top, endPoint: .bottom)
    }

    /// Subtle vertical gradient for large display numbers — gives the hero / 中文：Subtle vertical 渐变 for large display numbers — gives the hero
    /// figures a touch of depth without breaking the monochrome rule. / 中文：figures a touch of depth without breaking the 单色 rule.
    static func heroText(_ scheme: ColorScheme) -> LinearGradient {
        let top = scheme == .dark ? Color.white.opacity(0.98) : Color.black.opacity(0.92)
        let bot = scheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.64)
        return LinearGradient(colors: [top, bot], startPoint: .top, endPoint: .bottom)
    }

    // ── Typography ──────────────────────────────────────────────────── / 中文：── 字体排版 ────────────────────────────────────────────────────

    /// SF Pro Rounded for numbers — tabular figures. / 中文：数字使用 SF Pro Rounded，并启用等宽数字。
    static func num(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Small uppercase label. / 中文：小号大写标签。
    static func label(_ size: CGFloat = 10.5, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Light display number — used for the big hero temperature. / 中文：Light display number — used for the big hero 温度.
    static func display(_ size: CGFloat, weight: Font.Weight = .thin) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }

    // ── Slider tints ────────────────────────────────────────────────── / 中文：── 滑杆着色 ──────────────────────────────────────────────────

    /// Soft tint for non-thermal sliders (rpm, intervals, gains) — avoids the / 中文：非温度类滑杆 (转速、间隔、增益) 的温和色 — 避免
    /// pure-black look without competing with the thermal range. / 中文：纯黑外观，同时不与温度色范围争夺注意力.
    static func sliderTint(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.62, green: 0.66, blue: 0.72)
            : Color(red: 0.42, green: 0.46, blue: 0.52)
    }
}

// MARK: - Card surface modifier / 中文：卡片表面修饰器

extension Theme {
    /// Card surface: translucent monochrome fill plus a hairline lit edge. / 中文：卡片表面：半透明单色填充加发丝亮边。
    /// Centralizes the look so every card stays consistent. / 中文：集中定义外观，保证所有卡片一致。
    struct CardSurface: ViewModifier {
        let scheme: ColorScheme
        let cornerRadius: CGFloat

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            return content
                .background(Theme.cardBg(scheme), in: shape)
                .overlay {
                    shape.strokeBorder(Theme.cardStroke(scheme), lineWidth: 0.75)
                }
                .clipShape(shape)
        }
    }
}

extension View {
    /// Apply the standard refined card surface. / 中文：Apply the standard refined 卡片 surface.
    func themedCard(_ scheme: ColorScheme, cornerRadius: CGFloat = 12) -> some View {
        modifier(Theme.CardSurface(scheme: scheme, cornerRadius: cornerRadius))
    }
}

// MARK: - Picker styles / 中文：选择器样式

extension View {
    /// Page-switching picker: the macOS 27 `.tabs` style where available, / 中文：页面切换选择器：可用时用 macOS 27 的 `.tabs` 样式，
    /// the segmented control on macOS 26. The compiler check keeps Xcode 26 / 中文：macOS 26 上回退为分段控件。编译器判断让 Xcode 26
    /// toolchains (without the macOS 27 SDK symbol) building. / 中文：工具链（SDK 里没有该符号）也能编译。
    @ViewBuilder
    func tabsPickerStyle() -> some View {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            pickerStyle(.tabs)
        } else {
            pickerStyle(.segmented)
        }
        #else
        pickerStyle(.segmented)
        #endif
    }
}
