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
    /// Height of the list up to the bottom of the 4th row.
    @State private var fourRowsHeight: CGFloat = 0
    private let visibleRows = 4

    var body: some View {
        SectionCard("Sessions", contentPadding: 0) {
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Live Sessions", systemImage: "terminal")
                } description: {
                    Text("Start Claude Code in a terminal and it shows up here.")
                }
                .controlSize(.small)
                .padding(12)
            } else if model.sessions.count > visibleRows {
                // Show four rows and scroll the rest. A ScrollView has no
                // height of its own in a menu bar window, so it's set from
                // where the 4th row ends.
                ScrollView {
                    rows
                }
                .scrollIndicators(.visible)
                .frame(height: max(fourRowsHeight + 12, 120))
            } else {
                rows
            }
        }
    }
}

extension SessionsSection {
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 { Divider().padding(.vertical, 10) }
                SessionRow(session: session)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("sessionList")).maxY } action: { maxY in
                        if index == visibleRows - 1 { fourRowsHeight = maxY }
                    }
            }
        }
        .padding(12)
        .coordinateSpace(.named("sessionList"))
    }
}

private struct TodaySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var selected: String?
    @State private var hoverDate: Date?

    /// Validated categorical slots (blue, orange, aqua) per mode; "Other" is neutral.
    private var palette: [Color] {
        colorScheme == .dark
            ? [Color(hex: 0x3987e5), Color(hex: 0xd95926), Color(hex: 0x199e70)]
            : [Color(hex: 0x2a78d6), Color(hex: 0xeb6834), Color(hex: 0x1baf7a)]
    }

    private func color(for series: String, in all: [ProjectUsage]) -> Color {
        if series == AppModel.otherSeries { return .gray }
        let index = all.firstIndex { $0.path == series } ?? 0
        return palette[min(index, palette.count - 1)]
    }

    var body: some View {
        let week = model.weekByProject
        let today: TokenTotals = selected.map { s in
            model.todayByProject.first { $0.path == s }?.totals ?? TokenTotals()
        } ?? model.totals(onDay: .now)

        SectionCard("Usage") {
            if let selected {
                Button("Show all") { withAnimation(.smooth) { self.selected = nil } }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Stop filtering by \(Project.name(of: selected))")
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.map { "\(seriesName($0)) today" } ?? "Today")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Stat(value: Format.tokens(today.total), label: "tokens")
                        Stat(value: Format.tokens(today.output), label: "output")
                        Stat(value: Format.tokens(today.cacheRead), label: "cache read")
                        Stat(value: "\(today.messages)", label: "replies")
                    }
                }

                chart(week)

                if !week.series.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(week.series) { p in
                            legendRow(p, color: color(for: p.path, in: week.series))
                        }
                    }
                }
            }
        }
    }

    private func seriesName(_ series: String) -> String {
        series == AppModel.otherSeries ? "Other" : Project.name(of: series)
    }

    private func chart(_ week: (series: [ProjectUsage], days: [ProjectDay])) -> some View {
        let domain = week.series.map(\.path)
        let range = week.series.map { color(for: $0.path, in: week.series) }
        let hovered = hoverDate.map { Calendar.current.startOfDay(for: $0) }

        return Chart {
            ForEach(week.days) { d in
                BarMark(
                    x: .value("Day", d.date, unit: .day),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(by: .value("Project", d.series))
                .opacity(selected == nil || selected == d.series ? 1 : 0.2)
            }
            if let hovered {
                RuleMark(x: .value("Day", hovered, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 18))
                    .zIndex(-1)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(for: hovered, in: week)
                    }
            }
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartXSelection(value: $hoverDate)
        .frame(height: 76)
        .accessibilityLabel("Tokens per day by project, last seven days")
    }

    private func tooltip(for date: Date, in week: (series: [ProjectUsage], days: [ProjectDay])) -> some View {
        let segments = week.days.filter { $0.date == date }.sorted { $0.tokens > $1.tokens }
        let total = segments.reduce(0) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.caption.weight(.semibold))
            Text("\(Format.tokens(total)) tokens").font(.caption).foregroundStyle(.secondary)
            ForEach(segments) { s in
                HStack(spacing: 5) {
                    Circle().fill(color(for: s.series, in: week.series)).frame(width: 6, height: 6)
                    Text(seriesName(s.series)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.tokens(s.tokens)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(width: 170)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private func legendRow(_ p: ProjectUsage, color: Color) -> some View {
        let isSelected = selected == p.path
        let isOther = p.path == AppModel.otherSeries
        return Button {
            withAnimation(.smooth) { selected = isSelected ? nil : p.path }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(seriesName(p.path)).lineLimit(1)
                Spacer()
                Text("\(Format.tokens(p.totals.total)) this week")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isOther)
        .help(isOther ? "" : isSelected ? "Show all projects" : "Show only \(seriesName(p.path))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
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
