import SwiftUI

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: LiveSession

    @State private var composing = false
    @State private var message = ""
    @State private var confirmingEnd = false
    @FocusState private var fieldFocused: Bool

    private var tokens: Int? { session.context?.tokens }
    private var tint: Color? { model.contextTint(tokens) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusDot(status: session.status)
                if model.isPinned(session) {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(45))
                        .accessibilityLabel("Pinned")
                }
                Text(session.projectName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(session.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ContextMeter(tokens: tokens, scale: model.criticalThreshold, tint: model.contextColor(tokens))

            HStack(spacing: 6) {
                Group {
                    if let tokens {
                        Text("\(Format.tokens(tokens)) context")
                            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                    } else if session.context?.compacted == true {
                        Text("Just compacted").foregroundStyle(.secondary)
                    } else {
                        Text("No replies yet").foregroundStyle(.secondary)
                    }
                    if let model = Format.model(session.context?.model) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(model).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .monospacedDigit()

                Spacer()
                controls
            }

            if composing {
                HStack(spacing: 6) {
                    TextField("Message \(session.name)", text: $message)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit(sendMessage)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                    Button("Send", action: sendMessage)
                        .buttonStyle(.glassProminent)
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .onAppear { fieldFocused = true }
                .onExitCommand { composing = false }
            }
        }
        .animation(.smooth(duration: 0.25), value: composing)
        .contextMenu { menuItems }
        .confirmationDialog("End \(session.name)?", isPresented: $confirmingEnd) {
            Button("End Session", role: .destructive) { model.end(session) }
        } message: {
            Text("The conversation is kept. You can resume it later with claude --resume.")
        }
    }

    private var statusText: String {
        if model.pendingCompactions.contains(session.id) { return "Compact queued" }
        switch session.status {
        case "busy": return "Working"
        case "idle": return "Idle"
        default: return session.status.capitalized
        }
    }

    @ViewBuilder
    private var controls: some View {
        // Own container with no merge distance so the buttons stay distinct
        // instead of melting into the window's shared glass.
        GlassEffectContainer(spacing: 0) {
        HStack(spacing: 6) {
            if session.canControl {
                if session.isBusy {
                    iconButton("stop.fill", help: "Interrupt (Esc)") { model.interrupt(session) }
                }
                iconButton("arrow.down.right.and.arrow.up.left", help: session.isIdle ? "Compact context" : "Compact when idle") {
                    model.compact(session)
                }
                .tint(tint)
                iconButton("text.bubble", help: "Send a message") { composing.toggle() }
                iconButton("arrow.up.forward.app", help: "Go to this session in Rex") { model.show(session) }
            }
            // A plain button (not a SwiftUI Menu) so it gets the exact same
            // glass circle as its neighbours; it pops up a native menu.
            iconButton("ellipsis", help: "More actions") { showMoreMenu() }
        }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }

    @ViewBuilder
    private var menuItems: some View {
        if session.canControl {
            Button("Go to Session in Rex", systemImage: "arrow.up.forward.app") { model.show(session) }
            Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") { model.compact(session) }
            Button("Send Message…", systemImage: "text.bubble") { composing = true }
            if session.isBusy {
                Button("Interrupt", systemImage: "stop") { model.interrupt(session) }
            }
            Divider()
        }
        Button(model.isPinned(session) ? "Unpin" : "Pin to Top", systemImage: model.isPinned(session) ? "pin.slash" : "pin") { model.togglePin(session) }
        Button("Copy Resume Command", systemImage: "doc.on.doc") { model.copyResumeCommand(session) }
        Button("Show Transcript in Finder", systemImage: "folder") { model.revealTranscript(session) }
            .disabled(session.transcriptURL == nil)
        Divider()
        Button("End Session…", systemImage: "xmark.circle", role: .destructive) { confirmingEnd = true }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 14, height: 14)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private func showMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if session.canControl {
            add("Go to Session in Rex", "arrow.up.forward.app") { model.show(session) }
            add("Compact", "arrow.down.right.and.arrow.up.left") { model.compact(session) }
            add("Send Message…", "text.bubble") { composing = true }
            if session.isBusy {
                add("Interrupt", "stop") { model.interrupt(session) }
            }
            menu.addItem(.separator())
        }
        add(model.isPinned(session) ? "Unpin" : "Pin to Top", model.isPinned(session) ? "pin.slash" : "pin") { model.togglePin(session) }
        add("Copy Resume Command", "doc.on.doc") { model.copyResumeCommand(session) }
        add("Show Transcript in Finder", "folder", enabled: session.transcriptURL != nil) { model.revealTranscript(session) }
        menu.addItem(.separator())
        add("End Session…", "xmark.circle") { confirmingEnd = true }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func sendMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.send(text, to: session)
        message = ""
        composing = false
    }
}

private struct StatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if status == "busy" {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(1.8)
                        .phaseAnimator([0.0, 1.0]) { view, phase in
                            view.opacity(1 - phase).scaleEffect(0.6 + phase * 0.6)
                        } animation: { _ in .easeOut(duration: 1.2) }
                }
            }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case "busy": .green
        case "idle": .secondary
        default: .yellow
        }
    }
}

struct MeterBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: fraction > 0 ? max(geo.size.width * min(fraction, 1), 6) : 0)
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

/// A bar scaled to the red level whose colour shifts gradually with size.
private struct ContextMeter: View {
    let tokens: Int?
    let scale: Int
    let tint: Color

    var body: some View {
        MeterBar(fraction: Double(tokens ?? 0) / Double(scale), tint: tint)
            .accessibilityElement()
            .accessibilityLabel("Context")
            .accessibilityValue(tokens.map { "\(Format.tokens($0)) tokens" } ?? "Unknown")
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
