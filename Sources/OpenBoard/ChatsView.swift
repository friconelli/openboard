import SwiftUI
import AppKit

/// List state shared by the chat list (left column) and the open chat (centre).
@MainActor
final class ChatsUI: ObservableObject {
    @Published var selection: Set<String> = []
    @Published var query = ""
    @Published var searchContent = false
    /// The one project shown when working on it alone (its folder), kept across launches.
    @Published var focusedProject: String? = UserDefaults.standard.string(forKey: "sidebarFocusedProject") {
        didSet { UserDefaults.standard.set(focusedProject, forKey: "sidebarFocusedProject") }
    }
    @Published var collapsedProjects: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebarCollapsedProjects") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedProjects), forKey: "sidebarCollapsedProjects") }
    }
    /// Orchestrators opened or closed by hand (otherwise they open while their agents work).
    @Published var expanded: Set<String> = []
    @Published var collapsedTeams: Set<String> = []
    /// Closed by hand during a search (everything opens to show the results); cleared with the search.
    @Published var searchCollapsed: Set<String> = []
    /// Rows shown per project after “Mostra altre”.
    @Published var shown: [String: Int] = [:]

    func toggleProject(_ path: String) {
        if !query.isEmpty {
            if searchCollapsed.contains(path) { searchCollapsed.remove(path) } else { searchCollapsed.insert(path) }
            return
        }
        if collapsedProjects.contains(path) { collapsedProjects.remove(path) } else { collapsedProjects.insert(path); shown[path] = nil }
    }
    @Published var accountFilter: String?
    @Published var renameTarget: ChatSession?
    @Published var mergeTargets: [ChatSession] = []
    @Published var trashTargets: [ChatSession] = []
    @Published var moveTargets: [ChatSession] = []
    @Published var splitTarget: ChatSession?
    @Published var slimTargets: [ChatSession] = []
}

struct ChatsView: View {
    enum Mode { case list, detail }

    @ObservedObject var store: DeckStore
    let scope: ChatScope
    @Binding var focusedChatID: String?
    @ObservedObject var ui: ChatsUI
    var mode: Mode = .list



    /// Folders with chats, for the project menu: most recent first.
    private var projects: [(path: String, count: Int)] {
        Dictionary(grouping: store.visibleChats, by: \.workingDirectory)
            .map { (path: $0.key, count: $0.value.count, last: $0.value.map(\.modifiedAt).max() ?? .distantPast) }
            .sorted { $0.last > $1.last }
            .map { ($0.path, $0.count) }
    }

    var filtered: [ChatSession] {
        (scope == .archived ? store.archivedChats : store.visibleChats).filter { chat in
            switch scope {
            case .all, .archived: break
            case .working: if !store.isWorking(chat) { return false }
            case .smart(let filter): if !store.matches(chat, filter) { return false }
            case .context(let context): if store.context(for: chat) != context { return false }
            case .unassigned: if store.context(for: chat) != nil { return false }
            }
            if let accountFilter = ui.accountFilter, !(store.sessionAccounts[chat.id]?.contains(accountFilter) ?? false) { return false }
            guard !ui.query.isEmpty else { return true }
            if ui.searchContent { return store.contentMatches?.contains(chat.id) ?? true }
            return chat.displayTitle.localizedCaseInsensitiveContains(ui.query)
                || (chat.preview?.localizedCaseInsensitiveContains(ui.query) ?? false)
                || (store.description(for: chat)?.localizedCaseInsensitiveContains(ui.query) ?? false)
                || chat.projectName.localizedCaseInsensitiveContains(ui.query)
                || chat.id.hasPrefix(ui.query)
        }
    }

    private var selectedChats: [ChatSession] {
        store.chats.filter { ui.selection.contains($0.id) }
    }

    var body: some View {
        if mode == .detail {
            detailPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(selectedChats.count == 1 ? selectedChats[0].displayTitle : scopeTitle)
                .toolbar { toolbar }
        } else {
            listBody
        }
    }

