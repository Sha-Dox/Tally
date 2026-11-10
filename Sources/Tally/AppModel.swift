import AppKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

enum SettingsKey {
    static let threshold = "contextThreshold"
    static let criticalThreshold = "contextCriticalThreshold"
    static let notifyContext = "notifyContext"
    static let notifyPlan = "notifyPlan"
    static let menuBarStyle = "menuBarStyle"
    static let showPlan = "showPlan"
}

@MainActor
@Observable
final class AppModel {
    var sessions: [LiveSession] = []
    var plan: PlanState = .loading
    var days: [String: [String: TokenTotals]] = [:]
    var lastUpdated: Date?
    var isScanning = false
    var toast: String?

    @ObservationIgnored private let scanner = UsageScanner()
    @ObservationIgnored private var contextCache: [String: (modified: Date, reading: ContextReading?, cwd: String?)] = [:]
    @ObservationIgnored private var warned: Set<String> = []
    @ObservationIgnored private var planWarned: Set<String> = []
    @ObservationIgnored private var planFetchedAt: Date?
    @ObservationIgnored private var timers: [Timer] = []
    var pendingCompactions: Set<String> = []

    var threshold: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.threshold)
        return v > 0 ? v : 400_000
    }

    var criticalThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: SettingsKey.criticalThreshold)
        return max(v > 0 ? v : 600_000, threshold)
    }

    /// A colour that shifts smoothly with context size: green when small,
    /// through yellow, reaching orange at the warning level and red at the
    /// critical one.
    func contextColor(_ tokens: Int?) -> Color {
        let t = Double(tokens ?? 0)
        let warn = Double(threshold), crit = Double(criticalThreshold)
        // Hue stops: green 0.36 → orange 0.08 at warn → red 0.0 at crit.
        let hue: Double
        if t <= warn {
            hue = 0.36 - (0.36 - 0.08) * (t / warn)
        } else {
            hue = 0.08 * (1 - min((t - warn) / max(crit - warn, 1), 1))
        }
        return Color(hue: hue, saturation: 0.82, brightness: 0.95)
    }

    /// Only past the warning level, for text and buttons that are neutral otherwise.
    func contextTint(_ tokens: Int?) -> Color? {
        guard let tokens, tokens >= threshold else { return nil }
        return contextColor(tokens)
    }

    var weeklyLimit: PlanLimit? {
        if case .loaded(let limits) = plan { return limits.first { $0.id == "seven_day" } }
        return nil
    }

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.threshold: 400_000,
            SettingsKey.criticalThreshold: 600_000,
            SettingsKey.notifyContext: true,
            SettingsKey.notifyPlan: true,
            SettingsKey.menuBarStyle: MenuBarStyle.percent.rawValue,
            SettingsKey.showPlan: true,
        ])
        Notifier.shared.configure(model: self)
        refreshSessions()
        Task { await refreshUsage() }
        Task { await refreshPlan(force: true) }

        timers = [
            Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshSessions() }
            },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshUsage() }
            },
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshPlan(force: true) }
            },
        ]
    }

    // MARK: Derived

    var overThreshold: [LiveSession] {
        sessions.filter { ($0.context?.tokens ?? 0) >= threshold }
    }

    var sessionLimit: PlanLimit? {
        if case .loaded(let limits) = plan { return limits.first { $0.id == "five_hour" } }
        return nil
    }

    func totals(onDay date: Date) -> TokenTotals {
        var t = TokenTotals()
        for (_, v) in days[dayKey(date)] ?? [:] { t.add(v) }
        return t
    }

    var lastSevenDays: [DayUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<7).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: today).map { DayUsage(date: $0, totals: totals(onDay: $0)) }
        }
    }

    var todayByProject: [ProjectUsage] {
        var grouped: [String: TokenTotals] = [:]
        for (path, totals) in days[dayKey(.now)] ?? [:] {
            grouped[Project.root(of: path), default: TokenTotals()].add(totals)
        }
        return grouped
            .map { ProjectUsage(path: $0.key, totals: $0.value) }
            .sorted { $0.totals.total > $1.totals.total }
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Refresh

    func refreshAll() {
        refreshSessions()
        Task { await refreshUsage() }
        Task { await refreshPlan(force: true) }
    }

    func popoverOpened() {
        refreshSessions()
        Task { await refreshPlan(force: false) }
    }

    func refreshSessions() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: ClaudePaths.sessions, includingPropertiesForKeys: nil)) ?? []
        var found: [LiveSession] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = raw["pid"] as? Int, let id = raw["sessionId"] as? String,
                  (raw["kind"] as? String ?? "interactive") == "interactive",
                  Processes.isAlive(Int32(pid)) else { continue }

            let cwd = raw["cwd"] as? String ?? NSHomeDirectory()
            var session = LiveSession(
                id: id,
                pid: Int32(pid),
                name: raw["name"] as? String ?? String(id.prefix(8)),
                status: raw["status"] as? String ?? "unknown",
                startedAt: Date(timeIntervalSince1970: (raw["startedAt"] as? Double ?? 0) / 1000),
                launchCwd: cwd,
                projectPath: cwd
            )
            if let existing = sessions.first(where: { $0.id == id && $0.pid == session.pid }) {
                session.rexBlock = existing.rexBlock
                session.transcriptURL = existing.transcriptURL
            } else {
                session.rexBlock = Processes.environment(of: session.pid)["REX_BLOCK"]
            }
            if session.transcriptURL == nil { session.transcriptURL = TranscriptReader.url(forSession: id) }

            if let url = session.transcriptURL {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let cached = contextCache[url.path], cached.modified == modified {
                    session.context = cached.reading
                    if let c = cached.cwd { session.projectPath = c }
                } else {
                    let (reading, latestCwd) = TranscriptReader.latestContext(at: url)
                    contextCache[url.path] = (modified, reading, latestCwd)
                    session.context = reading
                    if let c = latestCwd { session.projectPath = c }
                }
            }
            found.append(session)
        }

        sessions = found.sorted {
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return ($0.context?.at ?? $0.startedAt) > ($1.context?.at ?? $1.startedAt)
        }
        lastUpdated = .now
        pendingCompactions.formIntersection(Set(found.map(\.id)))
        for session in found where session.isIdle && pendingCompactions.contains(session.id) {
            compact(session)
        }
        checkContextWarnings()
    }

    func refreshUsage() async {
        guard !isScanning else { return }
        isScanning = true
        days = await scanner.scan()
        isScanning = false
    }

    func refreshPlan(force: Bool) async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showPlan) else { return }
        if !force, let at = planFetchedAt, Date.now.timeIntervalSince(at) < 60 { return }
        planFetchedAt = .now
        let result = await PlanUsageClient.fetch()
        // Keep the last good numbers through a transient failure.
        if case .unavailable = result, case .loaded = plan, force == false { return }
        plan = result
        checkPlanWarnings()
    }

    // MARK: Warnings

    private func checkContextWarnings() {
        let over = Set(overThreshold.map(\.id))
        // Re-arm once a session drops back under the threshold (e.g. after /compact).
        warned.formIntersection(over)
        guard UserDefaults.standard.bool(forKey: SettingsKey.notifyContext) else { return }
        for session in overThreshold where !warned.contains(session.id) {
            warned.insert(session.id)
            Notifier.shared.contextWarning(for: session, threshold: threshold)
        }
    }

    private func checkPlanWarnings() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.notifyPlan), case .loaded(let limits) = plan else { return }
        for limit in limits where limit.percent >= 90 {
            let key = "\(limit.id)-\(limit.resetsAt?.timeIntervalSince1970 ?? 0)"
            guard !planWarned.contains(key) else { continue }
            planWarned.insert(key)
            Notifier.shared.planWarning(limit)
        }
    }

    // MARK: Controls

    func session(withID id: String) -> LiveSession? { sessions.first { $0.id == id } }

    func show(_ session: LiveSession) {
        guard let block = session.rexBlock else { return }
        Task { await Rex.focus(block: block) }
    }

    /// Compacts now if the session is idle; otherwise waits for it to finish
    /// its turn so the command doesn't land in the middle of a prompt.
    func compact(_ session: LiveSession) {
        guard session.canControl else { return }
        if session.isIdle {
            pendingCompactions.remove(session.id)
            send("/compact", to: session, confirmation: "Compacting \(session.projectName)…")
        } else {
            pendingCompactions.insert(session.id)
            flash("Will compact \(session.projectName) when it's idle")
        }
    }

    func send(_ text: String, to session: LiveSession, confirmation: String? = nil) {
        guard let block = session.rexBlock, !text.isEmpty else { return }
        Task {
            let ok = await Rex.send(text, to: block)
            flash(ok ? (confirmation ?? "Sent to \(session.name)") : "Couldn't reach that terminal.")
        }
    }

    func interrupt(_ session: LiveSession) {
        guard let block = session.rexBlock else { return }
        Task {
            let ok = await Rex.press("escape", in: block)
            flash(ok ? "Interrupted \(session.name)" : "Couldn't reach that terminal.")
        }
    }

    func end(_ session: LiveSession) {
        if session.canControl, session.isIdle {
            send("/exit", to: session, confirmation: "Ended \(session.name)")
        } else {
            kill(session.pid, SIGTERM)
            flash("Ended \(session.name)")
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshSessions()
        }
    }

    func newSession(in directory: String) {
        Task {
            if Rex.isAvailable, await Rex.newSession(in: directory) { return }
            TerminalFallback.run("claude", in: directory)
        }
    }

    func resumeCommand(for session: LiveSession) -> String {
        "cd \(TerminalFallback.shellQuote(session.projectPath)) && claude --resume \(session.id)"
    }

    func copyResumeCommand(_ session: LiveSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand(for: session), forType: .string)
        flash("Copied resume command")
    }

    func revealTranscript(_ session: LiveSession) {
        guard let url = session.transcriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var recentProjects: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let ordered = (sessions.map(\.projectPath) + days.keys.sorted(by: >).flatMap { day in
            (days[day] ?? [:]).sorted { $0.value.total > $1.value.total }.map(\.key)
        }).map(Project.root(of:)).filter { $0 != "/tmp" }
        for path in ordered where !seen.contains(path) && FileManager.default.fileExists(atPath: path) {
            seen.insert(path)
            result.append(path)
            if result.count == 8 { break }
        }
        return result
    }

    private func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percent, context, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: "Plan usage (5h · 7d)"
        case .context: "Largest context"
        case .icon: "Icon only"
        }
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()

    func configure(model: AppModel) {
        self.model = model
        center.delegate = self
        let compact = UNNotificationAction(identifier: "compact", title: "Compact Now")
        let show = UNNotificationAction(identifier: "show", title: "Show Session", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "context", actions: [compact, show], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func contextWarning(for session: LiveSession, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.projectName) is over \(Format.tokens(threshold)) context"
        content.body = "\(session.name) is at \(Format.tokens(session.context?.tokens ?? 0)) tokens. Compacting keeps replies fast and focused."
        content.sound = .default
        content.categoryIdentifier = "context"
        content.userInfo = ["session": session.id]
        center.add(UNNotificationRequest(identifier: "context-\(session.id)", content: content, trigger: nil))
    }

    func planWarning(_ limit: PlanLimit) {
        let content = UNMutableNotificationContent()
        content.title = "\(limit.title) limit at \(Int(limit.percent))%"
        content.body = Format.resets(limit.resetsAt) ?? ""
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "plan-\(limit.id)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run {
            guard let model = self.model, let session = model.session(withID: id) else { return }
            switch action {
            case "compact": model.compact(session)
            default: model.show(session)
            }
        }
    }
}
