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
    
    private let daemonPath = "/usr/local/libexec/fanfan-smcd"
    private let daemonPlistPath = "/Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist"
    
    private init() {
        checkInstallation()
    }
    
    func checkInstallation() {
        // Run on background thread / 中文：在后台线程运行
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let daemonReady = SMCDaemonClient.ping()

            // Treat "files exist but launchd cannot run them" as not installed. / 中文：把“文件存在但 launchd 无法运行”的状态视为未安装。
            // A quarantined or stale helper otherwise hides the repair button / 中文：否则被 quarantine 或过期的 helper 会隐藏修复按钮，
            // while every SET/AUTO command still fails because the socket is absent. / 中文：但 socket 不存在时每次 SET/AUTO 仍会失败。
            DispatchQueue.main.async {
                self.isHelperInstalled = daemonReady
            }
        }
    }
    
    private func verifySudoAccess() -> Bool {
        return SMCDaemonClient.ping()
    }
    
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        // 1. Locate privileged tools in the App Bundle / 中文：1. 在 App Bundle 中定位特权工具
        guard let bundledDaemonURL = Bundle.main.url(forResource: "fanfan-smcd", withExtension: nil) else {
            completion(false, "App Bundle missing fanfan-smcd. Re-build app.")
            return
        }
        guard let bundledPlistURL = Bundle.main.url(forResource: "com.hoobnn.fanfan.smcd", withExtension: "plist") else {
            completion(false, "App Bundle missing daemon plist. Re-build app.")
            return
        }
        
        let bundledDaemonPath = bundledDaemonURL.path
        let bundledPlistPath = bundledPlistURL.path
        
        // 2. Construct the installation script / 中文：2. 构造安装脚本
        // We handle everything in one sudo shell script for atomicity / 中文：通过一个 sudo shell 脚本完成全部操作以保证原子性
        // NOTE: rm the daemon before cp so the new binary lands on a fresh inode. / 中文：注意：cp 前先 rm，让新二进制落在全新 inode 上。
        // Overwriting in place reuses the vnode and its cached code signature, so / 中文：原地覆盖会复用 vnode 及其缓存的代码签名，
        // on upgrade AMFI SIGKILLs the new content (OS_REASON_CODESIGNING). / 中文：升级时 AMFI 会以签名违规 SIGKILL 新内容。
        let script = """
        do shell script "mkdir -p /usr/local/libexec /Library/LaunchDaemons && rm -f '\(daemonPath)' && cp '\(bundledDaemonPath)' '\(daemonPath)' && chown root:wheel '\(daemonPath)' && chmod 755 '\(daemonPath)' && cp -f '\(bundledPlistPath)' '\(daemonPlistPath)' && chown root:wheel '\(daemonPlistPath)' && chmod 644 '\(daemonPlistPath)' && (/usr/bin/xattr -d com.apple.quarantine '\(daemonPath)' >/dev/null 2>&1 || true) && (/usr/bin/xattr -d com.apple.quarantine '\(daemonPlistPath)' >/dev/null 2>&1 || true) && (/bin/launchctl bootout system '\(daemonPlistPath)' >/dev/null 2>&1 || true) && /bin/launchctl bootstrap system '\(daemonPlistPath)' && /bin/launchctl kickstart -k system/com.hoobnn.fanfan.smcd" with administrator privileges
        """
        
        // 3. Execute / 中文：3. 执行
        DispatchQueue.global(qos: .userInitiated).async {
             var error: NSDictionary?
             if let scriptObject = NSAppleScript(source: script) {
                 _ = scriptObject.executeAndReturnError(&error)
                 
                 DispatchQueue.main.async {
                     if let error = error {
                         let msg = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                         completion(false, msg)
                     } else {
                         self.checkInstallation() // Refresh state
                         completion(true, nil)
                     }
                 }
             } else {
                 DispatchQueue.main.async {
                     completion(false, "Failed to create installation script")
                 }
             }
        }
    }
}
