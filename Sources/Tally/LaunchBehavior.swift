import Foundation

/// Launches Tally from a Claude Code SessionStart hook in ~/.claude/settings.json.
/// The hook is identified by Tally's bundle ID so it can be removed exactly.
enum ClaudeCodeHook {
    static let settingsURL = ClaudePaths.root.appending(path: "settings.json")
    private static let marker = Bundle.main.bundleIdentifier ?? "com.mert.tally"
    private static var command: String { "/usr/bin/open -g -b \(marker) || true" }

    static var isInstalled: Bool {
        guard let entries = (try? readSettings())?["hooks"].flatMap({ $0 as? [String: Any] })?["SessionStart"] as? [[String: Any]] else { return false }
        return entries.contains(where: isOurs)
    }

    static func setInstalled(_ install: Bool) throws {
        var settings = try readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var start = (hooks["SessionStart"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
        if install {
            start.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
        }
        if start.isEmpty { hooks.removeValue(forKey: "SessionStart") } else { hooks["SessionStart"] = start }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeSettings(settings)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("open -g -b \(marker)") == true }
    }

    private static func readSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        // Keep a one-time copy of the user's original settings.
        let backup = settingsURL.appendingPathExtension("tally-backup")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
