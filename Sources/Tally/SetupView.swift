import ServiceManagement
import SwiftUI
import UserNotifications

/// First-run setup: everything recommended is pre-selected, one button
/// applies it all, and the only interruption is a single password prompt.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var notify = true
    @State private var sessionAlerts = true
    @State private var keepAwake = true
    @State private var lidClosed = true
    @State private var openAtLogin = true
    @State private var followClaudeCode = true

    @State private var results: [Step: Result] = [:]
    @State private var running = false

    enum Step: Hashable { case notify, alerts, keepAwake, lid, login, follow }
    enum Result: Equatable { case done, failed(String) }

    private var finished: Bool { !results.isEmpty && !running }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Set Up Tally")
                    .font(.title2.weight(.semibold))
                Text("Everything below is recommended and already selected. Click Set Up and you're done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                row(.notify, $notify, "bell.badge", "Notifications",
                    "Warn me when a session's context gets big or a plan limit is nearly used up.")
                Divider().padding(.leading, 44)
                row(.alerts, $sessionAlerts, "bell.and.waves.left.and.right", "Tell me when Claude is done or needs me",
                    "A notification and a menu bar badge when a session finishes or stops at a prompt.")
                Divider().padding(.leading, 44)
                row(.keepAwake, $keepAwake, "cup.and.saucer", "Keep Mac awake while Claude works",
                    "No idle sleep while a session is working. Normal sleep once they're idle.")
                Divider().padding(.leading, 44)
                row(.lid, $lidClosed, "laptopcomputer", "Even with the lid closed",
                    "Stops Claude losing the network when you close the lid. Asks for your password once.")
                    .disabled(!keepAwake)
                Divider().padding(.leading, 44)
                row(.login, $openAtLogin, "power", "Open at login",
                    "Tally starts with your Mac.")
                Divider().padding(.leading, 44)
                row(.follow, $followClaudeCode, "terminal", "Open with Claude Code",
                    "Tally opens when a session starts and quits after the last one ends.")
            }
            .padding(.vertical, 4)
            .background(.fill.quinary, in: .rect(cornerRadius: 14))

            HStack {
                if finished {
                    Text(failures == 0 ? "All set." : "\(failures) step\(failures == 1 ? "" : "s") didn't finish. You can retry or change them in Settings.")
                        .font(.callout)
                        .foregroundStyle(failures == 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                } else {
                    Button("Not Now") { finishSetup() }
                        .buttonStyle(.glass)
                }
                Spacer()
                if finished {
                    if failures > 0 {
                        Button("Retry") { Task { await apply() } }
                            .buttonStyle(.glass)
                    }
                    Button("Done") { finishSetup() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        Task { await apply() }
                    } label: {
                        if running { ProgressView().controlSize(.small) } else { Text("Set Up") }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate() }
    }

    private var failures: Int {
        results.values.filter { if case .failed = $0 { true } else { false } }.count
    }

    private func row(_ step: Step, _ isOn: Binding<Bool>, _ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let reason) = results[step] {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            switch results[step] {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            default:
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(running)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func apply() async {
        running = true
        defer { running = false }
        let selected = { (step: Step, on: Bool) in on && results[step] != .done }

        if selected(.notify, notify) {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if granted || status == .authorized {
                UserDefaults.standard.set(true, forKey: SettingsKey.notifyContext)
                UserDefaults.standard.set(true, forKey: SettingsKey.notifyPlan)
                record(.notify, .done)
            } else {
                // Once denied, macOS only lets the user change it in System Settings.
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                record(.notify, .failed("Notifications are off for Tally. Turn them on in System Settings, which just opened."))
            }
        }

        let alertKeys = [SettingsKey.notifyDone, SettingsKey.notifyNeedsYou, SettingsKey.showBadge]
        if selected(.alerts, sessionAlerts) {
            alertKeys.forEach { UserDefaults.standard.set(true, forKey: $0) }
            record(.alerts, .done)
        } else if !sessionAlerts {
            alertKeys.forEach { UserDefaults.standard.set(false, forKey: $0) }
        }

        if selected(.keepAwake, keepAwake) {
            model.keepAwake = true
            record(.keepAwake, .done)
        }

        if selected(.lid, lidClosed && keepAwake) {
            UserDefaults.standard.set(true, forKey: SettingsKey.keepAwakeLidClosed)
            if let error = LidSleep.isSetUp ? nil : LidSleep.setUp() {
                record(.lid, .failed(error))
            } else {
                model.updateSleepAssertion()
                record(.lid, .done)
            }
        }

        if selected(.login, openAtLogin) {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                record(.login, .done)
            } catch {
                record(.login, .failed(error.localizedDescription))
            }
        }

        if selected(.follow, followClaudeCode) {
            do {
                if !ClaudeCodeHook.isInstalled { try ClaudeCodeHook.setInstalled(true) }
                UserDefaults.standard.set(true, forKey: SettingsKey.followClaudeCode)
                record(.follow, .done)
            } catch {
                record(.follow, .failed("Couldn't update ~/.claude/settings.json."))
            }
        }

        // Nothing was selected: treat it like "Not Now".
        if results.isEmpty { finishSetup() }
    }

    private func record(_ step: Step, _ result: Result) {
        withAnimation(.smooth) { results[step] = result }
    }

    private func finishSetup() {
        UserDefaults.standard.set(true, forKey: SettingsKey.setupCompleted)
        dismissWindow(id: "setup")
    }
}
