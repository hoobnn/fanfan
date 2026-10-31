//
//  File: PageSwitcher.swift / 文件：PageSwitcher.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/10/31. / 创建者：haobin，日期：2026/10/31。
//  Description: Two-page switcher with a Liquid Glass puck. / 描述：带 Liquid Glass 滑块的双页切换器。
//

import SwiftUI

/// Flat track with a system Liquid Glass puck. The puck follows `progress` / 中文：平底轨道加系统 Liquid Glass 滑块。滑块跟随 `progress`
/// (0 = first page, 1 = last) continuously, so it tracks a trackpad swipe / 中文：（0 = 第一页，1 = 最后一页）连续移动，触控板滑到一半时
/// mid-gesture instead of jumping once the page lands. A segmented `Picker` / 中文：它也跟着走，而不是等翻页落定才跳。不用分段 `Picker`：
/// can't follow a gesture, and its blue selection would match the mode / 中文：它跟不了手势，蓝色选中态也会和卡片里的模式选择器
/// pickers inside the cards. / 中文：混为一谈。
struct PageSwitcher: View {
    let titles: [String]
    let progress: CGFloat
    let accessibilityLabel: String
    let select: (Int) -> Void

    @Environment(\.colorScheme) private var scheme

    private static let height: CGFloat = 26
    private static let inset: CGFloat = 2.5
    private static let segmentWidth: CGFloat = 96

    var body: some View {
        let selected = Int(progress.rounded())
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Theme.fill2(scheme))

            Color.clear
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .frame(width: Self.segmentWidth, height: Self.height - Self.inset * 2)
                .offset(x: Self.inset + progress * Self.segmentWidth)

            HStack(spacing: 0) {
                ForEach(titles.indices, id: \.self) { i in
                    Button { select(i) } label: {
                        Text(titles[i])
                            .font(.system(size: 11.5, weight: i == selected ? .semibold : .medium))
                            .foregroundStyle(i == selected ? Theme.text1 : Theme.text2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: Self.segmentWidth, height: Self.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(i == selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Self.inset)
        }
        .frame(width: Self.segmentWidth * CGFloat(titles.count) + Self.inset * 2,
               height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
