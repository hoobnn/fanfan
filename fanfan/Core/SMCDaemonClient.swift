//
//  File: SMCDaemonClient.swift / 文件：SMCDaemonClient.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Fast fan-write path through the root LaunchDaemon. / 描述：通过 root LaunchDaemon 执行风扇写入的快速路径。
//

import Darwin
import Foundation

enum SMCDaemonClient {
    nonisolated private static let socketPath = "/var/run/fanfan-smcd.sock"
    nonisolated static let protocolVersion = 2

    enum LeaseState: String {
        case idle
        case active
        case restoring
    }

    nonisolated static func ping() -> Bool {
        pingState() != nil
    }

    nonisolated static func pingState() -> LeaseState? {
        guard let response = send("PINGV2", receiveTimeoutSeconds: 1) else { return nil }
        guard let parsed = parsePingResponse(response),
              parsed.version == protocolVersion else {
            return nil
        }
        return parsed.state
    }

    nonisolated static func renewControlLease() -> Bool {
        send("RENEWV2", receiveTimeoutSeconds: 1) == "OK"
    }

    nonisolated static func setFanSpeed(fanIndex: Int, rpm: Int) -> Bool {
        send("SETV2 \(fanIndex) \(rpm)") == "OK"
    }

    nonisolated static func setFanAuto(fanIndex: Int) -> Bool {
        if send("AUTOV2 \(fanIndex)") == "OK" {
            return true
        }
        // Upgrade fail-safe: an older helper may have left this fan manual. Its
        // legacy AUTO command is safe to use only for relinquishing control.
        return send("AUTO \(fanIndex)") == "OK"
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

    nonisolated private static func send(
        _ command: String,
        receiveTimeoutSeconds: Int = 20
    ) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // A helper restart between connect and write must be an ordinary failed
        // command, not SIGPIPE terminating the whole menu-bar app.
        // 中文：helper 若在 connect 与 write 之间重启，应只让命令失败，不能由
        // SIGPIPE 直接终止整个菜单栏应用。
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return nil
        }

        // Sending is always quick. Receiving may block for the one-time Ftst / 中文：发送总是很快；接收在首次 Ftst
        // unlock on Apple Silicon (~8 s, see fanfan-smcd.c), so the read budget / 中文：解锁时可能阻塞约 8 秒（见 fanfan-smcd.c），
        // is generous. It is a ceiling, not a delay — read() returns the instant / 中文：故读取上限放宽。这是上限而非固定延迟——
        // the daemon replies, so normal SET/AUTO calls still complete in ms. / 中文：daemon 一回应 read() 立即返回，普通 SET/AUTO 仍是毫秒级。
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        var recvTimeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathCapacity else { return nil }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { rebound in
                for (idx, byte) in pathBytes.enumerated() {
                    rebound[idx] = CChar(bitPattern: byte)
                }
                rebound[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let payload = Array((command + "\n").utf8)
        guard writeAll(fd: fd, bytes: payload) else { return nil }

        guard let response = readLine(fd: fd, limit: 256) else { return nil }
        return String(decoding: response, as: UTF8.self)
    }

    nonisolated private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    nonisolated private static func readLine(fd: Int32, limit: Int) -> [UInt8]? {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64)

        while result.count < limit {
            let remaining = min(chunk.count, limit - result.count)
            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, remaining)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }

            result.append(contentsOf: chunk.prefix(count))
            if let newline = result.firstIndex(of: 0x0A) {
                var line = Array(result[..<newline])
                if line.last == 0x0D { line.removeLast() }
                return line
            }
        }
        return nil
    }
}
