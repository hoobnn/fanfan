//
//  File: LaunchAtLoginManager.swift / 文件：LaunchAtLoginManager.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Launch-at-login management through ServiceManagement. / 描述：通过 ServiceManagement 管理开机登录启动。
//

import Foundation
import ServiceManagement
import Combine
import AppKit

class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var registrationStatus: String = "Unknown"

    private init() {
        updateStatus()
    }

    var isEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            setLaunchAtLogin(newValue)
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
                registrationStatus = "Enabled"
                print("LaunchAtLogin: Successfully registered")
            } else {
                try SMAppService.mainApp.unregister()
                registrationStatus = "Disabled"
                print("LaunchAtLogin: Successfully unregistered")
            }
        } catch {
            registrationStatus = "Error: \(error.localizedDescription)"
            print("LaunchAtLogin: Error - \(error)")
        }

        // Persist the service's observed state, not the optimistic request. A
        // registration error must roll both Settings @AppStorage and the popover
        // toggle back to reality.
        let actuallyEnabled = SMAppService.mainApp.status == .enabled
        UserDefaults.standard.set(actuallyEnabled, forKey: "launchAtLogin")
    }

    private func updateStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            registrationStatus = "Enabled"
        case .notRegistered:
            registrationStatus = "Not registered"
        case .requiresApproval:
            registrationStatus = "Requires approval in System Settings"
        case .notFound:
            registrationStatus = "Not found"
        @unknown default:
            registrationStatus = "Unknown"
        }
    }

    func openLoginItemsSettings() {
        // Open System Settings > General > Login Items / 中文：打开“系统设置 > 通用 > 登录项”
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
