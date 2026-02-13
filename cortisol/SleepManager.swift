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
    var needsSetup: Bool { !sudoersInstalled }

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
            self?.cleanup()
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

        countdownTimer?.invalidate()
        countdownTimer = nil

        if let duration {
            remainingSeconds = duration
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let remaining = self.remainingSeconds, remaining > 1 {
                    self.remainingSeconds = remaining - 1
                } else {
                    self.disableAwake()
                }
            }
        } else {
            remainingSeconds = nil
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
        refreshStatus()
    }

    func refreshStatus() {
        if let output = shell("/usr/bin/pmset", ["-g"]) {
            let wasAwake = isAwake
            isAwake = output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil

            if isAwake && !wasAwake {
                createMarker()
            } else if !isAwake && wasAwake {
                removeMarker()
                countdownTimer?.invalidate()
                countdownTimer = nil
                remainingSeconds = nil
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

    func cleanup() {
        countdownTimer?.invalidate()
        pollTimer?.invalidate()
        countdownTimer = nil
        pollTimer = nil

        if isAwake {
            _ = runPmset(disableSleep: false)
            isAwake = false
        }
        removeMarker()
    }

    // MARK: - Sudoers Setup (one-time, with Touch ID)

    private var sudoersInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.sudoersPath)
    }

    /// One-time admin prompt (supports Touch ID). Installs a sudoers entry so
    /// all future pmset calls are passwordless.
    @discardableResult
    func installSudoers() -> Bool {
        if sudoersInstalled { return true }

        let username = NSUserName()
        let sudoersContent = [
            "# Cortisol - passwordless pmset for sleep control",
            "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0",
            "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1",
        ].joined(separator: "\n")

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
        return error == nil
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

    private func removeMarker() {
        try? FileManager.default.removeItem(atPath: Self.markerPath)
    }

    // MARK: - Watchdog LaunchAgent

    func installWatchdog() {
        // Watchdog tries sudo -n first (silent), falls back to dialog
        let inlineScript = [
            "[ ! -f /tmp/cortisol-awake ] && exit 0;",
            "pgrep -x cortisol >/dev/null 2>&1 && exit 0;",
            "pmset -g 2>/dev/null | grep -q 'SleepDisabled.*1' || { rm -f /tmp/cortisol-awake; exit 0; };",
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
