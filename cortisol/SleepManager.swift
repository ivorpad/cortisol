import AppKit
import Foundation
import Observation

@Observable
final class SleepManager {

    // MARK: - State

    var isAwake = false
    var remainingSeconds: Int?
    var powerSource = "Unknown"
    var activeInterfaces: [String] = []
    var displaySleepMinutes: Int = 10
    var needsSetup: Bool { !sudoersInstalled }
    private var userInitiatedQuit = false
    private var didCleanup = false

    static let displaySleepOptions = [1, 2, 5, 10, 30, 0]

    // MARK: - Persistence Keys

    private static let persistedAwakeKey = "cortisolAwakeState"
    private static let persistedExpirationKey = "cortisolAwakeExpiration"

    // MARK: - Timers

    private var countdownTimer: Timer?
    private var pollTimer: Timer?

    // MARK: - Paths

    private static let markerPath = "/tmp/cortisol-awake"
    private static let sudoersPath = "/etc/sudoers.d/cortisol"
    private static let launchAgentPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/io.gradion.cortisol.watchdog.plist")

    // MARK: - Init

    init() {
        restorePersistedState()
        refreshStatus()
        installWatchdog()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.userInitiatedQuit {
                self.cleanup()
            } else if self.isAwake {
                // System-initiated termination: touch the marker so the
                // watchdog grace period is measured from NOW, not from when
                // awake mode was originally enabled.
                self.touchMarker()
            }
        }
    }

    // MARK: - State Persistence

    /// Save awake state so Cortisol can restore it after a system-initiated kill.
    /// If duration is set, persist the absolute expiration time.
    private func persistAwakeState(remainingSeconds: Int? = nil) {
        UserDefaults.standard.set(true, forKey: Self.persistedAwakeKey)
        if let remaining = remainingSeconds, remaining > 0 {
            let expiration = Date().addingTimeInterval(TimeInterval(remaining)).timeIntervalSince1970
            UserDefaults.standard.set(expiration, forKey: Self.persistedExpirationKey)
        } else {
            // Indefinite — clear any previous expiration
            UserDefaults.standard.removeObject(forKey: Self.persistedExpirationKey)
        }
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: Self.persistedAwakeKey)
        UserDefaults.standard.removeObject(forKey: Self.persistedExpirationKey)
    }

    /// On launch, if we were previously awake (persisted) AND the marker file
    /// still exists (watchdog hasn't cleaned up), re-enable immediately.
    private func restorePersistedState() {
        guard UserDefaults.standard.bool(forKey: Self.persistedAwakeKey) else { return }

        // If the watchdog already restored sleep and removed the marker,
        // don't fight it — clear persisted state and stay off.
        guard FileManager.default.fileExists(atPath: Self.markerPath) else {
            clearPersistedState()
            return
        }

        // Re-enable sleep prevention — we were killed while awake
        guard runPmset(disableSleep: true) else {
            clearPersistedState()
            return
        }

        isAwake = true
        createMarker()

        // Restore timed session if an expiration was persisted
        let expiration = UserDefaults.standard.double(forKey: Self.persistedExpirationKey)
        if expiration > 0 {
            let remaining = Int(expiration - Date().timeIntervalSince1970)
            if remaining > 0 {
                enableCountdown(seconds: remaining)
            } else {
                // Timer already expired while we were dead — disable
                disableAwake()
            }
        }
    }

    // MARK: - Computed

    var menuBarIcon: String {
        isAwake ? "bolt.fill" : "bolt.slash"
    }

    var formattedTime: String? {
        guard let seconds = remainingSeconds else { return nil }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    var compactTime: String? {
        guard let seconds = remainingSeconds else { return nil }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        }
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    func enableAwake(duration: Int? = nil) {
        guard runPmset(disableSleep: true) else { return }
        isAwake = true
        createMarker()
        persistAwakeState(remainingSeconds: duration)

        countdownTimer?.invalidate()
        countdownTimer = nil

        if let duration {
            enableCountdown(seconds: duration)
        } else {
            remainingSeconds = nil
        }
    }

    private func enableCountdown(seconds: Int) {
        remainingSeconds = seconds
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let remaining = self.remainingSeconds, remaining > 1 {
                self.remainingSeconds = remaining - 1
            } else {
                self.disableAwake()
            }
        }
    }

    func disableAwake() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        remainingSeconds = nil

        if isAwake {
            _ = runPmset(disableSleep: false)
        }
        removeMarker()
        clearPersistedState()
        refreshStatus()
    }

    func setDisplaySleep(minutes: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "displaysleep", "\(minutes)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                displaySleepMinutes = minutes
            }
        } catch {}
    }

    static func displaySleepLabel(for minutes: Int) -> String {
        if minutes == 0 { return "Never" }
        if minutes == 1 { return "1 Minute" }
        return "\(minutes) Minutes"
    }

    func refreshStatus() {
        if let output = shell("/usr/bin/pmset", ["-g"]) {
            let wasAwake = isAwake
            isAwake = output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil

            if isAwake && !wasAwake {
                createMarker()
                persistAwakeState()
            } else if !isAwake && wasAwake {
                removeMarker()
                clearPersistedState()
                countdownTimer?.invalidate()
                countdownTimer = nil
                remainingSeconds = nil
            }

            if let range = output.range(of: #"displaysleep\s+(\d+)"#, options: .regularExpression) {
                let match = output[range]
                let digits = match.split(separator: " ").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if let d = digits { displaySleepMinutes = d }
            }
        }

        if let output = shell("/usr/bin/pmset", ["-g", "batt"]) {
            if output.contains("'AC Power'") {
                powerSource = "AC Power"
            } else if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
                powerSource = "Battery \(output[range])"
            } else {
                powerSource = "Battery"
            }
        }

        activeInterfaces = getActiveInterfaces()
    }

    /// Call this only from the explicit "Quit Cortisol" menu action.
    func userQuit() {
        userInitiatedQuit = true
        cleanup()
        NSApplication.shared.terminate(nil)
    }

    func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true

        countdownTimer?.invalidate()
        pollTimer?.invalidate()
        countdownTimer = nil
        pollTimer = nil

        if isAwake {
            _ = runPmset(disableSleep: false)
            isAwake = false
        }
        removeMarker()
        clearPersistedState()
    }

    // MARK: - Sudoers Setup (one-time, with Touch ID)

    private static let sudoersVersion = "v2"

    private var sudoersInstalled: Bool {
        guard FileManager.default.fileExists(atPath: Self.sudoersPath) else { return false }
        return UserDefaults.standard.string(forKey: "sudoersVersion") == Self.sudoersVersion
    }

    /// One-time admin prompt (supports Touch ID). Installs a sudoers entry so
    /// all future pmset calls are passwordless.
    @discardableResult
    func installSudoers() -> Bool {
        if sudoersInstalled { return true }

        let username = NSUserName()
        let displaySleepEntries = Self.displaySleepOptions.map {
            "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a displaysleep \($0)"
        }
        let sudoersContent = ([
            "# Cortisol \(Self.sudoersVersion) - passwordless pmset for sleep control",
            "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0",
            "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1",
        ] + displaySleepEntries).joined(separator: "\n")

        // Write to temp, validate with visudo, then move into place
        let commands = [
            "printf '%s\\n' '\(sudoersContent)' > /tmp/cortisol-sudoers",
            "visudo -cf /tmp/cortisol-sudoers",
            "mv /tmp/cortisol-sudoers /etc/sudoers.d/cortisol",
            "chmod 440 /etc/sudoers.d/cortisol",
            "chown root:wheel /etc/sudoers.d/cortisol",
        ].joined(separator: " && ")

        let source = "do shell script \"\(commands)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if error == nil {
            UserDefaults.standard.set(Self.sudoersVersion, forKey: "sudoersVersion")
            return true
        }
        return false
    }

    // MARK: - Privileged Execution

    /// Runs pmset via sudo -n (passwordless after setup).
    /// Falls back to NSAppleScript if sudoers not yet installed.
    private func runPmset(disableSleep: Bool) -> Bool {
        let value = disableSleep ? "1" : "0"

        // Try passwordless sudo first
        if sudoersInstalled {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return true }
            } catch {}
        }

        // Sudoers not installed — do one-time setup, then retry
        if installSudoers() {
            return runPmset(disableSleep: disableSleep)
        }

        return false
    }

    // MARK: - Marker File

    private func createMarker() {
        FileManager.default.createFile(atPath: Self.markerPath, contents: nil)
    }

    /// Update the marker's mtime to now without recreating it.
    private func touchMarker() {
        let url = URL(fileURLWithPath: Self.markerPath)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private func removeMarker() {
        try? FileManager.default.removeItem(atPath: Self.markerPath)
    }

    // MARK: - Watchdog LaunchAgent

    func installWatchdog() {
        // Watchdog checks marker age: if Cortisol has been dead less than 5
        // minutes, skip — it may be relaunching after a system-initiated kill.
        // The marker mtime is refreshed on system termination so the grace
        // period is measured from when Cortisol was killed, not when awake
        // mode was first enabled.
        let inlineScript = [
            "[ ! -f /tmp/cortisol-awake ] && exit 0;",
            "pgrep -x cortisol >/dev/null 2>&1 && exit 0;",
            "pmset -g 2>/dev/null | grep -q 'SleepDisabled.*1' || { rm -f /tmp/cortisol-awake; exit 0; };",
            // Grace period: check marker mod time. If modified less than 300s ago,
            // Cortisol may be relaunching — give it time.
            "AGE=$(( $(date +%s) - $(stat -f %m /tmp/cortisol-awake) ));",
            "[ \"$AGE\" -lt 300 ] && exit 0;",
            "sudo -n pmset -a disablesleep 0 2>/dev/null && rm -f /tmp/cortisol-awake && exit 0;",
            "osascript",
            "-e 'display dialog \"Cortisol was terminated but your Mac is still prevented from sleeping.\" & return & return & \"Click Restore to re-enable normal sleep behavior.\" buttons {\"Ignore\", \"Restore Sleep\"} default button \"Restore Sleep\" with title \"Cortisol Watchdog\" with icon caution'",
            "-e 'if button returned of result is \"Restore Sleep\" then'",
            "-e 'do shell script \"pmset -a disablesleep 0\" with administrator privileges'",
            "-e 'end if';",
            "rm -f /tmp/cortisol-awake",
        ].joined(separator: " ")

        let plist: [String: Any] = [
            "Label": "io.gradion.cortisol.watchdog",
            "ProgramArguments": ["/bin/sh", "-c", inlineScript],
            "StartInterval": 120,
            "RunAtLoad": false,
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: Self.launchAgentPlist)
        }

        _ = shell("/bin/launchctl", ["unload", Self.launchAgentPlist.path])
        _ = shell("/bin/launchctl", ["load", Self.launchAgentPlist.path])
    }

    // MARK: - Shell Helpers

    @discardableResult
    private func shell(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Network

    private static let filteredPrefixes = [
        "lo", "bridge", "awdl", "llw", "ap", "gif", "stf", "p2p", "anpi",
    ]

    private func getActiveInterfaces() -> [String] {
        let portMap = getHardwarePortMap()
        guard let output = shell("/sbin/ifconfig", []) else { return [] }
        var result: [String] = []
        var currentInterface: String?

        for line in output.components(separatedBy: "\n") {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(": flags=") {
                let iface = String(line.prefix(while: { $0 != ":" }))
                if Self.filteredPrefixes.contains(where: { iface.hasPrefix($0) }) {
                    currentInterface = nil
                } else {
                    currentInterface = iface
                }
            } else if let iface = currentInterface,
                      line.contains("inet "),
                      !line.contains("127.0.0.1") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 2 {
                    let ip = parts[1]
                    let name: String
                    if let portName = portMap[iface] {
                        name = portName
                    } else if iface.hasPrefix("utun") {
                        name = "VPN"
                    } else {
                        name = iface
                    }
                    result.append("\(name) — \(ip)")
                }
            }
        }

        return result
    }

    private func getHardwarePortMap() -> [String: String] {
        guard let output = shell("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return [:] }
        var map: [String: String] = [:]
        var currentPort: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("Hardware Port: ") {
                currentPort = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let port = currentPort {
                let device = line.dropFirst("Device: ".count).trimmingCharacters(in: .whitespaces)
                map[device] = port
            }
        }

        return map
    }
}
