//
//  File: ResponseCurveView.swift / 文件：ResponseCurveView.swift
//  Target: fanfan / 目标：fanfan
//
//  Description: Draws the fan-speed curves of every strategy against temperature, and edits the / 描述：绘制各策略的温度-转速曲线，并编辑所选策略的控制点。
//  selected one by dragging its points. Temperature is the only colour on the chart, as in the rest of / 中文：与界面其他部分一致，图中只有温度使用颜色。
//  the UI. / 中文：控制点颜色同样取自温度。
//

import AppKit
import SwiftUI

struct ResponseCurveView: View {
    let strategies: [FanStrategy]
    let selectedID: String
    let floorRPM: Int
    let hardwareMaxRPM: Int
    let protectionFraction: Double
    /// Live reading drawn as a dot on the selected curve, if available. / 中文：可用时，在所选曲线上绘制一个实时读数点。
    let liveTemperature: Double?
    let liveRPM: Double?
    /// Receives the curve after a point is dragged, added or removed. nil makes the chart read-only. / 中文：拖动、添加或删除控制点后接收新曲线；为 nil 时图表只读。
    var onCommit: ((FanCurve) -> Void)?
    /// Plot height; Settings passes a taller value than the 196 pt default when the window has room. / 中文：图表高度；设置窗口空间充足时传入比默认 196 pt 更高的值。
    var chartHeight: CGFloat = 196

    @Environment(\.colorScheme) private var scheme
    /// Points shown while a drag is in progress, or until the commit lands in the model. / 中文：拖动过程中显示的控制点，直到提交结果写入模型为止。
    @State private var draft: [CurvePoint]?
    @State private var selectedIndex: Int?
    @State private var dragIndex: Int?
    @State private var dragging = false
    @State private var addingPoint = false
    @State private var hoveredIndex: Int?
    @State private var dragOrigin: CGPoint?
    /// Points when the drag began. Each frame moves from these, so neighbours pushed aside / 中文：拖动开始时的控制点。每一帧都从它出发计算，
    /// spring back if the pointer returns before release. / 中文：松手前拖回来，被推开的相邻点也会复位。
    @State private var dragBase: [CurvePoint]?
    @State private var undoHistory: [[CurvePoint]] = []
    @State private var redoHistory: [[CurvePoint]] = []
    /// Previous empty-area click, used to recognise a double-click inside the drag gesture. / 中文：上一次在空白处的单击，用于在拖动手势里识别双击。
    @State private var lastEmptyClick: (time: TimeInterval, location: CGPoint)?
    /// The chart takes keyboard focus when clicked, so Delete removes the selected point and the / 中文：点击图表即获得键盘焦点：删除键移除所选控制点，
    /// arrow keys nudge it. It also pulls focus out of any text field in the window. / 中文：方向键微调它；同时让窗口里的输入框失去焦点。
    @FocusState private var chartFocused: Bool

    private static let insets = EdgeInsets(top: 20, leading: 38, bottom: 22, trailing: 16)
    private static let sampleStep = 1.0
    private static let handleHitRadius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let plot = plotRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    gridLines(in: plot)
                    axisLabels(in: plot)

