//
//  File: FanDetailsListView.swift / 文件：FanDetailsListView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Per-fan RPM list for the Fans tab. / 描述：风扇页签中的单风扇 RPM 列表。
//

import SwiftUI

struct FanDetailsMetrics: Equatable {
    var numberOfFans: Int
    var fanSpeeds: [Int]
    var fanMinSpeeds: [Int]
    var fanMaxSpeeds: [Int]
    var maxTemperature: Double
}

struct FanDetailsListView: View {
    var metrics: FanDetailsMetrics

    @Environment(\.colorScheme) private var scheme

    private var accent: Color {
        Theme.accent(for: metrics.maxTemperature, scheme: scheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("sensors.fan_details", comment: "").uppercased())
                    .font(Theme.label(10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.text3)
                Spacer()
                let key = metrics.numberOfFans == 1
                    ? "fan.count_singular" : "fan.count_plural"
                Text(String(format: NSLocalizedString(key, comment: ""),
                            metrics.numberOfFans))
                    .font(Theme.num(11, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ForEach(0..<metrics.numberOfFans, id: \.self) { i in
                if i > 0 {
                    Rectangle()
                        .fill(Theme.separator(scheme))
                        .frame(height: 0.5)
                        .padding(.horizontal, 14)
                }
                fanRow(i)
            }
            .padding(.bottom, 2)
        }
        .themedCard(scheme)
    }

    private func fanRow(_ index: Int) -> some View {
        let rpm = index < metrics.fanSpeeds.count ? metrics.fanSpeeds[index] : 0
        let mn = minRPM(atFan: index)
        let mx = maxRPM(atFan: index)
        let pct = mx > mn
            ? Double(rpm - mn) / Double(mx - mn)
            : 0
        return HStack(spacing: 10) {
            Text("F\(index + 1)")
                .font(Theme.label(11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.text3)
                .frame(width: 26, alignment: .leading)

            HeatBar(value: Double(rpm), min: Double(mn), max: Double(mx),
                    accent: accent, height: 3)

            Text("\(rpm)")
                .font(Theme.num(12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .opacity(rpm > 0 ? 1 : 0.45)
        .accessibilityLabel(String(format: NSLocalizedString("fan.number", comment: ""), index + 1))
        .accessibilityValue("\(rpm) rpm, \(Int(pct * 100))%")
    }

    private func minRPM(atFan index: Int) -> Int {
        guard index >= 0, index < metrics.fanMinSpeeds.count else {
            return FanRPMBounds.fallbackMinWhenSMCUnreadable
        }
        return metrics.fanMinSpeeds[index]
    }

    private func maxRPM(atFan index: Int) -> Int {
        guard index >= 0, index < metrics.fanMaxSpeeds.count else {
            return FanRPMBounds.fallbackMaxWhenSMCUnreadable
        }
        return metrics.fanMaxSpeeds[index]
    }
}
