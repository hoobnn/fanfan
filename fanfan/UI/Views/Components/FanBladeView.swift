//
//  File: FanBladeView.swift / 文件：FanBladeView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Rotating fan blade visualization. / 描述：旋转风扇叶片可视化。
//

import SwiftUI

struct FanBladeView: View {
    /// Current fan RPM. / 中文：Current 风扇 RPM.
    var rpm: Int
    /// Maximum supported RPM (used to map to visual rotation speed). / 中文：Maximum supported RPM (used to map to visual rotation speed).
    var maxRpm: Int = 6500
    /// Number of blades. / 中文：叶片数量。
    var bladeCount: Int = 5
    /// Hub accent — typically `Theme.accent(for: maxTemp, scheme:)`. / 中文：Hub 强调色 — typically `Theme.强调色(for: maxTemp, scheme:)`.
    var accent: Color

    @Environment(\.colorScheme) private var scheme

    /// Rotation is integrated incrementally from these anchors so a change in / 中文：旋转从这些锚点增量积分，因此变化发生在
    /// `visualRps` only alters the *rate* — never the current angle. Driving / 中文：`visualRps` 只改变速度，不改变当前角度；如果直接使用
    /// the angle straight off `t * visualRps` makes it jump, because `t` is a / 中文：`t * visualRps` 推导角度会导致跳变，因为 `t` 是一个
    /// huge number and any rate change scales the whole product. / 中文：很大的数，任何速率变化都会缩放整个乘积。
    @State private var anchorTime = Date().timeIntervalSinceReferenceDate
    @State private var anchorAngle = 0.0

    /// Visual rotations-per-second, capped so very high RPM doesn't strobe. / 中文：Visual rotations-per-second, capped so very high RPM doesn't strobe.
    private var visualRps: Double {
        let target = Double(rpm) / Double(max(1, maxRpm)) * 2.2
        return min(3.5, max(0, target))
    }

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let hub = r * 0.28

            ZStack {
                // Accent bloom — static, lives outside `TimelineView` so it / 中文：强调色光晕——静态元素，放在 `TimelineView` 外，
                // doesn't re-evaluate (and re-blur) on every animation tick. / 中文：每帧动画 tick 不再重新求值（也不再重做高斯模糊）。
                Circle()
                    .fill(accent.opacity(0.55))
                    .frame(width: hub * 2.6, height: hub * 2.6)
                    .blur(radius: 6)

                if visualRps > 0 {
                    // Drive rotation off the display's vsync so step sizes stay even at low RPM. / 中文：跟随显示器 vsync 驱动旋转，
                    // The static bloom / inner dot stay outside this subtree so they don't re-evaluate per frame. / 中文：低速下步进才不会忽长忽短。静态光晕和内圆点放在子树外，避免每帧重新求值。
                    // Capped at 60 fps: on 120 Hz ProMotion panels an uncapped / 中文：限频 60 fps：在 120 Hz ProMotion 屏上不限频的
                    // `.animation` ticks every refresh, doubling the rotor's / 中文：`.animation` 每次刷新都 tick，让转子重绘开销翻倍，
                    // re-render cost for no perceptible smoothness gain. / 中文：而流畅度并无可感知提升。
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let degrees = (anchorAngle + (t - anchorTime) * visualRps * 360)
                            .truncatingRemainder(dividingBy: 360)

                        rotor(radius: r, hub: hub, degrees: degrees)
                    }
                } else {
                    rotor(radius: r, hub: hub, degrees: anchorAngle)
                }

