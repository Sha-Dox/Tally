import Foundation

/// A running interactive Claude Code session, from ~/.claude/sessions/<pid>.json
/// enriched with what its transcript says.
struct LiveSession: Identifiable, Hashable {
    let id: String
    let pid: Int32
    var name: String
    var status: String
    var startedAt: Date
    var launchCwd: String
    var projectPath: String
    var transcriptURL: URL?
    var context: ContextReading?
    var rexBlock: String?
    /// What a "waiting" session needs from the user, e.g. a permission prompt.
    var waitingFor: String?

    var projectName: String { Project.name(of: Project.root(of: projectPath)) }

    var isBusy: Bool { status == "busy" }
    var isIdle: Bool { status == "idle" }
    var isWaiting: Bool { status == "waiting" }
    var canControl: Bool { rexBlock != nil }
}

/// The context size of a session, taken from the usage of its latest main-chain reply.
struct ContextReading: Hashable {
    var tokens: Int?
    var model: String?
    var at: Date?
    var compacted: Bool
}

struct TokenTotals: Codable, Hashable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var messages = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        messages += other.messages
    }
}

enum Project {
    /// Collapses a working directory to its project folder: the top-level
    /// folder under home (agents often cd into subfolders), or the path itself.
    static func root(of path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp") { return "/tmp" }
        guard path.hasPrefix(home + "/") else { return path.hasPrefix("-") ? home : path }
        let rest = path.dropFirst(home.count + 1)
        let first = rest.split(separator: "/").first.map(String.init) ?? ""
        return first.isEmpty ? home : home + "/" + first
    }

    static func name(of path: String) -> String {
        if path == NSHomeDirectory() { return "Home" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

struct ProjectUsage: Identifiable, Hashable {
    let path: String
    let totals: TokenTotals
    var id: String { path }
    var name: String { Project.name(of: path) }
}

/// One stacked bar segment: a project's tokens on one day.
struct ProjectDay: Identifiable, Hashable {
    let date: Date
    let series: String
    let tokens: Int
    var id: String { "\(date.timeIntervalSince1970)|\(series)" }
}

struct PlanLimit: Identifiable, Hashable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
}

enum PlanState: Equatable {
    case loading
    case loaded([PlanLimit])
    case unavailable(String)
}

enum Format {
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 10_000_000...: return String(format: "%.0fM", v / 1_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.0fK", v / 1_000)
        default: return "\(n)"
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5"
    static func model(_ id: String?) -> String? {
        guard var id, !id.isEmpty, id != "<synthetic>" else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && Int($0) != nil }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    static func resets(_ date: Date?) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resetting now" }
        if interval < 24 * 3600 {
            let f = DateComponentsFormatter()
            f.allowedUnits = interval < 3600 ? [.minute] : [.hour, .minute]
            f.unitsStyle = .abbreviated
            return "Resets in \(f.string(from: interval) ?? "")"
        }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}