                    ForEach(otherStrategies, id: \.id) { strategy in
                        curvePath(for: strategy.curve, in: plot)
                            .stroke(Theme.text3.opacity(0.45), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    }

                    if selectedStrategy != nil {
                        if isEditable {
                            curvePath(for: displayCurve, in: plot, protected: true)
                                .stroke(Theme.text3, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        }
                        curvePath(for: displayCurve, in: plot, protected: !isEditable)
                            .stroke(temperatureGradient(in: plot),
                                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    }

                    if let temp = liveTemperature, let rpm = liveRPM {
                        liveDot(temp: temp, rpm: rpm, in: plot)
                    }

                    if isEditable {
                        selectionGuides(in: plot)
                        handles(in: plot)
                        readoutBubble(in: plot)
                        Color.clear
                            .contentShape(Rectangle())
                            .focusable()
                            .focused($chartFocused)
                            .focusEffectDisabled()
                            // The Delete key reaches a focused view as the delete command, not as a key press. / 中文：删除键以 delete 命令送达有焦点的视图，而不是按键事件。
                            .onDeleteCommand { removeSelected() }
                            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                                nudgeSelected(press)
                            }
                            .onKeyPress(.escape) {
                                guard selectedIndex != nil || addingPoint else { return .ignored }
                                selectedIndex = nil
                                addingPoint = false
                                return .handled
                            }
                            .gesture(editGesture(in: plot))
                            .pointerStyle(pointerStyle)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): hoveredIndex = handleIndex(near: location, in: plot)
                                case .ended: hoveredIndex = nil
                                }
                            }
                    }
                }
            }
            .frame(height: chartHeight)

            legend

            if isEditable {
                Divider().padding(.top, 4)
                editorControls
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: committedPoints) { _, _ in
            if draft != committedPoints {
                undoHistory = []
                redoHistory = []
                selectedIndex = nil
            }
            draft = nil
        }
        .onChange(of: selectedID) { _, _ in
            draft = nil
            selectedIndex = nil
            addingPoint = false
            dragging = false
            dragIndex = nil
            dragOrigin = nil
            undoHistory = []
            redoHistory = []
        }
    }

    /// One compact row under the chart: the hint or the selected point's values on the left, icon / 中文：图表下方一行紧凑工具栏：左侧是提示或所选控制点的数值，
    /// tools on the right. Its height never changes with the selection. / 中文：右侧是图标工具；高度不随选中状态变化。
    private var editorControls: some View {
        HStack(spacing: 10) {
            Group {
                if !addingPoint, let index = selectedIndex, displayPoints.indices.contains(index) {
                    pointFields(index: index, point: displayPoints[index])
                } else {
                    Text(NSLocalizedString(addingPoint ? "settings.curve_add_hint" : "settings.curve_hint", comment: ""))
                        .font(.caption)
                        .foregroundStyle(addingPoint ? Theme.text1 : Theme.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)

            HStack(spacing: 2) {
                toolButton(addingPoint ? "plus.circle.fill" : "plus.circle",
                           help: "\(NSLocalizedString("settings.curve_add_point", comment: "")) (\(displayPoints.count)/\(FanCurve.pointCountRange.upperBound))",
                           enabled: addingPoint || displayPoints.count < FanCurve.pointCountRange.upperBound) {
                    addingPoint.toggle()
                }
                toolButton("minus.circle", help: "\(NSLocalizedString("settings.curve_remove_point", comment: "")) (⌫)",
                           enabled: canRemoveSelected) { removeSelected() }
                Divider().frame(height: 14).padding(.horizontal, 4)
                toolButton("arrow.uturn.backward", help: NSLocalizedString("settings.curve_undo", comment: ""),
                           enabled: !undoHistory.isEmpty) { restoreHistory(undo: true) }
                toolButton("arrow.uturn.forward", help: NSLocalizedString("settings.curve_redo", comment: ""),
                           enabled: !redoHistory.isEmpty) { restoreHistory(undo: false) }
            }
            .fixedSize()
        }
    }

    /// Temperature and fan speed of the selected point: type a value, or step it one unit at a time. / 中文：所选控制点的温度与转速：可直接输入，也可逐级步进。
    /// Labels sit outside the steppers: inside a Form a labelled Stepper takes the row's label/control / 中文：标签放在步进器外面。Form 里带标签的 Stepper 会套用整行的
    /// layout and claims the full row width, which pushed the form wider than the window. / 中文：标签/控件布局并占满行宽，曾把表单撑得比窗口还宽。
    private func pointFields(index: Int, point: CurvePoint) -> some View {
        let bounds = displayCurve.temperatureBounds(for: index)
        let tempText = Binding<Int>(
            get: { Int(point.temp.rounded()) },
            set: { editSelected(CurvePoint(temp: clamp(Double($0), bounds), fraction: point.fraction)) }
        )
        let tempStep = Binding<Double>(
            get: { point.temp },
            set: { editSelected(CurvePoint(temp: $0, fraction: point.fraction)) }
        )
        let rpmText = Binding<Int>(
            get: { Int(rpm(forFraction: point.fraction).rounded()) },
            set: { editSelected(CurvePoint(temp: point.temp, fraction: clamp((Double($0) - rpmDomain.lowerBound) / span, 0...1))) }
        )
        let fractionStep = Binding<Double>(
            get: { point.fraction },
            set: { editSelected(CurvePoint(temp: point.temp, fraction: $0)) }
        )
        return HStack(spacing: 16) {
            // The end points are pinned at 40 °C and 100 °C, so only their speed is editable. / 中文：首尾点固定在 40 °C 与 100 °C，只能改转速。
            valueField(label: "settings.curve_field_temp", unit: "°C", width: 34, text: tempText) {
                Stepper("", value: tempStep, in: bounds, step: FanCurve.temperatureStep)
            }
            .disabled(displayCurve.isPinned(index))
            valueField(label: "settings.curve_field_rpm", unit: "RPM", width: 46, text: rpmText) {
                Stepper("", value: fractionStep, in: 0...1, step: FanCurve.fractionStep)
            }
        }
        .controlSize(.small)
    }

    private func valueField<S: View>(label: String, unit: String, width: CGFloat, text: Binding<Int>,
                                     @ViewBuilder stepper: () -> S) -> some View {
        HStack(spacing: 5) {
            Text(NSLocalizedString(label, comment: ""))
                .font(.caption)
                .foregroundStyle(Theme.text2)
            TextField("", value: text, format: IntegerFormatStyle<Int>().grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(Theme.num(11.5, weight: .medium))
                .frame(width: width)
                .labelsHidden()
            Text(verbatim: unit)
                .font(Theme.num(10.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            stepper()
                .labelsHidden()
                .padding(.leading, -2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString(label, comment: ""))
    }

    private func toolButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("settings.curve_legend_curve") {
                Capsule()
                    .fill(LinearGradient(colors: [Theme.thermalColor(forTemperature: 50, scheme: scheme),
                                                  Theme.thermalColor(forTemperature: 90, scheme: scheme)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 14, height: 2.2)
            }
            if isEditable {
                legendItem("settings.curve_legend_protected") {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: 14, y: 1))
                    }
                    .stroke(Theme.text3, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .frame(width: 14, height: 2)
                }
            }
            if !otherStrategies.isEmpty {
                legendItem("settings.curve_legend_others") {
                    Capsule().fill(Theme.text3.opacity(0.7)).frame(width: 14, height: 1.2)
                }
            }
            if let temp = liveTemperature, liveRPM != nil {
                legendItem("settings.curve_legend_live") {
                    Circle()
                        .fill(Theme.thermalColor(forTemperature: temp, scheme: scheme))
                        .frame(width: 5, height: 5)
                        .background(Circle().fill(Theme.thermalColor(forTemperature: temp, scheme: scheme).opacity(0.22))
                            .frame(width: 11, height: 11))
                        .frame(width: 14)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.insets.leading)
        .font(.caption2)
        .foregroundStyle(Theme.text2)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func legendItem<Glyph: View>(_ key: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 4) {
            glyph()
            Text(NSLocalizedString(key, comment: ""))
        }
        .accessibilityElement(children: .combine)
    }

    private var pointerStyle: PointerStyle? {
        if dragIndex != nil { return .grabActive }
        if hoveredIndex != nil { return .grabIdle }
        return addingPoint ? .rectSelection : nil
    }

    private func editSelected(_ point: CurvePoint) {
        guard let index = selectedIndex else { return }
        commit(displayCurve.movingPoint(at: index, to: point).points)
    }

    /// Arrow keys move the selected point one step (Shift: five), the same steps as the fields below. / 中文：方向键按一级步进移动所选控制点（按住 Shift 为五级），与下方输入框一致。
    private func nudgeSelected(_ press: KeyPress) -> KeyPress.Result {
        guard !addingPoint, let index = selectedIndex, displayPoints.indices.contains(index) else { return .ignored }
        let point = displayPoints[index]
        let steps = press.modifiers.contains(.shift) ? 5.0 : 1.0
        var moved = point
        switch press.key {
        case .leftArrow:  moved.temp -= FanCurve.temperatureStep * steps
        case .rightArrow: moved.temp += FanCurve.temperatureStep * steps
        case .upArrow:    moved.fraction += FanCurve.fractionStep * steps
        case .downArrow:  moved.fraction -= FanCurve.fractionStep * steps
        default: return .ignored
        }
        editSelected(CurvePoint(temp: clamp(moved.temp, displayCurve.temperatureBounds(for: index)),
                                fraction: clamp(moved.fraction, 0...1)))
        return .handled
    }

    private func restoreHistory(undo: Bool) {
        let points: [CurvePoint]?
        if undo {
            points = undoHistory.popLast()
            if points != nil { redoHistory.append(committedPoints) }
        } else {
            points = redoHistory.popLast()
            if points != nil { undoHistory.append(committedPoints) }
        }
        guard let points else { return }
        selectedIndex = nil
        addingPoint = false
        draft = points
        onCommit?(FanCurve(points: points))
    }

    // MARK: - Data / 中文：数据

    private var isEditable: Bool { onCommit != nil }

    private var selectedStrategy: FanStrategy? {
        strategies.first { $0.id == selectedID }
    }

    private var otherStrategies: [FanStrategy] {
        strategies.filter { $0.id != selectedID }
    }

    private var committedPoints: [CurvePoint] {
        selectedStrategy?.curve.points ?? []
    }

    private var displayPoints: [CurvePoint] {
        draft ?? committedPoints
    }

    private var displayCurve: FanCurve {
        FanCurve(points: displayPoints)
    }

    private var canRemoveSelected: Bool {
        guard let index = selectedIndex else { return false }
        return committedPoints.indices.contains(index)
            && committedPoints.count > FanCurve.pointCountRange.lowerBound
            && !FanCurve(points: committedPoints).isPinned(index)
    }

    private func readoutText(for point: CurvePoint) -> String {
        String(
            format: NSLocalizedString("settings.curve_point_readout", comment: ""),
            Int(point.temp.rounded()),
            Int(rpm(forFraction: point.fraction).rounded())
        )
    }

    /// Every curve shares one fan-speed domain, so strategies compare directly. / 中文：所有曲线共用同一转速量程，便于直接比较。
    private var rpmDomain: ClosedRange<Double> {
        let lo = Double(floorRPM)
        let hi = Double(max(hardwareMaxRPM, floorRPM + 1))
        return lo...hi
    }

    private var span: Double {
        rpmDomain.upperBound - rpmDomain.lowerBound
    }

    private func rpm(forFraction fraction: Double) -> Double {
        rpmDomain.lowerBound + fraction * span
    }

    /// The curve as the controller runs it, including the thermal-protection lift. / 中文：控制器实际运行的曲线，包含高温保护抬升。
    private func rpm(for curve: FanCurve, at temp: Double) -> Double {
        ResponseCurve.target(
            curveTemp: temp,
            safetyTemp: temp,
            curve: curve,
            floor: floorRPM,
            hardwareMax: hardwareMaxRPM,
            protectionFraction: protectionFraction
        ).rpm
    }

    // MARK: - Editing / 中文：编辑

    private func editGesture(in plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    chartFocused = true
                    dragIndex = handleIndex(near: value.startLocation, in: plot)
                    if let index = dragIndex {
                        lastEmptyClick = nil
                        selectedIndex = index
                        dragOrigin = handleCenter(displayPoints[index], in: plot)
                        dragBase = displayPoints
                        addingPoint = false
                    }
                }
                guard let index = dragIndex, let origin = dragOrigin else { return }
                guard hypot(value.translation.width, value.translation.height) >= 3 else {
                    draft = nil
                    return
                }
                // Preserve the pointer offset so selecting a handle never moves it.
                draft = movedPoints(index: index,
                                    to: CGPoint(x: origin.x + value.translation.width,
                                                y: origin.y + value.translation.height), in: plot)
            }
            .onEnded { value in
                defer {
                    dragging = false
                    dragIndex = nil
                    dragOrigin = nil
                    dragBase = nil
                }
                if let index = dragIndex {
                    selectedIndex = index
                    if let draft {
                        commit(draft)
                    }
                } else if hypot(value.translation.width, value.translation.height) < 4 {
                    // The drag gesture (minimum distance 0) swallows taps, so double-clicks are
                    // recognised here rather than with a competing onTapGesture(count: 2).
                    // 中文：minimumDistance 为 0 的拖动手势会吞掉点击，因此在这里识别双击，而不是叠加 onTapGesture(count: 2)。
                    let now = ProcessInfo.processInfo.systemUptime
                    let isDoubleClick = lastEmptyClick.map {
                        now - $0.time <= NSEvent.doubleClickInterval
                            && hypot($0.location.x - value.location.x, $0.location.y - value.location.y) <= 6
                    } ?? false
                    if addingPoint || isDoubleClick {
                        lastEmptyClick = nil
                        addPoint(at: value.location, in: plot)
                    } else {
                        lastEmptyClick = (now, value.location)
                        selectedIndex = nil
                    }
                }
            }
    }

    /// Moves one point, held between its neighbours so the curve stays ordered and never falls. / 中文：移动一个控制点，并限定在相邻两点之间，使曲线保持有序且不下降。
    private func movedPoints(index: Int, to location: CGPoint, in plot: CGRect) -> [CurvePoint] {
        FanCurve(points: dragBase ?? displayPoints).movingPoint(at: index, to: CurvePoint(
            temp: tempFor(x: location.x, in: plot),
            fraction: fractionFor(y: location.y, in: plot)
        )).points
    }

    /// Inserts a point at the clicked temperature, then lifts or lowers it toward the clicked height, / 中文：在点击处的温度插入控制点，再把它移向点击的高度，
    /// held between its neighbours so the curve never falls. A click on the curve keeps its shape. / 中文：并限定在相邻两点之间，曲线不会下降；点在曲线上则形状不变。
    private func addPoint(at location: CGPoint, in plot: CGRect) {
        guard isEditable, plot.insetBy(dx: -Self.handleHitRadius, dy: -Self.handleHitRadius).contains(location) else { return }
        let temp = snapTemp(tempFor(x: location.x, in: plot))
        var curve = displayCurve.insertingPoint(at: temp)
        guard curve.points != displayPoints, let index = curve.points.firstIndex(where: { $0.temp == temp }) else {
            addingPoint = false
            return
        }
        let fraction = min(1, max(0, fractionFor(y: location.y, in: plot)))
        curve = curve.movingPoint(at: index, to: CurvePoint(temp: temp, fraction: fraction))
        selectedIndex = curve.points.firstIndex { $0.temp == temp }
        addingPoint = false
        commit(curve.points)
    }

    private func removeSelected() {
        guard canRemoveSelected, let index = selectedIndex else { return }
        var points = committedPoints
        points.remove(at: index)
        selectedIndex = nil
        commit(points)
    }

    /// Keeps the normalised points visible until the model reports them back. / 中文：在模型回传结果之前，保持规范化后的控制点可见。
    private func commit(_ points: [CurvePoint]) {
        let curve = FanCurve(points: points)
        guard curve.points != committedPoints else {
            draft = nil
            return
        }
        undoHistory.append(committedPoints)
        if undoHistory.count > 50 { undoHistory.removeFirst() }
        redoHistory = []
        draft = curve.points
        onCommit?(curve)
    }

    private func handleIndex(near location: CGPoint, in plot: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in displayPoints.enumerated() {
            let center = handleCenter(point, in: plot)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= Self.handleHitRadius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func snapTemp(_ temp: Double) -> Double {
        (temp / FanCurve.temperatureStep).rounded() * FanCurve.temperatureStep
    }

    // MARK: - Geometry / 中文：几何

    private func plotRect(in size: CGSize) -> CGRect {
        let insets = Self.insets
        return CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(1, size.width - insets.leading - insets.trailing),
            height: max(1, size.height - insets.top - insets.bottom)
        )
    }

    private func x(for temp: Double, in plot: CGRect) -> CGFloat {
        let range = FanCurve.temperatureRange
        let t = (temp - range.lowerBound) / (range.upperBound - range.lowerBound)
        return plot.minX + CGFloat(t) * plot.width
    }

    private func tempFor(x: CGFloat, in plot: CGRect) -> Double {
        let range = FanCurve.temperatureRange
        let t = Double((x - plot.minX) / plot.width)
        return clamp(range.lowerBound + t * (range.upperBound - range.lowerBound), range)
    }

    private func y(forRPM rpm: Double, in plot: CGRect) -> CGFloat {
        let t = (rpm - rpmDomain.lowerBound) / span
        return plot.maxY - CGFloat(min(1, max(0, t))) * plot.height
    }

    private func fractionFor(y: CGFloat, in plot: CGRect) -> Double {
        Double((plot.maxY - y) / plot.height)
    }

    private func handleCenter(_ point: CurvePoint, in plot: CGRect) -> CGPoint {
        CGPoint(x: x(for: point.temp, in: plot), y: y(forRPM: rpm(forFraction: point.fraction), in: plot))
    }

    private func curvePath(for curve: FanCurve, in plot: CGRect, protected: Bool = true) -> Path {
        var path = Path()
        let range = FanCurve.temperatureRange
        var temp = range.lowerBound
        var first = true
        while temp <= range.upperBound + 0.001 {
            let point = CGPoint(x: x(for: temp, in: plot), y: y(forRPM: protected ? rpm(for: curve, at: temp) : rpm(forFraction: curve.fraction(at: temp)), in: plot))
            if first {
                path.move(to: point)
                first = false
            } else {
                path.addLine(to: point)
            }
            temp += Self.sampleStep
        }
        return path
    }

    // MARK: - Decoration / 中文：装饰

    private func gridLines(in plot: CGRect) -> some View {
        Path { path in
            for fraction in [0.0, 0.5, 1.0] {
                let yPos = plot.maxY - CGFloat(fraction) * plot.height
                path.move(to: CGPoint(x: plot.minX, y: yPos))
                path.addLine(to: CGPoint(x: plot.maxX, y: yPos))
            }
        }
        .stroke(Theme.separator(scheme), lineWidth: 0.5)
    }

    private func axisLabels(in plot: CGRect) -> some View {
        let lo = rpmDomain.lowerBound
        let hi = rpmDomain.upperBound
        let mid = (lo + hi) / 2
        return ZStack(alignment: .topLeading) {
            Text(verbatim: "RPM")
                .font(Theme.num(9, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 34, alignment: .trailing)
                .position(x: plot.minX - 20, y: plot.minY - 12)
            // The floor label sits just above the baseline so it clears the x-axis labels. / 中文：下界标签放在基线上方，避免与横轴标签重叠。
            ForEach([(hi, 0.0), (mid, 0.0), (lo, -7.0)], id: \.0) { value, offset in
                Text(String(format: "%.0f", value))
                    .font(Theme.num(9, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 34, alignment: .trailing)
                    .position(x: plot.minX - 20, y: y(forRPM: value, in: plot) + offset)
            }
            ForEach([40.0, 60.0, 80.0, 100.0], id: \.self) { temp in
                Text(String(format: temp == 100 ? "%.0f°C" : "%.0f°", temp))
                    .font(Theme.num(9, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .position(x: x(for: temp, in: plot) - (temp == 100 ? 6 : 0), y: plot.maxY + 11)
            }
        }
    }

    /// Colour runs along the temperature axis, so the curve reads cool-to-hot. / 中文：颜色沿温度轴变化，曲线由冷到热渐变。
    private func temperatureGradient(in plot: CGRect) -> LinearGradient {
        let range = FanCurve.temperatureRange
        let stops = stride(from: range.lowerBound, through: range.upperBound, by: 10).map { temp in
            Gradient.Stop(
                color: Theme.thermalColor(forTemperature: temp, scheme: scheme),
                location: (temp - range.lowerBound) / (range.upperBound - range.lowerBound)
            )
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// Handles of the selected curve. They are coloured by their temperature, like everything else on the chart. / 中文：所选曲线的控制点，颜色同样取自温度。
    private func handles(in plot: CGRect) -> some View {
        ForEach(Array(displayPoints.enumerated()), id: \.offset) { index, point in
            let selected = index == selectedIndex
            let highlighted = selected || index == hoveredIndex
            Circle()
                .fill(Theme.thermalColor(forTemperature: point.temp, scheme: scheme))
                .overlay(Circle().stroke(Theme.text1, lineWidth: selected ? 1.6 : 0.8))
                .frame(width: highlighted ? 12 : 9, height: highlighted ? 12 : 9)
                .background {
                    Circle().fill(Theme.fill2(scheme)).frame(width: 24, height: 24).opacity(highlighted ? 1 : 0)
                }
                .position(handleCenter(point, in: plot))
                .accessibilityLabel(String(format: NSLocalizedString("settings.curve_point_readout", comment: ""),
                                           Int(point.temp.rounded()), Int(rpm(forFraction: point.fraction).rounded())))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { selectedIndex = index }
                .accessibilityAdjustableAction { direction in
                    selectedIndex = index
                    let delta = direction == .increment ? FanCurve.fractionStep : -FanCurve.fractionStep
                    editSelected(CurvePoint(temp: point.temp, fraction: point.fraction + delta))
                }
        }
    }

    private func selectionGuides(in plot: CGRect) -> some View {
        ZStack {
            if let index = selectedIndex, displayPoints.indices.contains(index) {
                let point = handleCenter(displayPoints[index], in: plot)
                Path { path in
                    path.move(to: CGPoint(x: point.x, y: plot.maxY))
                    path.addLine(to: CGPoint(x: point.x, y: plot.minY))
                    path.move(to: CGPoint(x: plot.minX, y: point.y))
                    path.addLine(to: CGPoint(x: plot.maxX, y: point.y))
                }
                .stroke(Theme.text3.opacity(0.5), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    /// Value bubble shown only while a handle is dragged or hovered; at rest the precision row below / 中文：仅在拖动或悬停控制点时显示数值气泡；
    /// carries the selected point's values, so the bubble never sits on the curve. / 中文：静止时由下方精调行展示，气泡不长期遮挡曲线。
    private func readoutBubble(in plot: CGRect) -> some View {
        ZStack {
            if let index = dragIndex ?? hoveredIndex, displayPoints.indices.contains(index) {
                let point = displayPoints[index]
                let center = handleCenter(point, in: plot)
                Text(readoutText(for: point))
                    .font(Theme.num(10, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize()
                    .position(x: min(plot.maxX - 50, max(plot.minX + 50, center.x)),
                              y: center.y < plot.minY + 24 ? center.y + 20 : center.y - 20)
            }
        }
        .allowsHitTesting(false)
    }

    private func liveDot(temp: Double, rpm: Double, in plot: CGRect) -> some View {
        let color = Theme.thermalColor(forTemperature: temp, scheme: scheme)
        let point = CGPoint(x: x(for: temp, in: plot), y: y(forRPM: rpm, in: plot))
        return ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 14, height: 14)
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
        }
        .position(point)
    }
}
