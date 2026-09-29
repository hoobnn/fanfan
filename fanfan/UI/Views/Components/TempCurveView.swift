//
//  File: TempCurveView.swift / 文件：TempCurveView.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Sixty-second temperature sparkline. / 描述：六十秒温度迷你曲线。
//

import SwiftUI

struct TempCurveView: View {
    /// History of max-temperature readings, oldest first. Typically 60 samples. / 中文：历史记录 of max-温度 读取ings, oldest first. Typically 60 采样s.
    var samples: [Double]
    var minValue: Double = 30
    var maxValue: Double = 100
    /// Optional reference threshold drawn as a dashed guide (e.g. warm cutoff). / 中文：Optional reference 阈值 drawn as a dashed guide (e.g. warm cutoff).
    var reference: Double? = 78
    var accent: Color

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = points(in: CGSize(width: w, height: h))

            ZStack {
                if let r = reference {
                    let y = yFor(r, height: h)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.primary.opacity(0.10),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }

                if let area = areaPath(pts, in: CGSize(width: w, height: h)) {
                    area.fill(
                        LinearGradient(
                            colors: [accent.opacity(0.22), accent.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                if let line = linePath(pts) {
                    line.stroke(accent, style: StrokeStyle(lineWidth: 1.4,
                                                           lineCap: .round,
                                                           lineJoin: .round))
                        .shadow(color: accent.opacity(scheme == .dark ? 0.5 : 0.32),
                                radius: 3, x: 0, y: 1)
                }

                if let last = pts.last {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 10, height: 10)
                        .position(x: last.x, y: last.y)
                    Circle()
                        .fill(accent)
                        .frame(width: 4.4, height: 4.4)
                        .position(x: last.x, y: last.y)
                }
            }
        }
    }

    // MARK: - Math / 中文：数学

    private func yFor(_ v: Double, height: CGFloat) -> CGFloat {
        let pad: CGFloat = 6
        let norm = (v - minValue) / (maxValue - minValue)
        let clamped = Swift.max(0, Swift.min(1, norm))
        return height - pad - CGFloat(clamped) * (height - pad * 2)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let n = CGFloat(samples.count - 1)
        return samples.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) / n * size.width,
                    y: yFor(v, height: size.height))
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path? {
        guard pts.count >= 2 else { return nil }
        var p = Path()
        p.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let a = pts[i]
            let b = pts[i + 1]
            let cx = (a.x + b.x) / 2
            p.addCurve(to: b,
                       control1: CGPoint(x: cx, y: a.y),
                       control2: CGPoint(x: cx, y: b.y))
        }
        return p
    }

    private func areaPath(_ pts: [CGPoint], in size: CGSize) -> Path? {
        guard let line = linePath(pts), let last = pts.last else { return nil }
        var p = line
        p.addLine(to: CGPoint(x: last.x, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }
}
