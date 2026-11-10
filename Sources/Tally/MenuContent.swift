import Charts
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.showPlan) private var showPlan = true

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                Header()
                if !model.overThreshold.isEmpty { WarningBanner() }
                if showPlan { PlanSection() }
                SessionsSection()
                TodaySection()
                Footer()
            }
            .padding(14)
        }
        .frame(width: 368)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.toast)
        .animation(.smooth, value: model.overThreshold.map(\.id))
        .onAppear { model.popoverOpened() }
    }
}

// MARK: - Header & footer

private struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code")
                    .font(.title3.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isScanning)
            }
            .help("Refresh")
            .accessibilityLabel("Refresh")
            SettingsButton()
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var subtitle: String {
        if model.isScanning && model.days.isEmpty { return "Reading transcripts…" }
        let live = model.sessions.count
        let sessions = live == 1 ? "1 live session" : "\(live) live sessions"
        guard let updated = model.lastUpdated else { return sessions }
        return "\(sessions) · updated \(updated.formatted(.relative(presentation: .named)))"
    }
}

private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            NSApp.activate()
            openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

private struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Menu {
                Section("Recent Projects") {
                    ForEach(model.recentProjects, id: \.self) { path in
                        Button((path as NSString).abbreviatingWithTildeInPath) { model.newSession(in: path) }
                    }
                }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button("Quit Tally") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Start Session"
        panel.message = "Choose a project folder for the new Claude Code session."
        if panel.runModal() == .OK, let url = panel.url { model.newSession(in: url.path) }
    }
}

// MARK: - Sections

private struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quinary, in: .rect(cornerRadius: 14))
        }
    }
}

private struct WarningBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let over = model.overThreshold
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeat(3))
            VStack(alignment: .leading, spacing: 2) {
                Text(over.count == 1 ? "\(over[0].projectName) is over \(Format.tokens(model.threshold))" : "\(over.count) sessions are over \(Format.tokens(model.threshold))")
                    .font(.callout.weight(.semibold))
                Text("Compact to keep replies fast and limits intact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if over.count == 1, over[0].canControl {
                Button("Compact") { model.compact(over[0]) }
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct PlanSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard("Plan Limits") {
            switch model.plan {
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .loaded(let limits):
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(limits) { LimitRow(limit: $0) }
                }
            }
        }
    }
}

private struct LimitRow: View {
    let limit: PlanLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            MeterBar(fraction: limit.percent / 100, tint: tint)
            if let resets = Format.resets(limit.resetsAt) {
                Text(resets).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch limit.percent {
        case 90...: .red
        case 70...: .orange
        default: .accentColor
        }
    }
}

private struct SessionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard("Sessions") {
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Live Sessions", systemImage: "terminal")
                } description: {
                    Text("Start Claude Code in a terminal and it shows up here.")
                }
                .controlSize(.small)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Divider().padding(.vertical, 10) }
                            SessionRow(session: session)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: model.sessions.count <= 3)
            }
        }
    }
}

private struct TodaySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let today = model.totals(onDay: .now)
        SectionCard("Today") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Stat(value: Format.tokens(today.total), label: "tokens")
                    Stat(value: Format.tokens(today.output), label: "output")
                    Stat(value: Format.tokens(today.cacheRead), label: "cache read")
                    Stat(value: "\(today.messages)", label: "replies")
                }

                Chart(model.lastSevenDays) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Tokens", day.totals.total)
                    )
                    .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.accentColor : Color.secondary.opacity(0.45))
                    .clipShape(.rect(cornerRadius: 3))
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .frame(height: 64)
                .accessibilityLabel("Tokens per day, last seven days")

                let projects = model.todayByProject.prefix(3)
                if !projects.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(projects) { p in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text(Format.tokens(p.totals.total)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
