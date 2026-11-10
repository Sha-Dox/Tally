import ServiceManagement
import SwiftUI

@main
struct TallyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.menuBarStyle) private var style = MenuBarStyle.percent.rawValue

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var warning: Bool { !model.overThreshold.isEmpty }

    private var symbol: String {
        if warning { return "exclamationmark.triangle.fill" }
        let percent = model.sessionLimit?.percent ?? 0
        switch percent {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<45: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    private var text: String? {
        switch MenuBarStyle(rawValue: style) ?? .percent {
        case .percent:
            let parts = [("5h", model.sessionLimit), ("7d", model.weeklyLimit)].compactMap { label, limit in
                limit.map { "\(label) \(Int($0.percent.rounded()))%" }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .context:
            return model.sessions.compactMap(\.context?.tokens).max().map(Format.tokens)
        case .icon:
            return nil
        }
    }

    private var accessibilityText: String {
        var parts = ["Claude Code usage"]
        if let limit = model.sessionLimit { parts.append("\(Int(limit.percent)) percent of 5-hour limit") }
        if let limit = model.weeklyLimit { parts.append("\(Int(limit.percent)) percent of weekly limit") }
        if warning { parts.append("\(model.overThreshold.count) sessions over the context threshold") }
        return parts.joined(separator: ", ")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.threshold) private var threshold = 400_000
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 600_000
    @AppStorage(SettingsKey.notifyContext) private var notifyContext = true
    @AppStorage(SettingsKey.notifyPlan) private var notifyPlan = true
    @AppStorage(SettingsKey.showPlan) private var showPlan = true
    @AppStorage(SettingsKey.menuBarStyle) private var style = MenuBarStyle.percent.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let thresholds = [200_000, 300_000, 400_000, 500_000, 600_000, 700_000, 800_000, 900_000]

    var body: some View {
        Form {
            Section {
                Picker("Warn when context exceeds", selection: $threshold) {
                    ForEach(thresholds, id: \.self) { Text("\(Format.tokens($0)) tokens").tag($0) }
                }
                Picker("Turn red above", selection: $critical) {
                    ForEach(thresholds.filter { $0 > threshold }, id: \.self) { Text("\(Format.tokens($0)) tokens").tag($0) }
                }
                Toggle("Send a notification", isOn: $notifyContext)
            } header: {
                Text("Context")
            } footer: {
                Text("Context turns orange past the warning level and red past the second one. Each session's context is the token count of its latest reply; the warning resets after you compact.")
                    .foregroundStyle(.secondary)
            }

            Section("Plan") {
                Toggle("Show plan limits", isOn: $showPlan)
                Toggle("Notify at 90% of a limit", isOn: $notifyPlan)
                    .disabled(!showPlan)
            }

            Section("Menu Bar") {
                Picker("Show", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Session Controls") {
                LabeledContent("Terminal") {
                    Label(Rex.isAvailable ? "Rex" : "Rex not found", systemImage: Rex.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(Rex.isAvailable ? .green : .secondary)
                }
                Text("Show, Compact, Interrupt and Send work for sessions running in Rex. New sessions open in Rex, or Terminal if Rex isn't installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: threshold) {
            if critical <= threshold { critical = thresholds.first { $0 > threshold } ?? threshold }
            model.refreshSessions()
        }
        .onChange(of: critical) { model.refreshSessions() }
        .onChange(of: showPlan) { Task { await model.refreshPlan(force: true) } }
    }
}
