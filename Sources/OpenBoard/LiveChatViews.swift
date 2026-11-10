import SwiftUI

extension Theme {
    /// OpenChamber's user message background, light and dark.
    static var userBubble: Color { isWarm ? warm(light: 0xE5EEE7, dark: 0x1D2A22) : coral.opacity(0.14) }

    static func toolSymbol(_ name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil.line"
        case "Grep", "Glob", "LS", "ToolSearch": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

/// What happened in the current turn(s), after the transcript history.
struct LiveItemsView: View {
    @ObservedObject var live: LiveChat
    @AppStorage(ChatStyle.key) private var chatStyle: ChatStyle = .terminal

    var body: some View {
        Group { items }
            // New steps arrive from below; a permission rises into view; the queue fills and empties.
            .animation(Motion.ease(), value: live.items.count)
            .animation(Motion.ease(0.22), value: live.pendingPermission?.id)
            .animation(Motion.ease(), value: live.queue.count)
    }

    @ViewBuilder
    private var items: some View {
        ForEach(live.items) { item in
            itemView(item).transition(Motion.arrive)
        }
        if let permission = live.pendingPermission {
            PermissionCard(permission: permission, live: live)
                .transition(Motion.attention)
        }
        queueAndStatus
    }

    @ViewBuilder
    private func itemView(_ item: LiveChat.Item) -> some View {
            switch item {
            case .user(_, let text) where chatStyle == .terminal:
                TerminalPrompt(text: text)
            case .text(_, let text) where chatStyle == .terminal:
                TerminalAnswer(text: AgentTeams.displayText(text))
            case .tool(let tool) where chatStyle == .terminal:
                TerminalToolLine(tool: tool)
            case .user(_, let text):
                HStack {
                    Spacer(minLength: 60)
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            case .text(_, let text):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(Theme.coral)
                        .padding(.top, 2)
                    MarkdownView(text: AgentTeams.displayText(text))
                    Spacer(minLength: 40)
                }
            case .thinking:
                ThinkingView(text: live.thinkingText)
            case .tool(let tool):
                ToolCard(tool: tool)
            case .notice(_, let text, let isError):
                Label(text, systemImage: isError ? "exclamationmark.triangle" : "stop.circle")
                    .font(.caption)
                    .foregroundStyle(isError ? Theme.danger : .secondary)
                    .padding(.leading, 26)
            }
    }

    @ViewBuilder
    private var queueAndStatus: some View {
        ForEach(live.queue) { queued in
            queuedRow(queued).transition(Motion.arrive)
        }
        statusRows
    }

    private func queuedRow(_ queued: LiveChat.Queued) -> some View {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(LiveChat.shown(queued.text, queued.attachments))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.userBubble.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    HStack(spacing: 6) {
                        Label("In coda", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                        Button("Togli") { live.removeFromQueue(queued.id) }.buttonStyle(.link).font(.caption2)
                    }
                }
            }
    }

    @ViewBuilder
    private var statusRows: some View {
        if let stalledSince = live.stalledSince {
            StalledTurnBanner(since: stalledSince, live: live)
        } else if live.isRunning && live.pendingPermission == nil {
            ActivityLine(live: live)
        }
    }
}

/// A tool call: icon, name and what it works on; click to see the output.
private struct ToolCard: View {
    let tool: LiveChat.Tool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Theme.toolSymbol(tool.name))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(tool.name)
                        .font(.callout.weight(.medium))
                    Text(tool.summary)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if !tool.isDone {
                        ProgressView().controlSize(.mini)
                    } else if tool.isError {
                        Image(systemName: "xmark.circle").foregroundStyle(Theme.danger)
                    } else {
                        Image(systemName: "checkmark").foregroundStyle(Theme.success)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let result = tool.result {
                ScrollView {
                    Text(result.isEmpty ? "(nessun output)" : String(result.prefix(20_000)))
                        .font(.caption.monospaced())
                        .foregroundStyle(tool.isError ? Theme.danger : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.leading, 26)
    }
}

private struct PermissionCard: View {
    let permission: LiveChat.Permission
    let live: LiveChat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised").foregroundStyle(Theme.warning)
                Text("Claude chiede il permesso").font(.headline)
            }
            HStack(spacing: 8) {
                Image(systemName: Theme.toolSymbol(permission.tool)).foregroundStyle(.secondary)
                Text(permission.tool).font(.callout.weight(.medium))
                Text(permission.summary)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let command = permission.input["command"] as? String, command.count > 60 {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Consenti") { live.answer(permission, allow: true) }
                    .keyboardShortcut(.defaultAction)
                if permission.canAllowEdits {
                    Button("Consenti modifiche da ora") { live.answer(permission, allow: true, allowEditsFromNow: true) }
                        .help("Da qui in avanti le modifiche ai file in questa chat non chiedono più")
                }
                Button("Nega", role: .destructive) { live.answer(permission, allow: false) }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
        .padding(.leading, 26)
    }
}

/// What Claude is doing right now, like the status line in the terminal:
/// "✻ Esegue `npm test`… (42s · ↓ 1,2k token · esc per interrompere)".
private struct ActivityLine: View {
    @ObservedObject var live: LiveChat

    var body: some View {
        HStack(spacing: 8) {
            Text("✻")
                .foregroundStyle(Theme.coral)
                .phaseAnimator(Motion.reduce ? [1.0] : [1.0, 0.35]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
            // The terminal's word for the turn, then what is running now when it says more.
            Text((live.spinnerVerb ?? live.activity ?? "Lavora") + "…")
                .font(.callout)
                .foregroundStyle(Theme.coral)
                .lineLimit(1)
                .fixedSize()
            if let step = live.activity, live.spinnerVerb != nil, step != "Pensa" {
                Text(step)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(step)
                    .transition(Motion.arrive)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(details(at: context.date))
                    .contentTransition(.numericText())
                    .animation(Motion.ease(0.25), value: context.date)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .animation(Motion.ease(0.2), value: live.activity)
    }

    private func details(at now: Date) -> String {
        var parts: [String] = []
        if let start = live.turnStartedAt { parts.append(StateMark.elapsed(start, now)) }
        if live.turnOutputTokens > 0 {
            let tokens = live.turnOutputTokens
            parts.append("↓ " + (tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)") + " token")
        }
        parts.append("esc per interrompere")
        return "(" + parts.joined(separator: " · ") + ")"
    }
}

/// Claude's reasoning while it thinks, in grey; the last lines only, it goes away when done.
private struct ThinkingView: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
        if !lines.isEmpty {
            Text(lines)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 26)
                .transition(.opacity)
        }
    }
}

/// A turn that has gone fully silent for a while (seen once with a tool call that never
/// returned): makes the hang visible instead of an endless, indistinguishable spinner.
private struct StalledTurnBanner: View {
    let since: Date
    let live: LiveChat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            Text("\(live.provider.title) non risponde da \(Text(since, style: .relative)): potrebbe essersi bloccato.")
                .font(.caption)
            Spacer()
            Button("Interrompi") { live.stop() }
                .controlSize(.small)
        }
        .padding(10)
        .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
        .padding(.leading, 26)
    }
}

/// Where you write to Claude: ↩ sends, ⇧↩ goes to a new line. Under it permission mode,
/// model, account, context and the 5-hour / 7-day usage of the account.
struct ChatComposer: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var live: LiveChat
    let blockedReason: String?
    var blockingSession: ActiveSession? = nil
    var onTakeOver: ((ActiveSession) -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var attachments: [URL] = []
    @State private var dropTargeted = false
    @State private var takingOver = false

    /// What is being typed. It lives here, not in the store: a change published to the whole app
    /// at every key redrew the chat list and made typing lag. The draft is saved quietly per chat
    /// (and across launches) until it is sent.
    @State private var text = ""
    @State private var loadedFor: String?
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { value in
            text = value
            store.setDraft(value, for: live.chatID)
        })
    }

    private let models: [(String, String?)] = [("Predefinito", nil), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blockedReason {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text(blockedReason).font(.caption)
                    Spacer()
                    if let blockingSession, let onTakeOver {
                        Button(takingOver ? "Chiusura…" : "Prendi qui il controllo") {
                            takingOver = true
                            onTakeOver(blockingSession)
                        }
                        .controlSize(.small)
                        .disabled(takingOver)
                        .help("Chiude il processo di \(blockingSession.accountName) (avviato \(blockingSession.startedAt.map { relative($0) } ?? "")) e sblocca la scrittura da qui")
                    }
                }
                .padding(10)
                .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
            }
            if !attachments.isEmpty { attachmentsRow }
            PlaceholderTextEditor(placeholder: live.isRunning ? "\(live.provider.title) sta lavorando…" : "Scrivi a \(live.provider.title)…", text: textBinding, padding: 0)
                    .frame(minHeight: 22, maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .disabled(blockedReason != nil)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        submit()
                        return .handled
                    }
            HStack(spacing: 8) {
                if live.provider == .codex {
                    ProviderBadge(provider: .codex)
                    Menu {
                        ForEach(LiveChat.CodexSandbox.allCases) { sandbox in
                            Button("\(sandbox.title) — \(sandbox.detail)") { live.sandbox = sandbox }
                        }
                    } label: {
                        Label(live.sandbox.title, systemImage: live.sandbox == .fullAccess ? "exclamationmark.shield" : "shield")
                    }
                    .fixedSize()
                    .help(live.sandbox.detail)
                } else {
                Menu {
                    ForEach(LiveChat.PermissionMode.allCases) { mode in
                        Button {
                            live.mode = mode
                        } label: {
                            Text("\(mode.title) — \(mode.detail)")
                        }
                    }
                } label: {
                    Label(live.mode.title, systemImage: live.mode == .bypassPermissions ? "exclamationmark.shield" : "shield")
                }
                .help(live.mode.detail)
                .fixedSize()
                Menu {
                    ForEach(models, id: \.0) { title, value in
                        Button(value == nil ? ModelNames.defaultLabel(for: live.account) : title) { live.model = value }
                    }
                } label: {
                    Label(live.model == nil ? ModelNames.defaultLabel(for: live.account)
                          : models.first { $0.1 == live.model }?.0 ?? live.model ?? "", systemImage: "cpu")
                }
                .fixedSize()
                Menu {
                    ForEach(store.accounts) { account in
                        Button(account.name) { live.account = account }
                    }
                } label: {
                    Label(live.account?.name ?? "Account", systemImage: "person.crop.circle")
                }
                .fixedSize()
                }
                Spacer()
                if let id = live.provider == .codex ? DeckStore.codexUsageKey : live.account?.id, let usage = store.planUsage[id] {
                    quotaView(usage)
                }
                if live.contextTokens > 0 {
                    ContextRing(tokens: live.contextTokens, size: 14)
                }
                Button { pickFiles() } label: { Image(systemName: "paperclip") }
                    .help("Allega file o immagini (puoi anche trascinarli qui)")
                Button { pasteImage() } label: { Image(systemName: "photo.on.rectangle") }
                    .help("Incolla l'immagine o i file copiati")
                if live.isRunning {
                    Button { live.stop() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Interrompi (Esc)")
                    .keyboardShortcut(.cancelAction)
                }
                Button { submit() } label: {
                    Image(systemName: live.isRunning ? "text.append" : "arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || blockedReason != nil)
                .help(live.isRunning ? "Metti in coda: parte quando finisce la risposta (↩)" : "Invia (↩)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .font(.caption)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(dropTargeted ? Theme.accent : focused ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: dropTargeted ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { attachments.append(url) } }
                }
            }
            return true
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .onChange(of: blockingSession?.pid) { _, _ in takingOver = false }
        .onAppear(perform: loadDraft)
        .onChange(of: live.chatID) { _, _ in loadDraft() }
    }

    private func loadDraft() {
        guard loadedFor != live.chatID else { return }
        loadedFor = live.chatID
        text = store.drafts[live.chatID] ?? ""
    }

    private func submit() {
        guard blockedReason == nil else { return }
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        text = ""
        store.setDraft("", for: live.chatID)
        let files = attachments
        attachments = []
        live.send(message, attachments: files)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { attachments += panel.urls }
    }

    /// An image on the clipboard (a screenshot copied with ⌃⇧⌘4) becomes a PNG attachment.
    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attachments += urls
            return
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let folder = ClaudePaths.home.appendingPathComponent(".openboard/attachments")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("incollata-\(Int(Date().timeIntervalSince1970)).png")
        if (try? png.write(to: url)) != nil { attachments.append(url) }
    }

    private var attachmentsRow: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(attachments, id: \.self) { url in
                HStack(spacing: 4) {
                    if LiveChat.imageType(url) != nil, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                    }
                    Text(url.lastPathComponent).font(.caption).lineLimit(1).frame(maxWidth: 160)
                    Button { attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    private func quotaView(_ usage: PlanUsage.Snapshot) -> some View {
        HStack(spacing: 6) {
            if let five = usage.session { Text("5h \(five.percent)%").foregroundStyle(five.percent > 80 ? Theme.danger : .secondary) }
            if let week = usage.week { Text("sett. \(week.percent)%").foregroundStyle(week.percent > 80 ? Theme.danger : .secondary) }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .help(usage.session?.resets.map { "Limite di 5 ore: si azzera \(PlanUsage.countdown(to: $0))" } ?? "Consumo del piano")
    }
}


// MARK: - Terminal style

/// Your message as in Claude Code: "> " and the text on a slightly lighter band.
struct TerminalPrompt: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(">").foregroundStyle(Term.dim)
            SelectableText(attributed: TerminalRender.plain(text))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Term.promptBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Claude's answer: a white dot, then the text.
struct TerminalAnswer: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("⏺").foregroundStyle(Term.text)
            SelectableText(attributed: TerminalRender.markdown(text))
                .padding(.trailing, 20)
        }
    }
}

