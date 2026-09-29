//
//  File: SMCDaemonClient.swift / 文件：SMCDaemonClient.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Fast fan-write path through the root LaunchDaemon. / 描述：通过 root LaunchDaemon 执行风扇写入的快速路径。
//

import Foundation
import XPC

enum SMCDaemonClient {
    /// Mach service (and launchd label) of the SMAppService daemon. / 中文：SMAppService 守护进程的 Mach 服务名（亦即 launchd 标签）。
    nonisolated static let serviceName = "com.hoobnn.fanfan.helper"
    nonisolated static let protocolVersion = 2

    /// PING / RENEW must outlast the daemon's Ftst unlock. The daemon handles
    /// one command at a time: while a first SET waits for thermalmonitord to
    /// yield (up to `UNLOCK_TIMEOUT_MS` = 12 s) other commands queue behind it.
    /// A shorter timeout here made every renewal during that window fail, and
    /// `FanController` reacts to a failed renewal by dropping control outright
    /// — cancelling a hand-off that was in fact about to succeed.
    nonisolated static let leaseCommandTimeoutSeconds = 15

#if !DEBUG
    /// Refuse to talk to anything but our own Developer ID-signed daemon. Debug
    /// builds bundle an ad-hoc-signed daemon, so they skip this check.
    /// 中文：只与自家 Developer ID 签名的守护进程通讯；Debug 构建内置的是 ad-hoc
    /// 签名守护进程，因此跳过此校验。
    nonisolated private static let daemonRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"8FUPL8QHFH\" and identifier \"fanfan-smcd\""
#endif

    enum LeaseState: String {
        case idle
        case active
        case restoring
    }

    nonisolated static func ping() -> Bool {
        pingState() != nil
    }

    nonisolated static func pingState() -> LeaseState? {
        guard let response = send("PINGV2", timeoutSeconds: leaseCommandTimeoutSeconds) else { return nil }
        guard let parsed = parsePingResponse(response),
              parsed.version == protocolVersion else {
            return nil
        }
        return parsed.state
    }

    nonisolated static func renewControlLease() -> Bool {
        send("RENEWV2", timeoutSeconds: leaseCommandTimeoutSeconds) == "OK"
    }

    nonisolated static func setFanSpeed(fanIndex: Int, rpm: Int) -> Bool {
        send("SETV2 \(fanIndex) \(rpm)") == "OK"
    }

    nonisolated static func setFanAuto(fanIndex: Int) -> Bool {
        send("AUTOV2 \(fanIndex)") == "OK"
    }

    nonisolated static func pingVersion(from response: String) -> Int? {
        parsePingResponse(response)?.version
    }

    nonisolated private static func parsePingResponse(
        _ response: String
    ) -> (version: Int, state: LeaseState)? {
        let fields = response.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 4,
              fields[0] == "OK",
              fields[1] == "pong",
              let version = Int(fields[2]),
              let state = LeaseState(rawValue: String(fields[3])) else {
            return nil
        }
        return (version, state)
    }

    // MARK: - XPC transport / 中文：XPC 传输

    nonisolated private static let queue = DispatchQueue(label: "com.hoobnn.fanfan.helper-client")
    nonisolated private static let lock = NSLock()
    /// One long-lived connection: the daemon ties the control lease to it, so
    /// fans return to firmware the moment this process goes away.
    /// 中文：单条长连接：守护进程把控制租约绑定在这条连接上，本进程一退出风扇
    /// 就立即交还固件。
    nonisolated(unsafe) private static var connection: xpc_connection_t?

    private final class ReplyBox: @unchecked Sendable {
        var value: String?
    }

    nonisolated private static func currentConnection() -> xpc_connection_t {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let newConnection = xpc_connection_create_mach_service(
            serviceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
#if !DEBUG
        _ = xpc_connection_set_peer_code_signing_requirement(newConnection, daemonRequirement)
#endif
        xpc_connection_set_event_handler(newConnection) { event in
            // Interrupted connections reconnect on the next message; an invalid
            // one (service not registered, signature mismatch) must be rebuilt.
            // 中文：中断的连接会在下一条消息时自动重连；失效的连接（服务未注册、
            // 签名不符）必须重建。
            guard xpc_get_type(event) == XPC_TYPE_ERROR,
                  event === XPC_ERROR_CONNECTION_INVALID else { return }
            lock.lock()
            if connection === newConnection { connection = nil }
            lock.unlock()
        }
        xpc_connection_resume(newConnection)
        connection = newConnection
        return newConnection
    }

    nonisolated private static func send(_ command: String, timeoutSeconds: Int = 20) -> String? {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "line", command)

        // The timeout is a ceiling, not a delay: normal SET/AUTO replies arrive
        // in milliseconds; only the one-time Ftst unlock takes seconds.
        // 中文：超时是上限而非固定延迟：普通 SET/AUTO 毫秒级返回，只有首次 Ftst
        // 解锁需要数秒。
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        xpc_connection_send_message_with_reply(currentConnection(), message, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
               let text = xpc_dictionary_get_string(reply, "reply") {
                box.value = String(cString: text)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else { return nil }
        return box.value
    }
}
