import AppKit
import Darwin
import Foundation

enum Processes {
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Reads another process's environment via KERN_PROCARGS2 (same user only).
    static func environment(of pid: Int32) -> [String: String] {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0 else { return [:] }

        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [:] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }  // executable path
        while i < size, buffer[i] == 0 { i += 1 }  // padding
        var skipped: Int32 = 0
        while i < size, skipped < argc {           // argv
            while i < size, buffer[i] != 0 { i += 1 }
            i += 1
            skipped += 1
        }

        var env: [String: String] = [:]
        while i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            if i == start { break }
            let entry = String(decoding: buffer[start..<i], as: UTF8.self)
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            i += 1
        }
        return env
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
                return
            }
            // Drain output before waiting so a chatty command can't fill the
            // pipe and block forever.
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// Drives Claude Code sessions that run inside Rex terminal blocks.
enum Rex {
    static let bundleID = "com.superlogical.rex"

    static let executable: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
            "/opt/homebrew/bin/rex",
            "/usr/local/bin/rex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { executable != nil }

    static func focus(block: String) async {
        guard let rex = executable else { return }
        await Processes.run(rex, ["focus", block])
        activateApp()
    }

    static func send(_ text: String, to block: String) async -> Bool {
        guard let rex = executable else { return false }
        let typed = await Processes.run(rex, ["send", "-b", block, text])
        guard typed.status == 0 else { return false }
        try? await Task.sleep(for: .milliseconds(150))
        return await Processes.run(rex, ["send-key", "-b", block, "enter"]).status == 0
    }

    static func press(_ key: String, in block: String) async -> Bool {
        guard let rex = executable else { return false }
        return await Processes.run(rex, ["send-key", "-b", block, key]).status == 0
    }

    private static func activateApp() {
        Task { @MainActor in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
    }
}

/// Plan limits from the endpoint Claude Code's /usage screen reads. The OAuth
/// token is borrowed read-only from Claude Code's Keychain item; Tally never
/// refreshes it, so it can't interfere with Claude Code's own sign-in.
enum PlanUsageClient {
    private struct Credentials: Decodable {
        struct OAuth: Decodable { var accessToken: String; var expiresAt: Double? }
        var claudeAiOauth: OAuth?
    }

    private struct Response: Decodable {
        struct Window: Decodable { var utilization: Double?; var resets_at: String? }
        var five_hour: Window?
        var seven_day: Window?
        var seven_day_opus: Window?
        var seven_day_sonnet: Window?
    }

    /// Returns nil for transient failures (network, server errors) so callers
    /// can keep showing the last good numbers.
    static func fetch() async -> PlanState? {
        let keychain = await Processes.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        guard keychain.status == 0,
              let creds = try? JSONDecoder().decode(Credentials.self, from: Data(keychain.output.utf8)),
              let oauth = creds.claudeAiOauth else {
            return .unavailable("Sign in to Claude Code to see plan limits.")
        }
        if let expiry = oauth.expiresAt, Date(timeIntervalSince1970: expiry / 1000) < .now {
            return .unavailable("Sign-in expired. Use Claude Code once to refresh it.")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .unavailable("Sign-in expired. Use Claude Code once to refresh it.") }
            guard code == 200 else { return nil }
            let r = try JSONDecoder().decode(Response.self, from: data)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func limit(_ id: String, _ title: String, _ w: Response.Window?) -> PlanLimit? {
                guard let w, let u = w.utilization else { return nil }
                return PlanLimit(id: id, title: title, percent: u, resetsAt: w.resets_at.flatMap { iso.date(from: $0) })
            }
            let limits = [
                limit("five_hour", "Current session", r.five_hour),
                limit("seven_day", "Weekly · all models", r.seven_day),
                limit("seven_day_opus", "Weekly · Opus", r.seven_day_opus),
                limit("seven_day_sonnet", "Weekly · Sonnet", r.seven_day_sonnet),
            ].compactMap { $0 }
            return limits.isEmpty ? .unavailable("No plan limits reported.") : .loaded(limits)
        } catch {
            return nil
        }
    }
}
