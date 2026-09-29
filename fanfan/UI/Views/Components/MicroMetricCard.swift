//
//  File: MicroMetricCard.swift / 文件：MicroMetricCard.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Dense four-up temperature metric tile. / 描述：紧凑的四列温度指标卡片。
//

import SwiftUI

struct MicroMetricCard: View {
    var label: String
    var temp: Double?
    /// Hover tooltip explaining what the number is, e.g. hottest core. / 中文：悬停提示，说明数值含义，例如最热核心。
    var help: String? = nil

    @Environment(\.colorScheme) private var scheme

    private var accent: Color { Theme.accent(for: temp, scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.label(9, weight: .bold))
                .tracking(0.6)
                .foregroundColor(Theme.text3(scheme))

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(temp.map { String(format: "%.0f", $0) } ?? "—")
                    .font(Theme.display(20, weight: .light))
                    .foregroundStyle(Theme.heroText(scheme))
                    .contentTransition(.numericText())
                Text("°")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Theme.text3(scheme))
            }
            .padding(.bottom, 2)

            HeatBar(value: temp, accent: accent, height: 3)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(scheme, cornerRadius: 8)
        .help(help ?? "")
    }
}
