//
//  File: AppUpdater.swift / 文件：AppUpdater.swift
//  Target: fanfan / 目标：fanfan
//
//  Description: In-app updates through Sparkle. / 描述：基于 Sparkle 的应用内更新。
//

import AppKit
import Combine
import Sparkle

/// Owns Sparkle's standard updater. The feed URL, public EdDSA key and the
/// default for automatic checks live in `Info.plist`.
/// 中文：持有 Sparkle 标准更新器。feed 地址、EdDSA 公钥和自动检查的默认值都在 `Info.plist` 里。
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController
    private let userDriverDelegate: MenuBarUserDriverDelegate

    /// Debug builds use another bundle ID but the same version numbers and
    /// feed, so a check could offer to "update" them to the release build.
    /// They keep the controls but never start the updater.
    /// 中文：Debug 构建的 bundle ID 不同、版本号和 feed 却相同，检查更新会提示把它
    /// "更新"成正式版。Debug 构建保留界面控件，但不启动更新器。
    #if DEBUG
    private static let startsUpdater = false
    #else
    private static let startsUpdater = true
    #endif

    override init() {
        let userDriverDelegate = MenuBarUserDriverDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: Self.startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
        self.userDriverDelegate = userDriverDelegate
        self.controller = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        super.init()

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// fanfan lives in the menu bar (`.accessory`), so Sparkle's windows would
/// otherwise open behind whatever app is in front, with no Dock icon to find
/// them by. Promote and activate the app first; `AppDelegate` drops back to
/// menu-bar mode when the last window closes.
/// 中文：fanfan 常驻菜单栏（`.accessory`），Sparkle 的窗口否则会开在前台应用后面，
/// 也没有 Dock 图标可找。先提升并激活应用；最后一个窗口关闭后由 `AppDelegate` 退回菜单栏模式。
private final class MenuBarUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        bringAppToFront()
    }

    func standardUserDriverWillShowModalAlert() {
        bringAppToFront()
    }

    private func bringAppToFront() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
