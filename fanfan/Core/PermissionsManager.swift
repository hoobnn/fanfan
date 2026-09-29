//
//  File: PermissionsManager.swift / 文件：PermissionsManager.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Privileged helper installation and access management. / 描述：特权辅助工具安装与访问管理。
//

import Foundation
import AppKit
import Combine
import ServiceManagement

class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    
    @Published var isHelperInstalled = false
    @Published private(set) var isInstalling = false
    /// Registered, but the user has not yet allowed it in System Settings. / 中文：已注册，但用户尚未在系统设置中允许。
    @Published private(set) var needsApproval = false

    private var statusGeneration = 0
    private var isChecking = false
    private var approvalTimer: Timer?
    private static let helperReadyTimeout: TimeInterval = 20
    private static let helperPollInterval: TimeInterval = 0.25

    /// Plist in `Contents/Library/LaunchDaemons`; launchd runs the daemon straight
    /// out of the app bundle, so an app update is also a daemon update.
    /// 中文：位于 `Contents/Library/LaunchDaemons` 的 plist；launchd 直接从 App
    /// Bundle 运行守护进程，App 更新即守护进程更新。
    private let service = SMAppService.daemon(plistName: "com.hoobnn.fanfan.helper.plist")
    
    private init() {
        checkInstallation()
    }
    
    func checkInstallation() {
        // An install owns helper state until it completes. A popover reappearing
        // during that window must not launch an older check that can overwrite
        // the install's eventual success.
        guard !isInstalling, !isChecking else { return }

        let status = service.status
        needsApproval = status == .requiresApproval
        if needsApproval {
            watchForApproval()
        }
        guard status == .enabled else {
            isHelperInstalled = false
            return
        }

        isChecking = true
        statusGeneration &+= 1
        let generation = statusGeneration
        let timeout = Self.helperReadyTimeout
        let pollInterval = Self.helperPollInterval

        // Tolerate launchd startup throttling and a daemon restarting after an
        // app update before declaring the helper absent.
        // 中文：容忍 launchd 启动节流以及 App 更新后守护进程的重启，再判定助手缺失。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let daemonReady = Self.waitUntil(
                timeout: timeout,
                pollInterval: pollInterval,
                check: SMCDaemonClient.ping
            )
            DispatchQueue.main.async {
                guard let self else { return }
                guard Self.shouldApplyStatusResult(
                    generation: generation,
                    currentGeneration: self.statusGeneration,
                    isInstalling: self.isInstalling
                ) else { return }
                self.isChecking = false
                self.isHelperInstalled = daemonReady
            }
        }
    }
    
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        guard !isInstalling else {
            completion(false, NSLocalizedString("popover.install_in_progress", comment: ""))
            return
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            watchForApproval()
            completion(false, nil)
            return
        }

        isInstalling = true
        isChecking = false
        statusGeneration &+= 1
        let installationGeneration = statusGeneration

        Task { @MainActor in
            do {
                // Re-registering an enabled daemon that stopped answering
                // restarts it.
                // 中文：对已启用但无响应的守护进程重新注册会让它重启。
                if self.service.status == .enabled {
                    try? await self.service.unregister()
                }
                try self.service.register()
            } catch {
                // Registration that still needs the user's approval throws too.
                // 中文：仍需用户批准的注册同样会抛错。
                if self.service.status != .requiresApproval {
                    guard self.statusGeneration == installationGeneration else { return }
                    self.isInstalling = false
                    completion(false, error.localizedDescription)
                    return
                }
            }

            if self.service.status == .requiresApproval {
                guard self.statusGeneration == installationGeneration else { return }
                self.isInstalling = false
                self.needsApproval = true
                SMAppService.openSystemSettingsLoginItems()
                self.watchForApproval()
                completion(false, nil)
                return
            }

            // `register()` returning does not mean the Mach service is answering
            // yet. Verify the actual protocol before reporting success.
            // 中文：`register()` 返回不代表 Mach 服务已可应答，先验证真实协议再报告成功。
            let timeout = Self.helperReadyTimeout
            let pollInterval = Self.helperPollInterval
            DispatchQueue.global(qos: .userInitiated).async {
                let daemonReady = Self.waitUntil(
                    timeout: timeout,
                    pollInterval: pollInterval,
                    check: SMCDaemonClient.ping
                )
                DispatchQueue.main.async {
                    guard self.statusGeneration == installationGeneration else { return }
                    self.isInstalling = false
                    self.needsApproval = false
                    self.isHelperInstalled = daemonReady
                    completion(
                        daemonReady,
                        daemonReady ? nil : NSLocalizedString("popover.helper_not_ready", comment: "")
                    )
                }
            }
        }
    }

    /// Notice the approval in System Settings without the user having to reopen
    /// the popover.
    /// 中文：无需用户重新打开弹窗即可感知系统设置中的批准。
    private func watchForApproval() {
        guard approvalTimer == nil else { return }
        let startedAt = Date()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let status = self.service.status
            let gaveUp = Date().timeIntervalSince(startedAt) > 600
            guard status != .requiresApproval || gaveUp else { return }
            timer.invalidate()
            self.approvalTimer = nil
            self.checkInstallation()
        }
    }

    nonisolated static func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        check: () -> Bool
    ) -> Bool {
        guard timeout > 0, pollInterval > 0 else { return check() }

        let deadline = now() + timeout
        while true {
            if check() { return true }

            let remaining = deadline - now()
            if remaining <= 0 { return false }
            sleep(min(pollInterval, remaining))
        }
    }

    nonisolated static func shouldApplyStatusResult(
        generation: Int,
        currentGeneration: Int,
        isInstalling: Bool
    ) -> Bool {
        generation == currentGeneration && !isInstalling
    }
}