                // Inner dot — static, outside `TimelineView`. / 中文：内部黑点——静态，放在 `TimelineView` 外。
                Circle()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: hub * 0.7, height: hub * 0.7)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: visualRps) { oldRps, _ in
            // Freeze the angle reached under the old rate, then re-anchor — / 中文：冻结旧速率下已经到达的角度，然后重新锚定，
            // keeps rotation continuous across RPM changes. / 中文：确保 RPM 变化时旋转保持连续。
            let now = Date().timeIntervalSinceReferenceDate
            anchorAngle = (anchorAngle + (now - anchorTime) * oldRps * 360)
                .truncatingRemainder(dividingBy: 360)
            anchorTime = now
        }
    }

    private func rotor(radius r: CGFloat, hub: CGFloat, degrees: Double) -> some View {
        ZStack {
            FanRotorShape(bladeCount: bladeCount)
                .fill(bladeGradient)
                .overlay {
                    FanRotorShape(bladeCount: bladeCount)
                        .stroke(strokeColor.opacity(0.18), lineWidth: 0.5)
                }
                .frame(width: r * 2, height: r * 2)
                .rotationEffect(.degrees(degrees))
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.35 : 0.16),
                        radius: 2, x: 0, y: 1.5)

            // Hub — the only place that takes the accent color. / 中文：轮毂：唯一使用强调色的位置。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            accent,
                            accent.opacity(0.7),
                        ],
                        center: UnitPoint(x: 0.38, y: 0.32),
                        startRadius: 0,
                        endRadius: hub
                    )
                )
                .frame(width: hub * 2, height: hub * 2)
                .rotationEffect(.degrees(degrees))
        }
    }

    private var bladeGradient: LinearGradient {
        let tip  = scheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.36)
        let root = scheme == .dark ? Color.white.opacity(0.78) : Color.black.opacity(0.66)
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: tip,  location: 0.0),
                .init(color: root, location: 1.0),
            ]),
            startPoint: .top, endPoint: .center
        )
    }

    private var strokeColor: Color {
        scheme == .dark ? Color.white : Color.black
    }
}

// MARK: - BladeShape / 中文：叶片形状
//
// Single swept-blade petal in unit coordinates (-1..1), pointing up. / 中文：单位坐标（-1..1）中朝上的单个扫掠叶片花瓣。
// Direct port of the path used in the HTML reference. / 中文：直接移植 HTML 参考实现中的路径。

private struct FanRotorShape: Shape {
    let bladeCount: Int

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r  = min(rect.width, rect.height) / 2

        func point(_ x: CGFloat, _ y: CGFloat, rotation: CGFloat) -> CGPoint {
            let c = cos(rotation)
            let s = sin(rotation)
            return CGPoint(
                x: cx + (x * c - y * s) * r,
                y: cy + (x * s + y * c) * r
            )
        }

        var p = Path()
        let count = max(1, bladeCount)
        let step = 2 * CGFloat.pi / CGFloat(count)
        for i in 0..<count {
            let rotation = CGFloat(i) * step
            p.move(to: point(-0.025, -0.13, rotation: rotation))
            p.addCurve(to: point( 0.16, -0.54, rotation: rotation),
                       control1: point( 0.10, -0.16, rotation: rotation),
                       control2: point( 0.20, -0.34, rotation: rotation))
            p.addCurve(to: point(-0.05, -0.62, rotation: rotation),
                       control1: point( 0.10, -0.64, rotation: rotation),
                       control2: point( 0.00, -0.66, rotation: rotation))
            p.addCurve(to: point(-0.025, -0.13, rotation: rotation),
                       control1: point(-0.08, -0.50, rotation: rotation),
                       control2: point(-0.08, -0.32, rotation: rotation))
            p.closeSubpath()
        }
        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        FanBladeView(rpm: 1300, accent: Theme.accent(for: .cool,   scheme: .dark))
            .frame(width: 92, height: 92)
        FanBladeView(rpm: 2800, accent: Theme.accent(for: .normal, scheme: .dark))
            .frame(width: 92, height: 92)
        FanBladeView(rpm: 5800, accent: Theme.accent(for: .hot,    scheme: .dark))
            .frame(width: 92, height: 92)
    }
    .padding(24)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
