import AppKit
import Foundation
import IOKit.pwr_mgt
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
    static let pinnedSessions = "pinnedSessions"
    static let followClaudeCode = "followClaudeCode"
    static let keepAwake = "keepAwake"
    static let keepAwakeLidClosed = "keepAwakeLidClosed"
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
    @ObservationIgnored private var contextCache: [String: (modified: Date, reading: ContextReading?, cwd: String?, title: String?)] = [:]
    @ObservationIgnored private var warned: Set<String> = []
    @ObservationIgnored private var planWarned: Set<String> = []
    @ObservationIgnored private var planFetchedAt: Date?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var hadSessions = false
    @ObservationIgnored private var emptySince: Date?
    var pendingCompactions: Set<String> = []

    /// When on, the Mac won't idle-sleep while any session is working.
    var keepAwake = UserDefaults.standard.bool(forKey: SettingsKey.keepAwake) {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: SettingsKey.keepAwake)
            updateSleepAssertion()
        }
    }
    private(set) var isPreventingSleep = false
    private(set) var isLidSleepDisabled = false
    @ObservationIgnored private var sleepAssertion = IOPMAssertionID(0)
    @ObservationIgnored private var networkAssertion = IOPMAssertionID(0)
    @ObservationIgnored private var lidChangeInFlight = false

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
            SettingsKey.keepAwakeLidClosed: true,
        ])
        Notifier.shared.configure(model: self)

        // Never leave lid-closed sleep disabled: undo a leftover from a crash,
        // and restore it when Tally quits.
        if LidSleep.isOwned { LidSleep.setSleepDisabledSync(false) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            if LidSleep.isOwned { LidSleep.setSleepDisabledSync(false) }
        }
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
            // "derived" names (e.g. "mert-36") are placeholders; prefer a real title.
            let userNamed = raw["nameSource"] as? String == "user"
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
                    if let t = cached.title, !userNamed { session.name = t }
                } else {
                    let (reading, latestCwd) = TranscriptReader.latestContext(at: url)
                    let title = TranscriptReader.latestTitle(at: url)
                    contextCache[url.path] = (modified, reading, latestCwd, title)
                    session.context = reading
                    if let c = latestCwd { session.projectPath = c }
                    if let t = title, !userNamed { session.name = t }
                }
            }
            found.append(session)
        }

        // Stable order so rows never jump around: pinned sessions first in
        // the order they were pinned, then the rest by start time.
        let pins = pinned
        sessions = found.sorted { a, b in
            switch (pins.firstIndex(of: a.id), pins.firstIndex(of: b.id)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (a.startedAt, a.pid) < (b.startedAt, b.pid)
            }
        }
        lastUpdated = .now
        updateSleepAssertion()
        quitIfClaudeCodeStopped()
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
        guard let result = await PlanUsageClient.fetch() else {
            // Transient failure: keep the last good numbers if there are any.
            if case .loaded = plan { return }
            plan = .unavailable("Couldn't reach Anthropic. Retrying shortly.")
            return
        }
        plan = result
        checkPlanWarnings()
    }

    /// With "Open and quit with Claude Code" on, quit once the last session
    /// has been gone for a while. Only after sessions were seen, so a launch at
    /// login or by hand keeps Tally open until Claude Code has run.
    private func quitIfClaudeCodeStopped() {
        if !sessions.isEmpty {
            hadSessions = true
            emptySince = nil
            return
        }
        guard hadSessions, UserDefaults.standard.bool(forKey: SettingsKey.followClaudeCode) else { return }
        let since = emptySince ?? .now
        emptySince = since
        if Date.now.timeIntervalSince(since) >= 30 { NSApp.terminate(nil) }
    }

    /// While a session is working: holds idle-sleep and network power
    /// assertions (dropped by the system if Tally quits), and, if set up,
    /// disables lid-closed sleep, which assertions alone can't prevent.
    func updateSleepAssertion() {
        let needed = keepAwake && sessions.contains(where: \.isBusy)
        if needed, !isPreventingSleep {
            let name = "Claude Code is working" as CFString
            let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, level, name, &sleepAssertion)
            // Keeps network connectivity up alongside the CPU.
            IOPMAssertionCreateWithName(kIOPMAssertNetworkClientActive as CFString, level, name, &networkAssertion)
            isPreventingSleep = result == kIOReturnSuccess
        } else if !needed, isPreventingSleep {
            IOPMAssertionRelease(sleepAssertion)
            IOPMAssertionRelease(networkAssertion)
            isPreventingSleep = false
        }

        // Lid closed: stop below 15% battery so a Mac in a bag can't run flat.
        let battery = LidSleep.batteryLevelOnBattery
        let wantLid = needed && LidSleep.isSetUp
            && UserDefaults.standard.bool(forKey: SettingsKey.keepAwakeLidClosed)
            && (battery ?? 100) >= 15
        guard wantLid != isLidSleepDisabled, !lidChangeInFlight else { return }
        lidChangeInFlight = true
        Task {
            if await LidSleep.setSleepDisabled(wantLid) { isLidSleepDisabled = wantLid }
            lidChangeInFlight = false
        }
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

    // MARK: Pinning

    var pinned: [String] {
        UserDefaults.standard.stringArray(forKey: SettingsKey.pinnedSessions) ?? []
    }

    func isPinned(_ session: LiveSession) -> Bool { pinned.contains(session.id) }

    func togglePin(_ session: LiveSession) {
        var pins = pinned
        if let i = pins.firstIndex(of: session.id) { pins.remove(at: i) } else { pins.append(session.id) }
        // Forget pins for sessions that are no longer running.
        let live = Set(sessions.map(\.id))
        pins.removeAll { !live.contains($0) }
        UserDefaults.standard.set(pins, forKey: SettingsKey.pinnedSessions)
        withAnimation(.smooth) { refreshSessions() }
    }

    func resumeCommand(for session: LiveSession) -> String {
        let dir = "'" + session.projectPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(dir) && claude --resume \(session.id)"
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