/// A tool call as in Claude Code: "⏺ Bash(npm test)" and the first lines of its output under "⎿".
struct TerminalToolLine: View {
    let tool: LiveChat.Tool
    @State private var expanded = false

    private var dot: Color { !tool.isDone ? Term.claude : tool.isError ? Term.red : Term.green }

    private var output: [String] {
        let lines = (tool.result ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return expanded ? Array(lines.prefix(400)) : Array(lines.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RunningDot(color: dot, running: !tool.isDone)
                (Text(tool.name).bold() + Text(tool.summary.isEmpty ? "" : "(\(tool.summary))").foregroundColor(Term.dim))
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.ease()) { expanded.toggle() } }
            .help(expanded ? "Riduci l'output" : "Mostra tutto l'output")
            if tool.isDone {
                let lines = output
                let total = (tool.result ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(index == 0 ? "  ⎿" : "   ").foregroundStyle(Term.dim)
                            Text(line.isEmpty && index == 0 ? "(nessun output)" : line)
                                .foregroundStyle(tool.isError ? Term.red : Term.dim)
                                .lineLimit(expanded ? nil : 1)
                                .textSelection(.enabled)
                        }
                    }
                    if !expanded && total > 3 {
                        Text("     … +\(total - 3) righe (clic per vedere tutto)").foregroundStyle(Term.dim.opacity(0.7))
                            .onTapGesture { withAnimation(Motion.ease()) { expanded = true } }
                    }
                }
            }
        }
    }
}

/// The tool's dot: pulses while the tool runs, settles on green or red when it ends.
private struct RunningDot: View {
    let color: Color
    let running: Bool

    var body: some View {
        Text("⏺")
            .foregroundStyle(color)
            .phaseAnimator(running && !Motion.reduce ? [1.0, 0.3] : [1.0]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.7) }
            .animation(Motion.ease(), value: running)
    }
}
