import ServiceManagement
import SwiftUI

@main
struct TallyApp: App {
    @State private var model = AppModel()

    init() {
        // Developer aid: `Tally --render-menu out.png` saves the menu to an
        // image (without Liquid Glass) for checking layout, then quits.
        if let i = CommandLine.arguments.firstIndex(of: "--render-menu"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let model = _model.wrappedValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let renderer = ImageRenderer(content: MenuContent().environment(model).background(Color(white: 0.16)).environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        // A plain Window rather than a Settings scene: menu-bar-only apps
        // can't reliably bring the Settings scene forward.
        Window("Tally Settings", id: "settings") {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Shown automatically until setup is finished or skipped.
        Window("Set Up Tally", id: "setup") {
            SetupView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: SettingsKey.setupCompleted) ? .suppressed : .presented)
        .restorationBehavior(.disabled)
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.menuBarStyle) private var style = MenuBarStyle.percent.rawValue
    @AppStorage(SettingsKey.showBadge) private var showBadge = true

    private var badge: Bool { showBadge && model.needsAttention }

    var body: some View {
        Group {
            if (MenuBarStyle(rawValue: style) ?? .percent) == .percent, let session = model.sessionLimit {
                // The menu bar only draws a single line, so the stacked
                // layout is rendered to a template image.
                Image(nsImage: stackedImage(session: session, weekly: model.weeklyLimit))
            } else {
                HStack(spacing: 3) {
                    Image(systemName: symbol)
                    if let text { Text(text).monospacedDigit() }
                    if badge { Image(systemName: "circle.fill").imageScale(.small) }
                }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func stackedImage(session: PlanLimit, weekly: PlanLimit?) -> NSImage {
        let font = Font.system(size: 9.5, weight: .semibold).monospacedDigit()
        let content = Grid(alignment: .trailing, horizontalSpacing: 2, verticalSpacing: -1) {
            GridRow {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                    .overlay(alignment: .topTrailing) {
                        // Waiting badge: a dot cut out of the gauge's corner.
                        if badge {
                            Circle().frame(width: 5, height: 5)
                                .padding(1.2)
                                .background(Circle().blendMode(.destinationOut))
                                .offset(x: 2.5, y: -2)
                        }
                    }
                    .compositingGroup()
                    .gridColumnAlignment(.center)
                Text("\(Int(session.percent.rounded()))%")
            }
            if let weekly {
                GridRow {
                    Text("W").font(.system(size: 8.5, weight: .heavy))
                    Text("\(Int(weekly.percent.rounded()))%")
                }
            }
        }
        .font(font)
        .foregroundStyle(.black)
        .frame(height: 22)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
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
        if badge { parts.append("a session needs your attention") }
        return parts.joined(separator: ", ")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.threshold) private var threshold = 400_000
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 600_000
    @AppStorage(SettingsKey.notifyContext) private var notifyContext = true
    @AppStorage(SettingsKey.notifyPlan) private var notifyPlan = true
    @AppStorage(SettingsKey.notifyDone) private var notifyDone = true
    @AppStorage(SettingsKey.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(SettingsKey.showBadge) private var showBadge = true
    @AppStorage(SettingsKey.showPlan) private var showPlan = true
    @AppStorage(SettingsKey.menuBarStyle) private var style = MenuBarStyle.percent.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(SettingsKey.followClaudeCode) private var followClaudeCode = false
    @State private var hookError: String?
    @AppStorage(SettingsKey.keepAwakeLidClosed) private var lidClosed = true
    @State private var lidSetUp = LidSleep.isSetUp
    @State private var lidError: String?

    private let thresholds = [200_000, 300_000, 400_000, 500_000, 600_000, 700_000, 800_000, 900_000]

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { page(general) }
            Tab("Context", systemImage: "gauge.with.dots.needle.67percent") { page(context) }
            Tab("Alerts", systemImage: "bell") { page(alerts) }
            Tab("Keep Awake", systemImage: "cup.and.saucer") { page(keepAwake) }
        }
        .frame(width: 460)
        .onChange(of: threshold) {
            if critical <= threshold { critical = thresholds.first { $0 > threshold } ?? threshold }
            model.refreshSessions()
        }
        .onChange(of: critical) { model.refreshSessions() }
        .onChange(of: lidClosed) { model.updateSleepAssertion() }
        .onAppear {
            // Reflect the real state in case settings.json was edited elsewhere.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if followClaudeCode != ClaudeCodeHook.isInstalled { followClaudeCode = ClaudeCodeHook.isInstalled }
        }
        .onChange(of: showPlan) { Task { await model.refreshPlan(force: true) } }
    }

    private func page(_ content: some View) -> some View {
        Form { content }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var context: some View {
        Section {
            Picker("Warn when context exceeds", selection: $threshold) {
                ForEach(thresholds, id: \.self) { Text("\(Format.tokens($0)) tokens").tag($0) }
            }
            Picker("Turn red above", selection: $critical) {
                ForEach(thresholds.filter { $0 > threshold }, id: \.self) { Text("\(Format.tokens($0)) tokens").tag($0) }
            }
        } header: {
            Text("Context")
        } footer: {
            Text("Context turns orange past the warning level and red past the second one. Each session's context is the token count of its latest reply; the warning resets after you compact.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var alerts: some View {
        Section {
            Toggle("When a session finishes", isOn: $notifyDone)
            Toggle("When a session needs you", isOn: $notifyNeedsYou)
            Toggle("Badge in the menu bar", isOn: $showBadge)
        } header: {
            Text("Sessions")
        } footer: {
            Text("A session counts as finished after a turn of 30 seconds or more, so quick back-and-forth stays quiet. It needs you when it stops at a permission prompt or a question. The badge shows until you open Tally's menu.")
                .foregroundStyle(.secondary)
        }

        Section("Limits") {
            Toggle("When a session goes over the context warning", isOn: $notifyContext)
            Toggle("When a plan limit reaches 90%", isOn: $notifyPlan)
                .disabled(!showPlan)
        }
    }

    @ViewBuilder
    private var keepAwake: some View {
        Section {
            @Bindable var model = model
            Toggle("Keep Mac awake while Claude is working", isOn: $model.keepAwake)
            Toggle("Even with the lid closed", isOn: $lidClosed)
                .disabled(!lidSetUp || !model.keepAwake)
            LabeledContent("Lid-closed permission") {
                if lidSetUp {
                    Button("Remove") {
                        lidError = LidSleep.remove()
                        lidSetUp = LidSleep.isSetUp
                    }
                } else {
                    Button("Set Up…") {
                        lidError = LidSleep.setUp()
                        lidSetUp = LidSleep.isSetUp
                        model.updateSleepAssertion()
                    }
                }
            }
        } header: {
            Text("Keep Awake")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS always sleeps when the lid closes, which cuts the network and makes Claude Code fail. Set Up asks for your password once, so Tally can turn that off while a session is working and back on when it's idle or Tally quits. It stops below 15% battery.")
                if let lidError { Text(lidError).foregroundStyle(.red) }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var general: some View {
        Section("Menu Bar") {
            Picker("Show", selection: $style) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }

        Section("Plan") {
            Toggle("Show plan limits", isOn: $showPlan)
        }

        Section {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Open and quit with Claude Code", isOn: $followClaudeCode)
                .onChange(of: followClaudeCode) { _, enabled in
                    guard enabled != ClaudeCodeHook.isInstalled else { return }
                    do {
                        try ClaudeCodeHook.setInstalled(enabled)
                        hookError = nil
                    } catch {
                        hookError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
                        followClaudeCode = ClaudeCodeHook.isInstalled
                    }
                }
        } header: {
            Text("Startup")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open and quit with Claude Code adds a SessionStart hook to ~/.claude/settings.json that opens Tally in the background, and quits Tally 30 seconds after the last session ends.")
                if let hookError { Text(hookError).foregroundStyle(.red) }
            }
            .foregroundStyle(.secondary)
        }

        Section {
            LabeledContent("First-time setup") {
                RunSetupButton()
            }
        }

        Section("Session Controls") {
            LabeledContent("Terminal") {
                Label(Rex.isAvailable ? "Rex" : "Rex not found", systemImage: Rex.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(Rex.isAvailable ? .green : .secondary)
            }
            Text("Go to session, Compact, Interrupt and Send work for sessions running in Rex.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RunSetupButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Run Setup…") {
            openWindow(id: "setup")
            NSApp.activate()
        }
    }
}
