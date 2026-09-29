//
//  File: SensorListView.swift / 文件：SensorListView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Sensor list grouped by category. / 描述：按类别分组的传感器列表。
//

import SwiftUI

struct SensorListView: View {
    let sections: [SensorSection]

    @Environment(\.colorScheme) private var scheme

    /// Row order per category, fixed when the page appears (hottest first) so / 中文：每个类别的行顺序在页面出现时固定（最热在前），
    /// rows keep their place while values update instead of reshuffling. / 中文：数值更新时行位置不变，不会来回重排。
    @State private var ranking: [SensorCategory: [String]] = [:]
    @State private var expanded: Set<SensorCategory> = []

    /// Rows visible before "Show all". / 中文：「显示全部」之前可见的行数。
    private let collapsedRowCount = 4

    var body: some View {
        if sections.isEmpty {
            EmptySensorState()
        } else {
            VStack(spacing: 8) {
                ForEach(sections) { section in
                    sectionCard(section)
                }
            }
            .onAppear { ranking = Self.rank(sections, previous: [:]) }
            .onChange(of: sections) { _, newSections in
                // Only append newly seen keys; existing rows never move. / 中文：只追加新出现的键；已有行不移动。
                ranking = Self.rank(newSections, previous: ranking)
            }
        }
    }

    static func rank(_ sections: [SensorSection],
                     previous: [SensorCategory: [String]]) -> [SensorCategory: [String]] {
        var result = previous
        for section in sections {
            let known = previous[section.category] ?? []
            let knownSet = Set(known)
            let fresh = section.sensors
                .filter { !knownSet.contains($0.id) }
                .sorted { $0.temperature != $1.temperature ? $0.temperature > $1.temperature : $0.id < $1.id }
                .map(\.id)
            result[section.category] = known + fresh
        }
        return result
    }

    private func orderedSensors(_ section: SensorSection) -> [SensorReading] {
        let byID = Dictionary(uniqueKeysWithValues: section.sensors.map { ($0.id, $0) })
        let order = ranking[section.category] ?? section.sensors.map(\.id)
        return order.compactMap { byID[$0] }
    }

    private func sectionCard(_ section: SensorSection) -> some View {
        let accent = Theme.accent(for: section.maxTemperature, scheme: scheme)
        let sensors = orderedSensors(section)
        let isExpanded = expanded.contains(section.category)
        let visible = isExpanded ? sensors : Array(sensors.prefix(collapsedRowCount))
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(section.category.displayName.uppercased())
                    .font(Theme.label(10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.text3)
                Text("\(section.sensors.count)")
                    .font(Theme.num(9, weight: .medium))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text(String(format: "%.0f°", section.maxTemperature))
                    .font(Theme.num(11, weight: .semibold))
                    .foregroundColor(accent)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, sensor in
                if idx > 0 {
                    separator
                }
                sensorRow(sensor)
            }

            if sensors.count > collapsedRowCount {
                separator
                Button {
                    if isExpanded {
                        expanded.remove(section.category)
                    } else {
                        expanded.insert(section.category)
                    }
                } label: {
                    Text(isExpanded
                         ? NSLocalizedString("sensors.show_less", comment: "")
                         : String(format: NSLocalizedString("sensors.show_all", comment: ""), sensors.count))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, idxBottomPad)
        .themedCard(scheme)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 12)
            .padding(.trailing, 12)
    }

    private var idxBottomPad: CGFloat { 2 }

    private func sensorRow(_ sensor: SensorReading) -> some View {
        let accent = Theme.accent(for: sensor.temperature, scheme: scheme)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Text(sensor.id)
                    .font(Theme.num(9, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.4)
            }
            Spacer()
            HeatBar(value: sensor.temperature, accent: accent, height: 3)
                .frame(width: 60)
            Text(String(format: "%.0f°", sensor.temperature))
                .font(Theme.num(12, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct EmptySensorState: View {
    var body: some View {
        ContentUnavailableView(NSLocalizedString("sensors.none", comment: ""),
                               systemImage: "thermometer.medium.slash")
    }
}
