import AppKit
import Foundation
import IOKit.ps

/// Keeps the Mac awake with the lid closed, which power assertions can't do:
/// macOS always sleeps on lid close unless `pmset disablesleep` is set, and
/// that needs root. A one-time setup installs a sudoers rule that allows only
/// `pmset -a disablesleep 0|1`, so Tally can toggle it without a password.
enum LidSleep {
    static let sudoersPath = "/etc/sudoers.d/tally-pmset"
    private static let ownedKey = "lidSleepDisabledByTally"

    static var isSetUp: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Asks for an administrator password and installs the sudoers rule.
    @MainActor
    static func setUp() -> String? {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let script = """
        f=$(mktemp) && printf '%s\\n' '\(rule)' > "$f" && /usr/sbin/visudo -cf "$f" >/dev/null && \
        /usr/bin/install -m 0440 -o root -g wheel "$f" \(sudoersPath); r=$?; rm -f "$f"; exit $r
        """
        return runAsAdmin(script)
    }

    @MainActor
    static func remove() -> String? {
        setSleepDisabledSync(false)
        return runAsAdmin("/bin/rm -f \(sudoersPath)")
    }

    @MainActor
    private static func runAsAdmin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Tally needs permission to keep your Mac awake with the lid closed while Claude is working.\""
        var error: NSDictionary?
        NSApp.activate()
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return error[NSAppleScript.errorMessage] as? String ?? "Setup failed."
    }

    /// Whether Tally currently has lid-closed sleep turned off.
    static var isOwned: Bool { UserDefaults.standard.bool(forKey: ownedKey) }

    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) async -> Bool {
        guard isSetUp else { return false }
        let ok = await Processes.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
        if ok { UserDefaults.standard.set(disabled, forKey: ownedKey) }
        return ok
    }

    /// Blocking variant for app termination, when there's no time for async work.
    static func setSleepDisabledSync(_ disabled: Bool) {
        guard isSetUp else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { UserDefaults.standard.set(disabled, forKey: ownedKey) }
        }
    }

    /// Battery percentage when running on battery, nil on AC power.
    static var batteryLevelOnBattery: Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let level = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            return level
        }
        return nil
    }
}
