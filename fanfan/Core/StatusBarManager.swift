//
//  File: StatusBarManager.swift / 文件：StatusBarManager.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Animated status bar icon and dynamic display text. / 描述：动画状态栏图标和动态显示文本。
//

import AppKit
import SwiftUI
import Combine
import QuartzCore

struct StatusBarAnimationSettings {
    /// The menu-bar icon is 16 pt and turns slowly (≤120°/s). At that size / 中文：菜单栏图标只有 16 pt 且转速 ≤120°/s。在该尺寸下，
    /// 15 fps is visually indistinguishable from 30 fps for a decorative / 中文：装饰性旋转动画 15 fps 和 30 fps 几乎不可分辨；
    /// spinner — but it halves the rate of `-[NSStatusBarButton setImage:]`, / 中文：但它能把 `-[NSStatusBarButton setImage:]` 的频率减半，
    /// each of which forces a full button-cell + autolayout + XPC redraw. / 中文：而每次 setImage 都会触发按钮单元 + 自动布局 + XPC 重绘。
    static let iconFramesPerSecond: Double = 15
    static let minimumFramesPerSecond: Double = 12
    static let iconCacheCount: Int = 120

    /// The icon animates at a fixed calm rate regardless of display refresh. / 中文：The 图标 animates at a fixed calm rate regardless of display refresh.
    static func effectiveFramesPerSecond(for _: Double?) -> Double {
        iconFramesPerSecond
    }

    static func degreesPerSecond(fanSpeed: Int, referenceMaxRPM: Int) -> Double {
        guard fanSpeed > 0 else { return 0 }
        let speedFactor = min(1.0, max(0.0, Double(fanSpeed) / Double(max(referenceMaxRPM, 1))))
        return 20.0 + speedFactor * 100.0
    }
}

class StatusBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var displayLink: CADisplayLink?
    private var fallbackAnimationTimer: Timer?
    private var currentRotation: CGFloat = 0
    private var targetDegreesPerSecond: Double = 0
    private var lastFrameTimestamp: CFTimeInterval?
    private var isAnimationRunning = false
    /// While the popover is open, the status bar icon stops spinning so the / 中文：While the 弹出窗口 is open, the 状态 bar 图标 stops spinning so the
    /// menu bar redraw doesn't compete with the popover's own animations — / 中文：menu bar redraw doesn't compete with the 弹出窗口's own animations —
    /// driving both off the main thread at 120 Hz drops frames on open. / 中文：driving both off the main th读取 at 120 Hz drops frames on open.
    private var suppressIconAnimation = false
    /// Latest sampled RPM per fan (from SMC); animation uses the maximum. / 中文：Latest 采样d RPM per 风扇 (from SMC); animation uses the maximum.
    private var cachedFanSpeeds: [Int] = []
    private var cachedFanMinRPM: [Int] = []
    private var cachedFanMaxRPM: [Int] = []
    private var displayFanSpeedMax: Int = 0
    private var currentTemperature: Double?
    private var currentPowerWatts: Double?
    private var displayMode: String = "temperature"

    // Pre-rendered icon cache. The fixed 30 fps animation does not need a / 中文：Pre-rendered 图标 缓存. The fixed 30 fps animation does not need a
    // display-refresh-sized cache. / 中文：display-refresh-sized 缓存.
    private var iconCache: [Int: NSImage] = [:]
    private let iconCacheCount: Int = StatusBarAnimationSettings.iconCacheCount
    /// Slot index currently visible on the menu bar; `-1` means none yet. / 中文：当前菜单栏上可见的槽位索引；`-1` 表示尚未绘制。
    /// Used to dedupe `-[NSStatusBarButton setImage:]` per animation frame. / 中文：用于在每帧动画中去重 `-[NSStatusBarButton setImage:]`。
    private var lastDrawnIconSlot: Int = -1

    func setupStatusBar() {
        DispatchQueue.main.async { [weak self] in
            self?.preRenderIconCache()
            self?.createStatusItem()
            self?.observeApplicationActivation()
        }
    }

    /// Close the popover when the user clicks outside the app — covers other / 中文：当用户点击应用外部（桌面或其他应用窗口）时关闭弹出窗口；
    /// apps and the desktop, which `.transient` alone misses once the popover / 中文：因为 `togglePopover` 调用了 `makeKey()` 使弹出窗口成为 key window 后，
    /// becomes the key window via `makeKey()` in `togglePopover`. / 中文：单独依赖 `.transient` 行为已无法覆盖这些场景。
    private func observeApplicationActivation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard popover?.isShown == true else { return }
        popover?.performClose(nil)
    }

    /// Pre-render fan icons at common rotation angles for animation cache / 中文：Pre-render 风扇 图标s at common rotation angles for animation 缓存
    private func preRenderIconCache() {
        for i in 0..<iconCacheCount {
            let angle = CGFloat(i) * (360.0 / CGFloat(iconCacheCount))
            iconCache[i] = createFanIcon(size: 16, rotation: angle)
        }
    }

    /// Get cached icon for a given rotation angle (quantized to cache slots) / 中文：Get 缓存d 图标 for a given rotation angle (quantized to 缓存 slots)
    private func cachedIcon(for rotation: CGFloat) -> NSImage {
        let normalized = rotation.truncatingRemainder(dividingBy: 360)
        let slot = Int((normalized / 360.0 * CGFloat(iconCacheCount)).rounded()) % iconCacheCount
        return iconCache[slot] ?? createFanIcon(size: 16, rotation: rotation)
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else {
            return
        }
        
        // Set initial icon / 中文：Set initial 图标
        let image = createFanIcon(size: 16, rotation: 0)
        button.image = image
        // Template images let WindowServer cache and tint the icon centrally / 中文：模板图像让 WindowServer 集中缓存并着色图标，
        // (auto-inverts for menu-bar appearance), so each `setImage` is much / 中文：（按菜单栏外观自动反色），这样每次 `setImage` 的下游开销
        // cheaper downstream than re-blitting a custom RGBA bitmap. The icon / 中文：远低于重新位图绘制 RGBA 像素的成本。该图标本就是
        // is already a monochrome silhouette, so template mode renders correctly. / 中文：单色剪影，使用模板模式渲染正确。
        button.image?.isTemplate = true
        button.title = "fanfan 85°"  // Initial temperature display with app name to ensure visibility
        button.imagePosition = .imageLeft
        button.toolTip = "fanfan"
        
        // Handle button click / 中文：处理按钮点击。
        button.action = #selector(togglePopover)
        button.target = self
        
        // Create popover / 中文：Create 弹出窗口
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.contentSize = NSSize(width: 340, height: 580)
        popover?.delegate = self
    }
    
    /// Number of fan blades — matches `FanBladeView` so the menu bar icon and / 中文：Number of 风扇 blades — matches `风扇BladeView` so the menu bar 图标 and
    /// the popover fan read as the same object. / 中文：the 弹出窗口 风扇 读取 as the same object.
    private static let iconBladeCount = 5

    private func createFanIcon(size: CGFloat, rotation: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            // Flip into a SwiftUI-style y-down space. With this in place the / 中文：翻转到 SwiftUI 风格的 y 轴向下坐标空间；这样
            // ported blade geometry and the rotation direction below match / 中文：移植过来的叶片几何和下面的旋转方向就能匹配。
            // `FanBladeView` exactly — both fans spin clockwise, together. / 中文：`风扇BladeView` exactly — both 风扇s spin clockwise, together.
            ctx.translateBy(x: 0, y: size)
            ctx.scaleBy(x: 1, y: -1)

            // Rotate the whole fan about its center. / 中文：Rotate the whole 风扇 about its center.
            ctx.translateBy(x: size / 2, y: size / 2)
            ctx.rotate(by: rotation * .pi / 180)
            ctx.translateBy(x: -size / 2, y: -size / 2)

            let r = size / 2
            let center = NSPoint(x: r, y: r)

            NSColor.black.setFill()

            // Blades — same swept-petal shape as `FanBladeView.BladeShape`, / 中文：Blades — same swept-petal shape as `风扇BladeView.BladeShape`,
            // arranged on the same 360/bladeCount spacing. / 中文：按照相同的 360/bladeCount 间距排列。
            let step = 2 * CGFloat.pi / CGFloat(Self.iconBladeCount)
            for i in 0..<Self.iconBladeCount {
                Self.bladePath(center: center, radius: r, rotation: CGFloat(i) * step).fill()
            }

            // Hub. / 中文：轮毂。
            let hub = size * 0.30
            NSBezierPath(ovalIn: NSRect(x: center.x - hub / 2,
                                        y: center.y - hub / 2,
                                        width: hub,
                                        height: hub)).fill()

            return true
        }

        image.isTemplate = true
        return image
    }

    /// One swept-blade petal, ported from `FanBladeView.BladeShape`. Unit / 中文：One swept-blade petal, ported from `风扇BladeView.BladeShape`. Unit
    /// coordinates point "up" (negative y in the flipped context); `rotation` / 中文：坐标指向“上方”（在翻转坐标系中为负 y）；`rotation`
    /// places the blade around the hub. / 中文：负责把叶片放置到轮毂周围。
    private static func bladePath(center: NSPoint, radius r: CGFloat, rotation: CGFloat) -> NSBezierPath {
        let c = cos(rotation), s = sin(rotation)
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: center.x + (x * c - y * s) * r,
                    y: center.y + (x * s + y * c) * r)
        }

        let p = NSBezierPath()
        p.move(to: P(-0.025, -0.13))
        p.curve(to: P( 0.16, -0.54), controlPoint1: P( 0.10, -0.16), controlPoint2: P( 0.20, -0.34))
        p.curve(to: P(-0.05, -0.62), controlPoint1: P( 0.10, -0.64), controlPoint2: P( 0.00, -0.66))
        p.curve(to: P(-0.025, -0.13), controlPoint1: P(-0.08, -0.50), controlPoint2: P(-0.08, -0.32))
        p.close()
        return p
    }
    
    /// Store a factory for the popover's SwiftUI tree instead of materializing / 中文：存储 弹出窗口 SwiftUI 视图树的工厂，而不是立即实例化，
    /// it eagerly. The tree contains `TimelineView(.animation)` (`FanBladeView`) / 中文：因为该视图树包含 `TimelineView(.animation)`（`FanBladeView`），
    /// which would otherwise tick at display-refresh rate as long as the / 中文：只要 `NSHostingController` 还活着，它就会按显示器刷新率持续 tick，
    /// `NSHostingController` is alive — burning ~40% CPU with the popover / 中文：在 弹出窗口 仅是视觉上关闭的情况下也是如此，
    /// closed. We mount the controller in `togglePopover` and tear it down in / 中文：曾经导致约 40% 主线程 CPU 占用。这里改为在 `togglePopover` 中挂载，
    /// `popoverDidClose` so the SwiftUI graph only exists while visible. / 中文：在 `popoverDidClose` 中拆除，使 SwiftUI 视图树仅在可见期间存在。
    func setPopoverContent<Content: View>(_ builder: @escaping () -> Content) {
        DispatchQueue.main.async { [weak self] in
            self?.popoverContentMounter = { [weak self] in
                guard let popover = self?.popover,
                      popover.contentViewController == nil else { return }
                popover.contentViewController = NSHostingController(rootView: builder())
            }
        }
    }

    private var popoverContentMounter: (() -> Void)?
    
    func updateIcon(fanSpeeds: [Int], fanMinSpeeds: [Int], fanMaxSpeeds: [Int], temperature: Double?, powerWatts: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.shouldApplyIconUpdate(
                fanSpeeds: fanSpeeds,
                fanMinSpeeds: fanMinSpeeds,
                fanMaxSpeeds: fanMaxSpeeds,
                temperature: temperature,
                powerWatts: powerWatts
            ) else {
                return
            }

            self.cachedFanSpeeds = fanSpeeds
            self.cachedFanMinRPM = fanMinSpeeds
            self.cachedFanMaxRPM = fanMaxSpeeds
            self.displayFanSpeedMax = fanSpeeds.max() ?? 0
            self.currentTemperature = temperature
            self.currentPowerWatts = powerWatts
            self.updateAnimationSpeed()
            self.updateDisplay()
        }
    }

    private func shouldApplyIconUpdate(
        fanSpeeds: [Int],
        fanMinSpeeds: [Int],
        fanMaxSpeeds: [Int],
        temperature: Double?,
        powerWatts: Double?
    ) -> Bool {
        cachedFanSpeeds != fanSpeeds ||
        cachedFanMinRPM != fanMinSpeeds ||
        cachedFanMaxRPM != fanMaxSpeeds ||
        !Self.nearlyEqual(currentTemperature, temperature, tolerance: 0.1) ||
        !Self.nearlyEqual(currentPowerWatts, powerWatts, tolerance: 0.05)
    }

    private static func nearlyEqual(_ lhs: Double?, _ rhs: Double?, tolerance: Double) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            return abs(lhs - rhs) <= tolerance
        default:
            return false
        }
    }

    /// Mean utilization in \([0,100]\) across fans using each fan's SMC min/max span. / 中文：Mean utilization in \([0,100]\) across 风扇s using each 风扇's SMC min/max span.
    private func averageFanLoadPercent() -> Int {
        guard !cachedFanSpeeds.isEmpty else { return 0 }
        var sum = 0.0
        var count = 0
        for i in 0..<cachedFanSpeeds.count {
            let mn = i < cachedFanMinRPM.count ? cachedFanMinRPM[i] : cachedFanMinRPM.first ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
            guard i < cachedFanMaxRPM.count else { continue }
            let mx = cachedFanMaxRPM[i]
            guard mx > mn else { continue }
            let p = Double(cachedFanSpeeds[i] - mn) / Double(mx - mn)
            sum += min(1.0, max(0.0, p))
            count += 1
        }
        guard count > 0 else {
            let ref = cachedFanMaxRPM.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
            guard ref > 0 else { return 0 }
            return min(100, max(0, Int(round(Double(displayFanSpeedMax) / Double(ref) * 100))))
        }
        return Int(min(100, max(0, round(sum / Double(count) * 100))))
    }

    private func animationReferenceMaxRPM() -> Int {
        max(cachedFanMaxRPM.max() ?? 0, FanRPMBounds.fallbackMaxWhenSMCUnreadable)
    }
    
    func setDisplayMode(_ mode: String) {
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            if let button = self?.statusItem?.button {
                if mode == "none" {
                    button.title = ""
                    button.imagePosition = .imageOnly
                } else {
                    button.imagePosition = .imageLeft
                }
            }
            self?.updateDisplay()
        }
    }
    
    /// Title text currently on the status button — dedupes `attributedTitle` / 中文：状态按钮当前显示的标题文本——用于去重 `attributedTitle`
    /// assignments. E.g. in temperature mode a battery-power jitter passes / 中文：赋值。例如温度模式下电池功率抖动会通过
    /// `shouldApplyIconUpdate` but renders the exact same string; setting the / 中文：`shouldApplyIconUpdate`，但渲染出的字符串完全相同；
    /// title anyway forces a status-item relayout for nothing. / 中文：重设标题只会白白触发一次状态栏重排。
    private var lastDisplayedText: String?

    private func updateDisplay() {
        guard let button = statusItem?.button else { return }

        // Update button title based on display mode / 中文：Update button title based on display 模式
        let text = getDisplayText()
        guard text != lastDisplayedText else { return }
        lastDisplayedText = text
        // Use a compact font for the title to reduce visual length / 中文：标题使用紧凑字体以减少视觉长度。
        if text.isEmpty {
            button.title = ""
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            ]
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
    }
    
    private func getDisplayText() -> String {
        switch displayMode {
        case "none":
            return ""
        case "temperature":
            if let temp = currentTemperature {
                let digits = String(format: "%.0f", temp)
                let padded = digits.count < 2
                    ? String(repeating: "\u{2007}", count: 2 - digits.count) + digits
                    : digits
                return padded + "°"
            }
            return "\u{2007}--°"
        case "power":
            // Prefer showing battery power in Watts when available / 中文：Prefer showing 电池 功率 in Watts when available
            if let pw = currentPowerWatts {
                return String(format: "%.1fW", pw)
            }
            let percentage = averageFanLoadPercent()
            return "\(percentage)%"
        case "fanSpeedPercentage":
            let percentage = averageFanLoadPercent()
            return "\(percentage)%"
        default:
            if let temp = currentTemperature {
                let digits = String(format: "%.0f", temp)
                let padded = digits.count < 2
                    ? String(repeating: "\u{2007}", count: 2 - digits.count) + digits
                    : digits
                return padded + "°"
            }
            return "\u{2007}--°"
        }
    }
    
    private func updateAnimationSpeed() {
        guard displayFanSpeedMax > 0 else {
            stopAnimation()
            statusItem?.button?.image = cachedIcon(for: 0)
            return
        }

        targetDegreesPerSecond = StatusBarAnimationSettings.degreesPerSecond(
            fanSpeed: displayFanSpeedMax,
            referenceMaxRPM: animationReferenceMaxRPM()
        )
        startAnimationIfNeeded()
    }

    private func startAnimationIfNeeded() {
        guard !suppressIconAnimation else { return }
        guard !isAnimationRunning else { return }

        lastFrameTimestamp = CACurrentMediaTime()

        if startDisplayLink() {
            isAnimationRunning = true
            return
        }

        startFallbackTimer()
        isAnimationRunning = true
    }

    private func startDisplayLink() -> Bool {
        guard let screen = NSScreen.main else {
            return false
        }

        let link = screen.displayLink(target: self, selector: #selector(displayLinkDidRefresh(_:)))
        let framesPerSecond = StatusBarAnimationSettings.effectiveFramesPerSecond(
            for: Double(screen.maximumFramesPerSecond)
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(StatusBarAnimationSettings.minimumFramesPerSecond),
            maximum: Float(framesPerSecond),
            preferred: Float(framesPerSecond)
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        return true
    }

    private func startFallbackTimer() {
        let framesPerSecond = StatusBarAnimationSettings.effectiveFramesPerSecond(
            for: NSScreen.main.map { Double($0.maximumFramesPerSecond) }
        )
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / framesPerSecond, repeats: true) { [weak self] _ in
            self?.advanceAnimationFrame()
        }
        // Rotation integrates real elapsed time, so coalesced wakeups shift / 中文：旋转按真实流逝时间积分，合并唤醒只会
        // frame timing without changing the spin rate. / 中文：移动帧时刻，不会改变转速。
        timer.tolerance = (1.0 / framesPerSecond) * 0.2
        RunLoop.current.add(timer, forMode: .common)
        fallbackAnimationTimer = timer
    }

    @objc private func displayLinkDidRefresh(_ link: CADisplayLink) {
        advanceAnimationFrame(timestamp: link.timestamp)
    }

    private func advanceAnimationFrame() {
        advanceAnimationFrame(timestamp: CACurrentMediaTime())
    }

    private func advanceAnimationFrame(timestamp: CFTimeInterval) {
        guard targetDegreesPerSecond > 0,
              let button = statusItem?.button else { return }

        let elapsed = min(0.1, timestamp - (lastFrameTimestamp ?? timestamp))
        lastFrameTimestamp = timestamp

        currentRotation = (currentRotation + CGFloat(targetDegreesPerSecond * elapsed))
            .truncatingRemainder(dividingBy: 360)

        // Skip the assignment when the quantized icon slot is unchanged. / 中文：当量化后的图标槽位未变时跳过赋值。
        // Each `-[NSStatusBarButton setImage:]` re-evaluates the entire button / 中文：每次 `-[NSStatusBarButton setImage:]` 都会重新计算整个按钮单元
        // cell (attributed title attributes, autolayout, …) regardless of / 中文：（属性化标题属性、自动布局等），与图像是否真正变化无关，
        // whether the image actually changed — at 30 fps with 120 slots and / 中文：在 30 fps、120 个槽位、低/中转速下，
        // low/medium fan speeds most frames hit the same slot. / 中文：大多数帧落在同一个槽位上。
        let slot = iconCacheSlot(for: currentRotation)
        guard slot != lastDrawnIconSlot else { return }
        lastDrawnIconSlot = slot
        button.image = iconCache[slot] ?? cachedIcon(for: currentRotation)
    }

    private func iconCacheSlot(for rotation: CGFloat) -> Int {
        let normalized = rotation.truncatingRemainder(dividingBy: 360)
        return Int((normalized / 360.0 * CGFloat(iconCacheCount)).rounded()) % iconCacheCount
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackAnimationTimer?.invalidate()
        fallbackAnimationTimer = nil
        isAnimationRunning = false
        targetDegreesPerSecond = 0
        lastFrameTimestamp = nil
        lastDrawnIconSlot = -1
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button,
              let popover = popover else {
            return
        }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverContentMounter?()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    func closePopover() {
        popover?.performClose(nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopAnimation()
    }
}

// MARK: - NSPopoverDelegate / 中文：NSPopoverDelegate 分区
//
// Freeze the menu bar icon while the popover is on screen. The popover's / 中文：Freeze the menu bar 图标 while the 弹出窗口 is on screen. The 弹出窗口's
// content (including its own animated `FanBladeView`) is heavy enough that / 中文：content (including its own animated `风扇BladeView`) is heavy enough that
// also pumping per-frame icon redraws through the main thread visibly drops / 中文：also pumping per-frame 图标 redraws through the main th读取 visibly drops
// frames during the open transition. / 中文：打开过渡期间的帧。
extension StatusBarManager: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        suppressIconAnimation = true
        stopAnimation()
    }

    func popoverDidClose(_ notification: Notification) {
        suppressIconAnimation = false
        // Tear down the hosted SwiftUI tree so its `TimelineView(.animation)` / 中文：拆除挂载的 SwiftUI 视图树，使其内部的 `TimelineView(.animation)`
        // stops ticking at display refresh while hidden. The next show re-builds / 中文：在隐藏期间不再按显示器刷新率 tick。下次显示时通过工厂闭包
        // it via the stored factory. / 中文：重新构建。
        popover?.contentViewController = nil
        // Resume spinning at whatever speed the latest sample implies. / 中文：Resume spinning at whatever speed the latest 采样 implies.
        updateAnimationSpeed()
    }
}
