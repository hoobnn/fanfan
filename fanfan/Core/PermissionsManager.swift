//
//  File: PermissionsManager.swift / 文件：PermissionsManager.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Privileged helper installation and access management. / 描述：特权辅助工具安装与访问管理。
//

import Foundation
import Security
import AppKit
import Combine

class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    
    @Published var isHelperInstalled = false
    @Published private(set) var isInstalling = false

    private var statusGeneration = 0
    private var isChecking = false
    private static let helperReadyTimeout: TimeInterval = 20
    private static let helperPollInterval: TimeInterval = 0.25
    
    private let daemonPath = "/Library/PrivilegedHelperTools/fanfan-smcd"
    private let legacyDaemonPath = "/usr/local/libexec/fanfan-smcd"
    private let daemonPlistPath = "/Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist"
    
    private init() {
        checkInstallation()
    }
    
    func checkInstallation() {
        // An install owns helper state until it completes. A popover reappearing
        // during that window must not launch an older check that can overwrite
        // the install's eventual success.
        guard !isInstalling, !isChecking else { return }
        isChecking = true
        statusGeneration &+= 1
        let generation = statusGeneration

        guard let bundledURL = Bundle.main.url(forResource: "fanfan-smcd", withExtension: nil) else {
            isChecking = false
            isHelperInstalled = false
            return
        }
        let installedPath = daemonPath
        let timeout = Self.helperReadyTimeout
        let pollInterval = Self.helperPollInterval

        // Run on background thread / 中文：在后台线程运行
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // A missing or outdated binary is a real install/upgrade request. If
            // the files already match, tolerate launchd startup throttling and
            // transient daemon restoration before declaring the helper absent.
            let daemonReady = Self.helperBinaryMatchesBundle(
                bundledURL: bundledURL,
                installedPath: installedPath
            ) && Self.waitUntil(
                timeout: timeout,
                pollInterval: pollInterval,
                check: SMCDaemonClient.ping
            )

            // Treat "files exist but launchd cannot run them" as not installed. / 中文：把“文件存在但 launchd 无法运行”的状态视为未安装。
            // A quarantined or stale helper otherwise hides the repair button / 中文：否则被 quarantine 或过期的 helper 会隐藏修复按钮，
            // while every SET/AUTO command still fails because the socket is absent. / 中文：但 socket 不存在时每次 SET/AUTO 仍会失败。
            DispatchQueue.main.async {
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

    private nonisolated static func helperBinaryMatchesBundle(
        bundledURL: URL,
        installedPath: String
    ) -> Bool {
        guard let bundled = try? Data(contentsOf: bundledURL),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: installedPath)) else {
            return false
        }
        return bundled == installed
    }
    
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        guard !isInstalling else {
            completion(false, "Helper installation already in progress")
            return
        }
        isInstalling = true
        isChecking = false
        statusGeneration &+= 1
        let installationGeneration = statusGeneration

        // 1. Locate privileged tools in the App Bundle / 中文：1. 在 App Bundle 中定位特权工具
        guard let bundledDaemonURL = Bundle.main.url(forResource: "fanfan-smcd", withExtension: nil) else {
            isInstalling = false
            completion(false, "App Bundle missing fanfan-smcd. Re-build app.")
            return
        }
        guard let bundledPlistURL = Bundle.main.url(forResource: "com.hoobnn.fanfan.smcd", withExtension: "plist") else {
            isInstalling = false
            completion(false, "App Bundle missing daemon plist. Re-build app.")
            return
        }
        
        let bundledDaemonPath = bundledDaemonURL.path
        let bundledPlistPath = bundledPlistURL.path
        
        // 2. Construct the installation script / 中文：2. 构造安装脚本
        // Bundle paths are user-controlled (the signed app can be renamed or put
        // below a directory containing quotes). Quote for the shell first, then
        // escape the complete command for the AppleScript string literal.
        // 中文：App 可被重命名或放进带引号的目录，因此 Bundle 路径属于用户可控输入；
        // 先做 shell 引用，再转义完整 AppleScript 字符串，避免提权命令注入。
        // NOTE: rm the daemon before cp so the new binary lands on a fresh inode. / 中文：注意：cp 前先 rm，让新二进制落在全新 inode 上。
        // Overwriting in place reuses the vnode and its cached code signature, so / 中文：原地覆盖会复用 vnode 及其缓存的代码签名，
        // on upgrade AMFI SIGKILLs the new content (OS_REASON_CODESIGNING). / 中文：升级时 AMFI 会以签名违规 SIGKILL 新内容。
        let qDaemonSource = Self.shellQuoted(bundledDaemonPath)
        let qPlistSource = Self.shellQuoted(bundledPlistPath)
        let qDaemon = Self.shellQuoted(daemonPath)
        let qPlist = Self.shellQuoted(daemonPlistPath)
        let qStagedDaemon = Self.shellQuoted(daemonPath + ".installing")
        let qStagedPlist = Self.shellQuoted(daemonPlistPath + ".installing")
        let qDaemonBackup = Self.shellQuoted(daemonPath + ".backup")
        let qPlistBackup = Self.shellQuoted(daemonPlistPath + ".backup")
        let qLegacyDaemon = Self.shellQuoted(legacyDaemonPath)
        let expectedPlistSHA256 = "aa58f48c612791700897b23f77894bae79a8ba5f485aba8e3ece941afe4ea148"
        var commands = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons",
            "/bin/rm -f \(qStagedDaemon) \(qStagedPlist) \(qDaemonBackup) \(qPlistBackup)",
            "/bin/cp \(qDaemonSource) \(qStagedDaemon)",
            "/bin/cp \(qPlistSource) \(qStagedPlist)",
            "/usr/sbin/chown root:wheel \(qStagedDaemon) \(qStagedPlist)",
            "/bin/chmod 755 \(qStagedDaemon)",
            "/bin/chmod 644 \(qStagedPlist)",
            "/usr/bin/shasum -a 256 \(qStagedPlist) | /usr/bin/grep -q '^\(expectedPlistSHA256) '",
            "(/usr/bin/xattr -d com.apple.quarantine \(qStagedDaemon) >/dev/null 2>&1 || true)",
            "(/usr/bin/xattr -d com.apple.quarantine \(qStagedPlist) >/dev/null 2>&1 || true)"
        ]