    /// The list with everything it owns: dialogs, focus handling, content search.
    private var listBody: some View {
        listPane
        .onChange(of: focusedChatID) { _, id in
            guard let id else { return }
            ui.selection = [id]
            // Screenshots/tests: `-debugOpenSlim YES` opens the slim sheet for the focused chat.
            if UserDefaults.standard.bool(forKey: "debugOpenSlim"), let chat = store.chats.first(where: { $0.id == id }) {
                ui.slimTargets = [chat]
            }
            if UserDefaults.standard.bool(forKey: "debugOpenSplit"), let chat = store.chats.first(where: { $0.id == id }) {
                ui.splitTarget = chat
            }
            if UserDefaults.standard.bool(forKey: "debugOpenMove"), let chat = store.chats.first(where: { $0.id == id }) {
                ui.moveTargets = [chat]
            }
            // A chat outside the project in focus brings back every project.
            if let focus = ui.focusedProject, let chat = store.chats.first(where: { $0.id == id }),
               chat.workingDirectory != focus, store.workerParents[id].flatMap({ parent in store.chats.first { $0.id == parent } })?.workingDirectory != focus {
                ui.focusedProject = nil
            }
            ui.accountFilter = nil
            ui.query = ""
            focusedChatID = nil
        }
        .onChange(of: ui.query) { _, value in
            if value.isEmpty { ui.searchCollapsed.removeAll() }
            if ui.searchContent { store.searchContent(value) }
        }
        .onChange(of: ui.searchContent) { _, enabled in
            store.searchContent(enabled ? ui.query : "")
        }
        .sheet(isPresented: Binding(get: { !ui.moveTargets.isEmpty }, set: { if !$0 { ui.moveTargets = [] } })) {
            FolderPickerSheet(
                store: store,
                title: ui.moveTargets.count == 1 ? "Sposta “\(ui.moveTargets[0].displayTitle)”" : "Sposta \(ui.moveTargets.count) chat",
                message: "La chat verrà registrata nella nuova cartella: da lì la ritrovi con /resume e Claude lavora in quella cartella.",
                excluding: Set(ui.moveTargets.map(\.workingDirectory))
            ) { folder in
                let targets = ui.moveTargets
                ui.selection.subtract(targets.map(\.id))
                store.move(targets, to: folder)
            }
        }
        .sheet(item: $ui.renameTarget) { chat in
            RenameSheet(chat: chat) { title in
                store.rename(chat, to: title)
            }
        }
        .sheet(isPresented: Binding(get: { !ui.slimTargets.isEmpty }, set: { if !$0 { ui.slimTargets = [] } })) {
            SlimSheet(store: store, chats: ui.slimTargets)
        }
        .sheet(item: $ui.splitTarget) { chat in
            SplitSheet(store: store, chat: chat) { created in
                ui.selection = Set(created.map(\.id))
            }
        }
        .sheet(isPresented: Binding(get: { !ui.mergeTargets.isEmpty }, set: { if !$0 { ui.mergeTargets = [] } })) {
            MergeSheet(store: store, chats: ui.mergeTargets) { newID in
                if let newID { ui.selection = [newID] }
            }
        }
        .alert(
            "Spostare \(ui.trashTargets.count) chat nel Cestino?",
            isPresented: Binding(get: { !ui.trashTargets.isEmpty }, set: { if !$0 { ui.trashTargets = [] } })
        ) {
            Button("Sposta nel Cestino", role: .destructive) {
                store.trash(ui.trashTargets)
                ui.selection.subtract(ui.trashTargets.map(\.id))
                ui.trashTargets = []
            }
            Button("Annulla", role: .cancel) { ui.trashTargets = [] }
        } message: {
            Text("Le potrai recuperare dal Cestino finché non lo svuoti. Spariranno da /resume per tutti gli account.")
        }
    }

    // MARK: - List

