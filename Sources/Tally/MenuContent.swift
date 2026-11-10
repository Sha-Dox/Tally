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
                model.keepAwake.toggle()
            } label: {
                Image(systemName: model.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(model.keepAwake ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .symbolEffect(.pulse, isActive: model.isPreventingSleep)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(model.keepAwake ? "Keep awake is on: your Mac won't sleep while Claude is working" : "Keep your Mac awake while Claude is working")
            .accessibilityLabel("Keep awake while Claude is working")
            .accessibilityValue(model.keepAwake ? "On" : "Off")
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
        var sessions = live == 1 ? "1 live session" : "\(live) live sessions"
        if model.isLidSleepDisabled {
            sessions += " · awake, lid too"
        } else if model.isPreventingSleep {
            sessions += " · keeping awake"
        }
        guard let updated = model.lastUpdated else { return sessions }
        return "\(sessions) · updated \(updated.formatted(.relative(presentation: .named)))"
    }
}

private struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "settings")
            NSApp.activate()
        } label: {
            Image(systemName: "gearshape")
        }
        .keyboardShortcut(",")
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

private struct Footer: View {
    var body: some View {
        HStack {
            Spacer()
            Button("Quit Tally") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

// MARK: - Sections

private struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    var contentPadding: CGFloat = 12
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, contentPadding: CGFloat = 12, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.contentPadding = contentPadding
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
                .padding(contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quinary, in: .rect(cornerRadius: 14))
        }
    }
}

private struct WarningBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let over = model.overThreshold
        let color = model.contextColor(over.compactMap(\.context?.tokens).max())
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(color)
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
                    .tint(color)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(color.opacity(0.18)), in: .rect(cornerRadius: 16))
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
    @State private var listHeight: CGFloat = 0

    /// Room left on screen after the other sections (about 560pt).
    private var maxListHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 900) - 560)
    }

    var body: some View {
        // Padding lives inside the scroll view so the busy pulse and glass
        // shadows at the edges aren't clipped by it.
        SectionCard("Sessions", contentPadding: 0) {
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Live Sessions", systemImage: "terminal")
                } description: {
                    Text("Start Claude Code in a terminal and it shows up here.")
                }
                .controlSize(.small)
                .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Divider().padding(.vertical, 10) }
                            SessionRow(session: session)
                        }
                    }
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // A ScrollView has no height of its own in a menu bar window,
                // so size it to its rows and only scroll past what fits.
                .frame(height: min(max(listHeight.rounded(.up), 1), maxListHeight))
                // Lock scrolling entirely when every row fits.
                .scrollDisabled(listHeight <= maxListHeight)
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