#if !DEBUG
        let helperRequirement = Self.shellQuoted(
            "=anchor apple generic and certificate leaf[subject.OU] = \"8FUPL8QHFH\" and identifier \"fanfan-smcd\""
        )
        commands.append(
            "/usr/bin/codesign --verify --strict --test-requirement \(helperRequirement) \(qStagedDaemon)"
        )
#endif
        commands.append(contentsOf: [
            "([ ! -f \(qDaemon) ] || /bin/cp \(qDaemon) \(qDaemonBackup))",
            "([ ! -f \(qPlist) ] || /bin/cp \(qPlist) \(qPlistBackup))",
            "(/bin/launchctl bootout system \(qPlist) >/dev/null 2>&1 || true)",
            "/bin/mv -f \(qStagedDaemon) \(qDaemon)",
            "/bin/mv -f \(qStagedPlist) \(qPlist)",
            "if ! /bin/launchctl bootstrap system \(qPlist); then /bin/rm -f \(qDaemon) \(qPlist); [ ! -f \(qDaemonBackup) ] || /bin/mv -f \(qDaemonBackup) \(qDaemon); [ ! -f \(qPlistBackup) ] || /bin/mv -f \(qPlistBackup) \(qPlist); [ ! -f \(qPlist) ] || (/bin/launchctl bootstrap system \(qPlist) >/dev/null 2>&1 || true); exit 1; fi",
            "/bin/rm -f \(qDaemonBackup) \(qPlistBackup) \(qLegacyDaemon)"
        ])
        let command = commands.joined(separator: " && ")
        let script = "do shell script \"\(Self.appleScriptEscaped(command))\" with administrator privileges"
        
        // 3. Execute / 中文：3. 执行
        DispatchQueue.global(qos: .userInitiated).async {
             var error: NSDictionary?
             if let scriptObject = NSAppleScript(source: script) {
                 _ = scriptObject.executeAndReturnError(&error)
                 
                 DispatchQueue.main.async {
                     if let error = error {
                         guard self.statusGeneration == installationGeneration else { return }
                         self.isInstalling = false
                         let msg = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                         completion(false, msg)
                     } else {
                         // launchd bootstrap returning does not guarantee that the
                         // versioned socket is accepting requests yet. Verify the
                         // actual protocol before reporting success.
                         let installedPath = self.daemonPath
                         let timeout = Self.helperReadyTimeout
                         let pollInterval = Self.helperPollInterval
                         DispatchQueue.global(qos: .userInitiated).async {
                             let helperMatches = Self.helperBinaryMatchesBundle(
                                 bundledURL: bundledDaemonURL,
                                 installedPath: installedPath
                             )
                             let daemonReady = helperMatches && Self.waitUntil(
                                 timeout: timeout,
                                 pollInterval: pollInterval,
                                 check: SMCDaemonClient.ping
                             )
                             DispatchQueue.main.async {
                                 guard self.statusGeneration == installationGeneration else { return }
                                 self.isInstalling = false
                                 self.isHelperInstalled = daemonReady
                                 completion(
                                     daemonReady,
                                     daemonReady ? nil : "Helper installed but did not become ready"
                                 )
                             }
                         }
                     }
                 }
             } else {
                 DispatchQueue.main.async {
                     guard self.statusGeneration == installationGeneration else { return }
                     self.isInstalling = false
                     completion(false, "Failed to create installation script")
                 }
             }
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