    private var archiveBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text("Archivia da sole le chat ferme da")
                Picker("", selection: Binding(get: { store.config.autoArchiveDays ?? 0 },
                                              set: { store.setAutoArchive(days: $0 == 0 ? nil : $0) })) {
                    Text("mai").tag(0)
                    Text("14 giorni").tag(14)
                    Text("30 giorni").tag(30)
                    Text("60 giorni").tag(60)
                    Text("90 giorni").tag(90)
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Non archivia mai le chat in lavorazione o aperte. Le chat archiviate restano su disco e in /resume: tasto destro → Ripristina.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(12)
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if scope == .archived { archiveBanner; Divider() }
            filterBar
            Divider()
            if filtered.isEmpty && !store.isIndexing {
                EmptyStateView(
                    symbol: "bubble.left.and.bubble.right",
                    title: ui.query.isEmpty ? "Nessuna chat" : "Nessun risultato",
                    message: ui.query.isEmpty ? nil : "Prova a cercare anche nel contenuto delle conversazioni."
                )
            } else {
                sidebarList
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(ui.searchContent ? "Cerca nel contenuto delle chat" : "Cerca titolo, progetto o ID", text: $ui.query)
                    .textFieldStyle(.plain)
                if store.isSearchingContent {
                    ProgressView().controlSize(.small)
                }
                if !ui.query.isEmpty {
                    Button { ui.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 6) {
                Toggle(isOn: $ui.searchContent) {
                    Image(systemName: "text.magnifyingglass")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Cerca anche nel contenuto delle conversazioni")

                // Short labels: this row must fit the narrowest column, or it widens the
                // whole column and eats the margins.
                Menu {
                    Button("Tutti i progetti") { ui.focusedProject = nil }
                    Divider()
                    ForEach(projects.prefix(40), id: \.path) { project in
                        Button("\(URL(fileURLWithPath: project.path).lastPathComponent) (\(project.count))") { ui.focusedProject = project.path }
                    }
                } label: {
                    Label(ui.focusedProject.map { short(URL(fileURLWithPath: $0).lastPathComponent) } ?? "Progetti", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Lavora su un solo progetto: la lista mostra solo quello, con i suoi agenti")

                Menu {
                    Button("Tutti gli account") { ui.accountFilter = nil }
                    Divider()
                    ForEach(store.accounts.filter { !$0.isDefault }) { account in
                        Button(account.name) { ui.accountFilter = account.id }
                    }
                } label: {
                    Label(ui.accountFilter.flatMap { store.account(id: $0)?.name }.map(short) ?? "Account", systemImage: "person.crop.circle")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Filtra per account")

                Spacer(minLength: 0)
                Text("\(filtered.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(12)
    }

    private func short(_ name: String) -> String {
        name.count > 12 ? name.prefix(11) + "…" : name
    }

    private var actions: ChatActions {
        ChatActions(
            rename: { ui.renameTarget = $0 },
            split: { ui.splitTarget = $0 },
            slim: { ui.slimTargets = $0 },
            move: { ui.moveTargets = $0 },
            merge: { ui.mergeTargets = $0 },
            trash: { ui.trashTargets = $0 }
        )
    }

    @ViewBuilder
    func contextMenu(for chat: ChatSession) -> some View {
        let targets = ui.selection.contains(chat.id) ? selectedChats : [chat]
        if targets.count == 1 {
            Menu("Riprendi in \(Launcher.terminalName) con…") {
                ForEach(store.accounts) { account in
                    Button(account.name) { store.resume(chat, with: account) }
                }
            }
            Button("Rinomina…") { ui.renameTarget = chat }
            if !chat.isCodex {
                Button("Suggerisci titolo con Claude") {
                    Task { await store.suggestTitle(for: chat, account: store.preferredAccount) }
                }
                .disabled(chat.promptCount == 0)
                Button("Dividi in argomenti…") { ui.splitTarget = chat }
                Button("Rigenera descrizione") { store.refreshDescriptions(force: [chat]) }
            }
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([chat.fileURL]) }
            Button("Copia ID sessione") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.id, forType: .string)
            }
        } else if !targets.contains(where: \.isCodex) {
            Button("Unisci \(targets.count) chat…") { ui.mergeTargets = targets }
        }
        // Slimming is offered where it pays (the lightbulb, Consigli), not on every chat.
        if !targets.contains(where: \.isCodex), targets.contains(where: { store.slimEntry(for: $0)?.isWorthIt ?? false }) {
            Button(targets.count == 1 ? "Snellisci…" : "Snellisci \(targets.count) chat…") { ui.slimTargets = targets }
        }
        Divider()
        if targets.allSatisfy(store.isPinned) {
            Button("Togli dalle fissate") { store.setPinned(false, for: targets) }
        } else {
            Button("Fissa in alto") { store.setPinned(true, for: targets) }
        }
        if targets.count == 1, !chat.isCodex {
            if let team = store.team(for: chat.id) {
                if team.isActive { Button("Ferma tutti gli agenti") { store.stopTeam(chat.id) } }
            } else if store.worker(chatID: chat.id) == nil {
                Button("Rendi orchestratore") { store.makeOrchestrator(chat) }
            }
        }
        Button("Lavora solo su \(URL(fileURLWithPath: chat.workingDirectory).lastPathComponent)") {
            ui.focusedProject = chat.workingDirectory
        }
        if targets.allSatisfy(store.isWorking) {
            Button("Togli da In lavorazione") { store.setWorking(false, for: targets) }
        } else {
            Button("Segna in lavorazione") { store.setWorking(true, for: targets) }
        }
        if !targets.contains(where: \.isCodex) {
            Button("Sposta in…") { ui.moveTargets = targets }
        }
        Menu("Contesto") { contextItems(for: targets) }
        if targets.allSatisfy(store.isArchived) {
            Button("Ripristina dall'archivio") { store.unarchive(targets) }
        } else {
            Button("Archivia") { store.archive(targets); ui.selection.subtract(targets.map(\.id)) }
        }
        Divider()
        Button("Sposta nel Cestino", role: .destructive) { ui.trashTargets = targets }
    }

    @ViewBuilder
    private func contextItems(for targets: [ChatSession]) -> some View {
        ForEach(store.config.contexts, id: \.self) { context in
            Button(context) { store.setContext(context, for: targets) }
        }
        Divider()
        Button("Automatico (dalla cartella)") { store.setContext(nil, for: targets) }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "Tutte le chat"
        case .archived: return "Archivio"
        case .working: return "In lavorazione"
        case .smart(let filter): return filter.title
        case .context(let context): return context
        case .unassigned: return "Da assegnare"
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if selectedChats.count == 1, let chat = selectedChats.first {
            TranscriptView(store: store, chat: chat, actions: actions)
                .id(chat.id)
        } else if selectedChats.count > 1 {
            MultiSelectionView(store: store, chats: selectedChats, actions: actions)
        } else {
            ToolsGuideView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                NotificationCenter.default.post(name: .newChat, object: nil)
            } label: {
                Label("Nuova chat", systemImage: "plus.bubble")
            }
            .help("Nuova chat (⌘N): cartella, account, modello e primo messaggio")
        }
        ToolbarItem {
            Button {
                store.reloadAll()
            } label: {
                Label("Aggiorna", systemImage: "arrow.clockwise")
            }
            .help("Aggiorna")
        }
    }

    private func newChat(with account: ClaudeAccount) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Avvia Claude qui"
        panel.directoryURL = ClaudePaths.home.appendingPathComponent("projects")
        if panel.runModal() == .OK, let url = panel.url {
            store.newChat(in: url.path, with: account)
        }
    }
}

// MARK: - Row

private struct ChatRow: View {
    let chat: ChatSession
    let accounts: [ClaudeAccount]
    let context: String?
    let showContext: Bool
    let isActive: Bool
    let hasAdvice: Bool
    let description: String?
    let isWorking: Bool
    let contextTokens: Int
    @AppStorage(RowDensity.key) private var density: RowDensity = .comfortable

    var body: some View {
        if density == .compact { compactBody } else { comfortableBody }
    }

    /// One line per chat: status, title, folder, context ring and age.
    private var compactBody: some View {
        HStack(spacing: 8) {
            Group {
                if isActive {
                    StatusDot(busy: false)
                } else if isWorking {
                    Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.orange)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            if chat.isCodex { ProviderBadge(provider: .codex, iconOnly: true) }
            Text(chat.displayTitle)
                .lineLimit(1)
                .layoutPriority(1)
                .help(description ?? chat.preview ?? "")
            if hasAdvice {
                Image(systemName: "lightbulb.fill").font(.caption2).foregroundStyle(.yellow)
            }
            Spacer(minLength: 6)
            // The folder only when it fits whole: no stray letter next to a long title.
            ViewThatFits(in: .horizontal) {
                Text(chat.projectName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            if contextTokens > 0 { ContextRing(tokens: contextTokens, size: 14) }
            Text(relative(chat.modifiedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var comfortableBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isActive {
                    StatusDot(busy: false)
                        .help("Aperta in una sessione in corso")
                }
                if isWorking {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("In lavorazione")
                }
                Text(chat.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if hasAdvice {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .help("Chat pesante: aprila per vedere come alleggerirla")
                }
                Spacer(minLength: 4)
                Text(relative(chat.modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let preview = chat.preview, chat.title != nil {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 6) {
                // Badges wrap as whole pills in a narrow list instead of breaking letter by letter.
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    Label(chat.projectName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if showContext || context == nil {
                        ContextBadge(context: context).fixedSize()
                    }
                    if chat.isCodex {
                        ProviderBadge(provider: .codex).fixedSize()
                    } else {
                        ForEach(accounts) { account in
                            AccountBadge(account: account, compact: true).fixedSize()
                        }
                    }
                }
                Spacer(minLength: 4)
                if contextTokens > 0 {
                    ContextRing(tokens: contextTokens)
                    Text(ContextMeter.format(contextTokens))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    Text(formatBytes(chat.sizeBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Multi selection

private struct MultiSelectionView: View {
    @ObservedObject var store: DeckStore
    let chats: [ChatSession]
    let actions: ChatActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: "square.stack.fill",
                    tint: Theme.coral,
                    title: "\(chats.count) chat selezionate",
                    subtitle: "\(formatBytes(chats.reduce(0) { $0 + $1.sizeBytes })) in tutto. Scegli cosa farne:"
                ) { EmptyView() }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    if !chats.contains(where: \.isCodex) {
                        Button { actions.merge(chats) } label: { Label("Unisci", systemImage: "arrow.triangle.merge") }
                            .prominentButton()
                            .tint(Theme.coral)
                            .help("Unisci in una sola chat")
                        ToolButton(title: "Snellisci", symbol: "arrow.down.right.and.arrow.up.left") { actions.slim(chats) }
                        ToolButton(title: "Sposta", symbol: "folder.badge.gearshape") { actions.move(chats) }
                    }
                    Menu {
                        ForEach(store.config.contexts, id: \.self) { context in
                            Button(context) { store.setContext(context, for: chats) }
                        }
                        Divider()
                        Button("Automatico (dalla cartella)") { store.setContext(nil, for: chats) }
                    } label: {
                        Label("Contesto", systemImage: "tag")
                    }
                    .menuStyle(.button)
                    .secondaryButton()
                    .fixedSize()
                    ToolButton(title: "Cestino", symbol: "trash", role: .destructive) { actions.trash(chats) }
                }
                .controlSize(.large)

                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(chats.sorted { ($0.startedAt ?? $0.modifiedAt) < ($1.startedAt ?? $1.modifiedAt) }) { chat in
                            HStack {
                                Text(chat.displayTitle).lineLimit(1)
                                Spacer()
                                Text(chat.projectName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formatBytes(chat.sizeBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .padding(10)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Sheets

private struct RenameSheet: View {
    let chat: ChatSession
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rinomina chat")
                .font(.title3.bold())
            TextField("Titolo", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Il nuovo titolo compare anche in /resume di Claude Code, per tutti gli account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rinomina", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { title = chat.title ?? "" }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

private struct MergeSheet: View {
    @ObservedObject var store: DeckStore
    let chats: [ChatSession]
    let onDone: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [ChatSession] = []
    @State private var title = ""
    @State private var targetID = ""
    @State private var openAfter = true
    @State private var accountID: String?
    @State private var isMerging = false

    private var target: ChatSession? { ordered.first { $0.id == targetID } ?? ordered.first }
    /// Context each chat reloads on resume, as Claude Code last measured it; the merged chat holds them all.
    private var contextTotal: Int { chats.reduce(0) { $0 + store.contextTokens(for: $1) } }
    private var projectChoices: [ChatSession] {
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0.projectDir).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.triangle.merge", tint: Theme.coral, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unisci \(chats.count) chat")
                        .font(.title3.bold())
                    Text("Le conversazioni diventano una sola, nell'ordine qui sotto.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Ordine")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, chat in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 20, height: 20)
                            .background(Theme.coral.opacity(0.15), in: Circle())
                            .foregroundStyle(Theme.coral)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.displayTitle).lineLimit(1)
                            Text("\(chat.projectName) · \(relative(chat.startedAt ?? chat.modifiedAt)) · \(formatBytes(chat.sizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == ordered.count - 1)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            Form {
                TextField("Nome della chat unita", text: $title)
                if projectChoices.count > 1 {
                    Picker("Salva nel progetto", selection: $targetID) {
                        ForEach(projectChoices) { chat in
                            Text(chat.projectName).tag(chat.id)
                        }
                    }
                }
                HStack {
                    Toggle("Riapri subito in \(Launcher.terminalName) con", isOn: $openAfter)
                    Picker("", selection: $accountID) {
                        ForEach(store.accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!openAfter)
                }
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 6) {
                Label("Dopo l'unione le \(chats.count) chat originali vanno nel Cestino: resta solo quella unita.", systemImage: "trash")
                Label("Viene ripresa la conversazione effettiva di ogni chat; se una era compattata entra il suo riassunto. I messaggi ripetuti tra chat derivate compaiono una volta sola.", systemImage: "info.circle")
                if contextTotal > 0 {
                    HStack(spacing: 6) {
                        Text("Contesto della chat unita, circa")
                        ContextMeter(tokens: contextTotal)
                    }
                    if contextTotal > 160_000 {
                        Label(contextTotal > 800_000
                              ? "Oltre l'80% anche di una finestra da 1M: alla ripresa Claude Code compatterà subito la conversazione. Conviene prima snellire le chat più pesanti."
                              : "Con un modello da 200k alla ripresa Claude Code compatterà subito la conversazione (con uno da 1M no). Snellire prima le chat più pesanti aiuta comunque.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    merge()
                } label: {
                    if isMerging { ProgressView().controlSize(.small) } else { Text("Unisci") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isMerging || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            ordered = chats.sorted { ($0.startedAt ?? $0.modifiedAt) < ($1.startedAt ?? $1.modifiedAt) }
            targetID = ordered.first?.id ?? ""
            title = ordered.first(where: { $0.isCustomTitle })?.title
                ?? ordered.map { String($0.displayTitle.prefix(30)) }.joined(separator: " + ")
            accountID = store.preferredAccount?.id
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard ordered.indices.contains(destination) else { return }
        ordered.swapAt(index, destination)
    }

    private func merge() {
        guard let target else { return }
        isMerging = true
        let name = title.trimmingCharacters(in: .whitespaces)
        Task {
            let merged = await store.merge(ordered, title: name, target: target)
            isMerging = false
            guard let merged else { return }
            if openAfter, let account = accountID.flatMap(store.account(id:)) {
                store.resume(merged, with: account)
            }
            onDone(merged.id)
            dismiss()
        }
    }
}
