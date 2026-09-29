//
//  File: HeatBar.swift / 文件：HeatBar.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Single-accent temperature gradient bar. / 描述：单一强调色的温度渐变条。
//

import SwiftUI

struct HeatBar: View {
    var value: Double?
    var min: Double = 30
    var max: Double = 100
    var accent: Color
    var height: CGFloat = 3

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Recessed track — a faint inner edge sells the inset. / 中文：内嵌轨道：微弱内边缘强化凹陷感。
                Capsule()
                    .fill(Theme.fill2(scheme))
                    .overlay(
                        Capsule().strokeBorder(
                            scheme == .dark ? Color.black.opacity(0.28)
                                            : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                    )

                // Lit fill — a top highlight makes it read as a glassy element, / 中文：高光填充：顶部高光让它呈现玻璃质感，
                // and a soft glow gives the accent presence. / 中文：柔和辉光让强调色更有存在感。
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.62), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.38), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .frame(width: geo.size.width * pct)
                    .shadow(color: accent.opacity(scheme == .dark ? 0.6 : 0.38),
                            radius: 2.5, x: 0, y: 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: pct)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
    }

    private var pct: CGFloat {
        guard let v = value else { return 0 }
        return Swift.max(0, Swift.min(1, (v - min) / (max - min)))
    }
}
