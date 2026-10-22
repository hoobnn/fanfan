import Foundation
import Combine

// Compile the real FanController with substitutes for hardware, XPC, and
// preferences. These regressions must never touch the machine's fan settings.
final class SystemMonitor: ObservableObject {
    @Published var numberOfFans = 2
    @Published var fanMinSpeeds = [1200, 1200]
    @Published var fanMaxSpeeds = [5779, 6241]
    @Published var fanSpeeds = [2300, 2500]
    var rawMaxTemperature: Double? = nil
    var controlCpuTemperature: Double? = nil
    var controlGpuTemperature: Double? = nil
    func temperatureIsFresh() -> Bool { false }
}

enum BatteryMonitor {
    static let shared = BatteryMonitorState()
}

struct BatteryMonitorState {
    let batteryInfo = BatteryInfo()
}

struct BatteryInfo {
    var powerWatts: Double? = nil
    var isCharging = false
}

final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func reset() { values = [:] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    func object(forKey key: String) -> Any? { values[key] }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

enum SMCDaemonClient {
    private static let lock = NSLock()
    private static var recovered = false
    private static var calls = 0
    private static var writes = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recovered = false
        calls = 0
        writes = 0
    }

    static func setFanAuto(fanIndex: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return recovered
    }

    static func recover() {
        lock.lock(); defer { lock.unlock() }
        recovered = true
    }

    static var autoCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    static var speedWrites: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    static func setFanSpeed(fanIndex: Int, rpm: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes += 1
        return true
    }

    static func renewControlLease() -> Bool { true }
}

@main
struct SystemRestoreRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor
    static func waitFor(_ message: String, timeout: TimeInterval = 1,
                        _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(description: message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    static func main() async {
        do {
            for scenario in 0..<6 {
                UserDefaults.standard.reset()
                SMCDaemonClient.reset()
                let monitor = SystemMonitor()
                var controller: FanController? = FanController(systemMonitor: monitor)
                controller!.mode = .system
                try await waitFor("initial failure was not reported") { controller!.applyDidFail }
                try check(SMCDaemonClient.autoCalls == 2, "initial restore must check both fans")

                switch scenario {
                case 0:
                    // The daemon has recovered independently; the old app never
                    // asks again, so this assertion fails before the fix.
                    SMCDaemonClient.recover()
                    try await waitFor("helper recovered, but failure banner remains", timeout: 3.5) {
                        !controller!.applyDidFail
                    }
                    try check(controller!.statusMessage == "Automatic mode restored", "success status missing")
                    try check(!controller!.isControlEnabled, "system mode must not claim manual control")
                    try check(SMCDaemonClient.speedWrites == 0, "recovery must not write a manual speed")
                    print("PASS: helper recovery clears the stale system-mode banner")
                case 1:
                    try await waitFor("failed restore was never retried", timeout: 3.5) {
                        SMCDaemonClient.autoCalls >= 4
                    }
                    // Let the completion publish before inspecting the warning.
                    try await Task.sleep(nanoseconds: 30_000_000)
                    try check(controller!.applyDidFail, "a genuine failure must remain visible")
                    try check(SMCDaemonClient.autoCalls == 4, "retries must not overlap or spin")
                    print("PASS: continuing failures stay visible and retries are spaced")
                case 2, 3:
                    let mode: ControlMode = scenario == 2 ? .manual : .automatic
                    let callsBeforeSwitch = SMCDaemonClient.autoCalls
                    controller!.setMode(mode)
                    if mode == .manual {
                        try await waitFor("manual selection was not applied") { controller!.isControlEnabled }
                    } else {
                        try await waitFor("automatic selection did not perform its initial restore") {
                            SMCDaemonClient.autoCalls == callsBeforeSwitch + 2
                        }
                    }
                    let callsAfterSwitch = SMCDaemonClient.autoCalls
                    SMCDaemonClient.recover()
                    try await Task.sleep(nanoseconds: 2_300_000_000)
                    try check(controller!.mode == mode, "an old retry changed the selected mode")
                    try check(SMCDaemonClient.autoCalls == callsAfterSwitch, "old system retry ran after switching modes")
                    if mode == .manual {
                        try check(controller!.isControlEnabled, "old retry revoked manual control")
                    }
                    print("PASS: switching to \(mode) invalidates the old system retry")
                case 4:
                    SMCDaemonClient.recover()
                    controller!.restoreAutomaticControl()
                    try await waitFor("replacement restore did not clear the failure") { !controller!.applyDidFail }
                    let callsAfterSuccess = SMCDaemonClient.autoCalls
                    try await Task.sleep(nanoseconds: 2_300_000_000)
                    try check(SMCDaemonClient.autoCalls == callsAfterSuccess, "superseded retry ran after a new restore")
                    print("PASS: a newer successful restore invalidates the scheduled retry")
                default:
                    controller!.restoreAutomaticControlSync()
                    let callsAfterTeardown = SMCDaemonClient.autoCalls
                    SMCDaemonClient.recover()
                    try await Task.sleep(nanoseconds: 2_300_000_000)
                    try check(SMCDaemonClient.autoCalls == callsAfterTeardown, "scheduled retry ran after synchronous teardown")
                    print("PASS: synchronous teardown invalidates the scheduled retry")
                }
                controller = nil
                withExtendedLifetime(monitor) {}
            }
            print("6 system-restore regressions passed")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
