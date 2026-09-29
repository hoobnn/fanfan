//
//  File: HeroCard.swift / 文件：HeroCard.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Top popover summary for temperature and fan status. / 描述：弹出窗口顶部的温度与风扇状态摘要。
//

import SwiftUI

struct HeroCardMetrics: Equatable {
    var maxTemperature: Double
    var currentFanSpeed: Int
    var minRPM: Int
    var maxRPM: Int
    var hasBattery: Bool
    var batteryPowerWatts: Double?
    var batteryPercentage: Int
}

struct HeroCard: View {
    var metrics: HeroCardMetrics
    var bladeCount: Int = 5
    /// Fanless Macs (e.g. MacBook Air) hide the blade and fan stats — the card / 中文：无风扇 Mac (e.g. MacBook Air) hide the blade and 风扇 stats — the 卡片
    /// then reads as a plain temperature display. / 中文：then 读取s as a plain 温度 display.
    var showsFan: Bool = true

    @Environment(\.colorScheme) private var scheme

    private var maxTemp: Double { metrics.maxTemperature }
    private var level: TemperatureLevel? { TemperatureLevel.of(maxTemp) }
    private var accent: Color { Theme.accent(for: level, scheme: scheme) }

    private var loadPct: Int {
        let span = Swift.max(1, metrics.maxRPM - metrics.minRPM)
        let n = Double(metrics.currentFanSpeed - metrics.minRPM) / Double(span)
        return Int((Swift.max(0, Swift.min(1, n)) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 4.5, height: 4.5)
                            .overlay(Circle().stroke(accent.opacity(0.25), lineWidth: 2.6))
                        Text((level?.label.uppercased() ?? "—"))
                            .font(Theme.label(10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.text3)
                        Text("·  " + NSLocalizedString("hero.max_temp", comment: ""))
                            .font(Theme.label(10, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(Theme.text4)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(maxTemp > 0 ? String(format: "%.0f", maxTemp) : "—")
                            .font(Theme.display(40, weight: .regular))
                            .foregroundStyle(Theme.heroText(scheme))
                            .contentTransition(.numericText())
                        Text("°C")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.text3)
                    }
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
                if showsFan {
                    FanBladeView(
                        rpm: metrics.currentFanSpeed,
                        maxRpm: Swift.max(metrics.maxRPM, 6500),
                        bladeCount: bladeCount,
                        accent: accent
                    )
                    .frame(width: 80, height: 80)
                    .background(
                        // Temperature halo — the blade quietly lights its surroundings. / 中文：温度光晕：叶片轻微照亮周围区域。
                        Circle()
                            .fill(accent.opacity(scheme == .dark ? 0.16 : 0.10))
                            .blur(radius: 12)
                            .padding(8)
                    )
                }
            }

            VStack(spacing: 3) {
                HeatBar(value: maxTemp, accent: accent, height: 3)
                HStack {
                    Text("30°").font(Theme.num(9, weight: .medium))
                    Spacer()
                    Text("50°").font(Theme.num(9, weight: .medium))
                    Spacer()
                    Text("70°").font(Theme.num(9, weight: .medium))
                    Spacer()
                    Text("90°").font(Theme.num(9, weight: .medium))
                    Spacer()
                    Text("100°").font(Theme.num(9, weight: .medium))
                }
                .foregroundStyle(Theme.text4)
            }

            if showsFan || metrics.hasBattery {
                Divider()

                HStack(spacing: 0) {
                    if showsFan {
                        stat(value: "\(metrics.currentFanSpeed)", unit: "rpm")
                        statSeparator
                        stat(value: "\(loadPct)", unit: NSLocalizedString("hero.unit.load", comment: ""))
                        if metrics.hasBattery { statSeparator }
                    }
                    if metrics.hasBattery {
                        if let w = metrics.batteryPowerWatts {
                            stat(value: String(format: "%.1f", w), unit: "W")
                            statSeparator
                        }
                        stat(value: "\(metrics.batteryPercentage)",
                             unit: NSLocalizedString("hero.unit.battery", comment: ""))
                    }
                }
            }
        }
        .padding(12)
        .themedCard(scheme)
    }

    private func stat(value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(Theme.num(12, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text(unit)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
    }

    private var statSeparator: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(width: 0.5, height: 9)
    }
}
