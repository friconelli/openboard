import SwiftUI
import Combine
import AppKit

struct TranscriptView: View {
    @ObservedObject var store: DeckStore
    let chat: ChatSession
    let actions: ChatActions

    @State private var messages: [TranscriptMessage] = []
    @State private var truncated = false
    @State private var isLoading = true

    @State private var live: LiveChat?
    @State private var showFiles = false
    @State private var showGit = false
    @State private var showTerminal = false

    /// Chatting here while the same chat is open in a terminal would write it twice.
    private var blockedReason: String? {
        let others = store.activeSessions.filter { $0.sessionId == chat.id && $0.pid != live?.pid }
        return others.isEmpty ? nil : "Questa chat è aperta in un terminale: chiudila lì per scrivere da qui."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showTerminal {
                VSplitView {
                    chatArea
                        .frame(minHeight: 200)
                    TerminalDock(folder: chat.workingDirectory) { showTerminal = false }
                        .frame(minHeight: 120, idealHeight: 240)
                }
            } else {
                chatArea
            }
        }
        .background(Theme.pageBackground ?? Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showFiles) { ChangedFilesSheet(chat: chat) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTerminal)) { _ in showTerminal.toggle() }
        .sheet(isPresented: $showGit) { GitSheet(store: store, folder: chat.workingDirectory) }
        .onAppear {
            Notifier.shared.visibleChatID = chat.id
            store.unseenChats.remove(chat.id)
            if UserDefaults.standard.bool(forKey: "debugTerminal") { showTerminal = true }
            if UserDefaults.standard.string(forKey: "debugChat") == chat.id {
                if UserDefaults.standard.bool(forKey: "debugOpenFiles") { showFiles = true }
                if UserDefaults.standard.bool(forKey: "debugOpenGit") { showGit = true }
            }
            if UserDefaults.standard.string(forKey: "debugChat") == chat.id, let prompt = UserDefaults.standard.string(forKey: "debugFork") {
                Task {
                    if let id = await store.fork(chat, prompt: prompt, occurrence: 0, includingIt: false, title: "\(chat.displayTitle) · da capo", draft: prompt) {
                        NotificationCenter.default.post(name: .focusChat, object: id)
                    }
                }
            }
            live = store.liveChat(for: chat)
            // Tests and screenshots: `-debugChat <id> -debugSend "…" [-debugModel haiku] [-debugMode manual]`.
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "debugChat") == chat.id, let message = defaults.string(forKey: "debugSend"), let live,
               live.items.isEmpty {
                live.model = defaults.string(forKey: "debugModel")
                if let mode = defaults.string(forKey: "debugMode").flatMap(LiveChat.PermissionMode.init(rawValue:)) { live.mode = mode }
                let attach = defaults.string(forKey: "debugAttach").map { [URL(fileURLWithPath: $0)] } ?? []
                live.send(message, attachments: attach)
                if let second = defaults.string(forKey: "debugQueue") { live.send(second) }
            }
        }
        .task(id: "\(chat.id)|\(chat.sizeBytes)|\(chat.modifiedAt.timeIntervalSince1970)|\(live?.isRunning == true)") {
            // While Claude answers, the turn is shown live: the history stops where it started.
            let running = live?.isRunning == true
            let cutoff = running ? live?.historyCutoff : nil
            if running && !messages.isEmpty { return }
            isLoading = true
            let url = chat.fileURL
            let result = await Task.detached(priority: .userInitiated) { TranscriptReader.read(url, upTo: cutoff) }.value
            messages = result.messages
            truncated = result.truncated
            isLoading = false
            if !running { live?.clearFinishedTurns() }
        }
    }

    private var chatArea: some View {
        VStack(spacing: 0) {
            if isLoading && messages.isEmpty {
                ProgressView("Caricamento conversazione…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if truncated {
                                Label("Mostro solo gli ultimi \(messages.count) messaggi", systemImage: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            if messages.isEmpty && (live?.items.isEmpty ?? true) {
                                EmptyStateView(symbol: "text.bubble", title: "Conversazione vuota")
                            }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                MessageView(message: message)
                                    .id(message.id)
                                    .contextMenu { messageMenu(message, at: index) }
                            }
                            if let live {
                                LiveItemsView(live: live)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(20)
                    }
                    // Native bottom anchoring: with lazily measured rows, a scrollTo right after
                    // loading can land past the content and leave the view blank.
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: messages.count) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onReceive(live?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            if store.team(for: chat.id) != nil || store.worker(chatID: chat.id) != nil {
                TeamBar(store: store, chatID: chat.id)
            }
            if let live {
                ChatComposer(store: store, live: live, blockedReason: blockedReason)
            }
                }
    }

    /// The prompt a message belongs to (itself, or the last one before it) and how many times
    /// the same text came before, to find its turn in the transcript.
    private func anchor(for index: Int) -> (text: String, occurrence: Int)? {
        func isPrompt(_ message: TranscriptMessage) -> Bool {
            if case .user = message.kind { return true }
            if case .command = message.kind { return true }
            return false
        }
        guard let position = messages.prefix(index + 1).lastIndex(where: isPrompt) else { return nil }
        let text = messages[position].text
        let occurrence = messages.prefix(position).filter { isPrompt($0) && cleanPromptText($0.text).prefix(160) == cleanPromptText(text).prefix(160) }.count
        return (text, occurrence)
    }

    @ViewBuilder
    private func messageMenu(_ message: TranscriptMessage, at index: Int) -> some View {
        Button("Copia") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        }
        if !chat.isCodex, let anchor = anchor(for: index) {
            Divider()
            Button("Biforca fino a qui") {
                Task {
                    if let id = await store.fork(chat, prompt: anchor.text, occurrence: anchor.occurrence, includingIt: true,
                                                 title: "\(chat.displayTitle) · biforcata", draft: nil) {
                        NotificationCenter.default.post(name: .focusChat, object: id)
                    }
                }
            }
            .help("Nuova chat con la conversazione fino a questo punto; l'originale resta com'è")
            if case .user = message.kind {
                Button("Riparti da questo messaggio") {
                    Task {
                        if let id = await store.fork(chat, prompt: anchor.text, occurrence: anchor.occurrence, includingIt: false,
                                                     title: "\(chat.displayTitle) · da capo", draft: message.text) {
                            NotificationCenter.default.post(name: .focusChat, object: id)
                        }
                    }
                }
                .help("Nuova chat ferma prima di questo messaggio, con il testo pronto da modificare e rimandare")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chat.displayTitle)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if let description = store.description(for: chat) {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    FlowLayout(spacing: 8, lineSpacing: 4) {
                        Label(chat.workingDirectory.replacingOccurrences(of: ClaudePaths.home.path, with: "~"), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 380, alignment: .leading)
                            .help(chat.workingDirectory)
                        ContextBadge(context: store.context(for: chat)).fixedSize()
                        ForEach(store.accounts(for: chat)) { account in
                            AccountBadge(account: account, compact: true).fixedSize()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    FlowLayout(spacing: 10, lineSpacing: 2) {
                        Text("\(chat.promptCount) messaggi tuoi")
                        Text(formatBytes(chat.sizeBytes))
                        if let started = chat.startedAt {
                            Text("iniziata \(started.formatted(date: .abbreviated, time: .shortened))")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                ResumeButton(store: store, chat: chat, large: true)
            }

            FlowLayout(spacing: 8, lineSpacing: 6) {
                if chat.isCodex {
                    ProviderBadge(provider: .codex)
                } else {
                    ToolButton(title: "Dividi", symbol: "scissors") { actions.split(chat) }
                        .help("Dividi in più chat, una per argomento")
                    ToolButton(title: "Sposta", symbol: "folder.badge.gearshape") { actions.move([chat]) }
                        .help("Sposta in un'area di lavoro o in un progetto")
                }
                ToolButton(title: "Rinomina", symbol: "pencil") { actions.rename(chat) }
                ToolButton(title: "File", symbol: "doc.on.doc") { showFiles = true }
                    .help("File modificati in questa chat, con le differenze")
                ToolButton(title: "Terminale", symbol: "terminal") { showTerminal.toggle() }
                    .help("Terminale nella cartella della chat (⌘J)")
                ToolButton(title: "Git", symbol: "arrow.triangle.branch") { showGit = true }
                    .help("Stato, differenze, commit e push della cartella della chat")
                Menu {
                    Menu("Contesto") {
                        ForEach(store.config.contexts, id: \.self) { context in
                            Button(context) { store.setContext(context, for: [chat]) }
                        }
                        Divider()
                        Button("Automatico (dalla cartella)") { store.setContext(nil, for: [chat]) }
                    }
                    if !chat.isCodex {
                        Button("Snellisci…") { actions.slim([chat]) }
                    }
                    Button("Esporta in Markdown…") { MarkdownExport.save(chat) }
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([chat.fileURL]) }
                    Button("Copia ID sessione") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chat.id, forType: .string)
                    }
                    Divider()
                    Button("Sposta nel Cestino…", role: .destructive) { actions.trash([chat]) }
                } label: {
                    Label("Altro", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .secondaryButton()
                .fixedSize()
            }
            .controlSize(.small)

            ChatHealthView(store: store, chat: chat, actions: actions)
        }
        .padding(16)
    }
}

private struct MessageView: View {
    let message: TranscriptMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.coral.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Theme.coral)
                    .padding(.top, 2)
                MarkdownView(text: AgentTeams.displayText(message.text))
                Spacer(minLength: 40)
            }
        case .command:
            Label(message.text, systemImage: "command")
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .tools(let tools):
            ToolGroupView(tools: tools)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ToolGroupView: View {
    let tools: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(tools.count == 1 ? tools[0] : "\(tools.count) strumenti usati")
                        .lineLimit(1)
                    if tools.count > 1 {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded && tools.count > 1 {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    Text(tool)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.leading, 26)
    }
}
