import SwiftUI

/// Ready-made filters shown as sidebar sections (OpenChamber's “smart sections”), hidden when empty.
enum SmartFilter: String, CaseIterable, Hashable, Identifiable {
    case open, today, week, idle, heavy, untitled, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Aperte adesso"
        case .today: return "Oggi"
        case .week: return "Ultimi 7 giorni"
        case .idle: return "Ferme da 3+ giorni"
        case .heavy: return "Pesanti"
        case .untitled: return "Senza titolo"
        case .codex: return "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "bolt.horizontal.fill"
        case .today: return "sun.max.fill"
        case .week: return "calendar"
        case .idle: return "hourglass"
        case .heavy: return "scalemass.fill"
        case .untitled: return "textformat"
        case .codex: return Provider.codex.symbol
        }
    }

    var tint: Color {
        switch self {
        case .open: return .green
        case .today: return .yellow
        case .week: return .blue
        case .idle: return .gray
        case .heavy: return .red
        case .untitled: return .purple
        case .codex: return .blue
        }
    }

    var hint: String {
        switch self {
        case .open: return "Chat aperte in una sessione in corso"
        case .today: return "Chat toccate oggi"
        case .week: return "Chat toccate negli ultimi 7 giorni"
        case .idle: return "In lavorazione ma senza attività da più di 3 giorni"
        case .heavy: return "Chat che conviene snellire o dividere"
        case .untitled: return "Chat senza un titolo tuo: dal menu contestuale Claude può suggerirne uno"
        case .codex: return "Conversazioni di Codex"
        }
    }
}

enum ChatScope: Hashable {
    case all
    case working
    case smart(SmartFilter)
    case context(String)
    case unassigned
}

enum DeckSection: Hashable {
    case overview
    case chats(ChatScope)
    case areas
    case active
    case accounts
    case memory
    case insights
    case compose

    /// For launching on a given page (`-debugSection insights`), used for screenshots.
    init?(debugName: String) {
        switch debugName {
        case "compose": self = .compose
        case "overview": self = .overview
        case "insights": self = .insights
        case "areas": self = .areas
        case "active": self = .active
        case "accounts": self = .accounts
        case "memory": self = .memory
        case "chats": self = .chats(.all)
        case "working": self = .chats(.working)
        default: return nil
        }
    }
}

struct ContentView: View {
    @StateObject private var store = DeckStore()
    @ObservedObject private var updater = Updater.shared
    @State private var showOnboarding = false
    @State private var section: DeckSection? = .chats(.all)
    @State private var focusedChatID: String?
    @State private var showPalette = false
    @State private var showNewChat = false
    @AppStorage(Theme.appearanceKey) private var appearance: Theme.Appearance = .system
    @AppStorage(Theme.Mode.key) private var mode: Theme.Mode = .auto

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .background(Theme.pageBackground ?? .clear)
        }
        // Theme colours are read statically: rebuild the views when the theme changes.
        .id(appearance)
        .preferredColorScheme(mode.scheme)
        .tint(Theme.accent)
        .overlay(alignment: .bottom) {
            if let action = store.pendingUndo {
                UndoToast(action: action, onUndo: { store.undo() }, onClose: {
                    if store.pendingUndo?.id == action.id { store.pendingUndo = nil }
                })
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.pendingUndo?.id)
        .sheet(isPresented: $showPalette) {
            CommandPalette(store: store, onSection: { section = $0 }) { id in
                focusedChatID = id
                section = .chats(.all)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPalette)) { _ in showPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in showNewChat = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusChat)) { note in
            if let id = note.object as? String { section = .chats(.all); focusedChatID = id }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet(store: store) { id in
                section = .chats(.all)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusedChatID = id }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPlanUsage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.closeAllLiveChats()
            TerminalStore.shared.closeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSection)) { note in
            if let name = note.object as? String, let target = DeckSection(debugName: name) { section = target }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSmartFilters)) { _ in
            for filter in SmartFilter.allCases { store.setSmartFilter(filter, hidden: false) }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(store: store) { showOnboarding = false }
                .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in showOnboarding = true }
        .onAppear {
            LiveChat.closeLeftovers()
            Notifier.shared.start()
            Notifier.shared.onOpenChat = { id in
                section = .chats(.all)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusedChatID = id }
            }
            store.start()
            store.startPlanUsageMonitor()
            showOnboarding = store.config.onboardingDone == false || UserDefaults.standard.bool(forKey: "debugOnboarding")
            updater.checkIfDue()
            if UserDefaults.standard.bool(forKey: "debugInstallUpdate") {
                Task { await updater.check(); await updater.install() }
            }
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "debugSection"), let debug = DeckSection(debugName: name) { section = debug }
            if defaults.bool(forKey: "debugNewChat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showNewChat = true }
            }
            if defaults.bool(forKey: "debugPalette") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showPalette = true }
            }
            if let id = defaults.string(forKey: "debugChat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { focusedChatID = id }
            }
        }
        .alert(
            "Aprire le chat direttamente in \(Launcher.terminalName)?",
            isPresented: Binding(get: { store.pendingLaunch != nil }, set: { if !$0 { store.pendingLaunch = nil } }),
            presenting: store.pendingLaunch
        ) { launch in
            Button("Attiva e apri") { store.enableDirectLaunchAndRun(launch) }
                .keyboardShortcut(.defaultAction)
            Button("Solo questa volta: copia il comando") {
                Launcher.openTabCopyingCommand(launch.command, directory: launch.directory)
            }
            Button("Annulla", role: .cancel) {}
        } message: { launch in
            Text("Per avviare Claude nella nuova scheda l'app aggiunge a ~/.zshrc un piccolo blocco “OpenBoard” che esegue il comando preparato per quella cartella (copia di sicurezza in ~/.openboard/zshrc.backup). Si disattiva da Account.\n\n\(launch.command)")
        }
        .alert(
            "Operazione non riuscita",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
            List(selection: $section) {
                row("Nuova chat guidata", symbol: "sparkles", tint: Theme.coral)
                    .tag(DeckSection.compose)
                let attention = store.activeSessions.filter { $0.status != "busy" }.count
                row("Panoramica", symbol: "square.grid.2x2.fill", tint: .teal, count: attention > 0 ? attention : nil,
                    highlight: attention > 0 ? .green : nil)
                    .tag(DeckSection.overview)
                    .help("Cosa ti aspetta: sessioni in attesa, chat ferme, chat da ricollegare o alleggerire")

                Section("Chat") {
                    let working = store.workingChats.count
                    row("In lavorazione", symbol: "flag.fill", tint: .orange, count: working, highlight: working > 0 ? .orange : nil)
                        .tag(DeckSection.chats(.working))
                        .help("Le chat che stai seguendo adesso: le aggiungi e le togli tu (menu contestuale o dettaglio)")
                    row("Tutte", symbol: "bubble.left.and.bubble.right.fill", tint: Theme.coral, count: store.chats.count)
                        .tag(DeckSection.chats(.all))
                    ForEach(store.config.contexts, id: \.self) { context in
                        row(context, symbol: Theme.symbol(forContext: context), tint: Theme.color(forContext: context),
                            count: store.chats.filter { store.context(for: $0) == context }.count)
                            .tag(DeckSection.chats(.context(context)))
                    }
                    let unassigned = store.chats.filter { store.context(for: $0) == nil }.count
                    row("Da assegnare", symbol: "tray.fill", tint: .gray, count: unassigned, highlight: unassigned > 0 ? .gray : nil)
                        .tag(DeckSection.chats(.unassigned))
                }
                let smart = SmartFilter.allCases.filter { !(store.config.hiddenSmartFilters ?? []).contains($0.rawValue) }
                    .map { filter in (filter, store.chats.filter { store.matches($0, filter) }.count) }
                    .filter { $0.1 > 0 }
                if !smart.isEmpty {
                    Section("Filtri") {
                        ForEach(smart, id: \.0) { filter, count in
                            row(filter.title, symbol: filter.symbol, tint: filter.tint, count: count)
                                .tag(DeckSection.chats(.smart(filter)))
                                .help(filter.hint)
                                .contextMenu {
                                    Button("Nascondi “\(filter.title)”") { store.setSmartFilter(filter, hidden: true) }
                                }
                        }
                    }
                }
                Section("Organizza") {
                    let advice = store.chats.filter { store.hasAdvice(for: $0) }.count
                    row("Consigli", symbol: "lightbulb.fill", tint: .yellow, count: advice, highlight: advice > 0 ? .orange : nil)
                        .tag(DeckSection.insights)
                        .help("Chat da snellire o dividere e modello giusto per ogni lavoro")
                    row("Aree di lavoro", symbol: "folder.fill", tint: .orange)
                        .tag(DeckSection.areas)
                        .help("Cartelle da cui far partire le chat, per contesto")
                    row("Memoria", symbol: "brain.head.profile", tint: .purple, count: store.memoryFiles.count)
                        .tag(DeckSection.memory)
                }
                Section("Sistema") {
                    row("Sessioni attive", symbol: "bolt.horizontal.fill", tint: .green, count: store.activeSessions.count,
                        highlight: store.activeSessions.isEmpty ? nil : .green)
                        .tag(DeckSection.active)
                    row("Account", symbol: "person.2.fill", tint: .blue, count: store.accounts.filter { !$0.isDefault }.count)
                        .tag(DeckSection.accounts)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                PlanUsagePanel(store: store)
                if updater.updateAvailable, let latest = updater.latest {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Versione \(latest.version) disponibile", systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.coral)
                        HStack {
                            Button(updater.state == .downloading || updater.state == .installing ? "Aggiorno…" : "Aggiorna e riavvia") {
                                Task { await updater.install() }
                            }
                            .controlSize(.small)
                            .disabled(updater.state == .downloading || updater.state == .installing)
                            Button("Novità") { NSWorkspace.shared.open(latest.pageURL) }
                                .buttonStyle(.link)
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .padding(10)
                }
                if !store.isIndexing && store.describingRemaining > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Descrivo le chat… \(store.describingRemaining)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                if store.isIndexing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Indicizzazione chat…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: store.indexProgress)
                            .tint(Theme.coral)
                    }
                    .padding(12)
                }
            }
            .scrollContentBackground(Theme.isWarm ? .hidden : .automatic)
            .background(Theme.sidebarBackground ?? .clear)
    }

    @ViewBuilder
    private var detail: some View {
            switch section ?? .chats(.all) {
            case .overview:
                OverviewView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            case .chats(let scope):
                ChatsView(store: store, scope: scope, focusedChatID: $focusedChatID)
            case .areas:
                WorkspacesView(store: store) { scope in section = .chats(scope) }
            case .active:
                ActiveSessionsView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            case .accounts:
                AccountsView(store: store)
            case .memory:
                MemoryView(store: store)
            case .insights:
                InsightsView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            case .compose:
                ComposeView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            }
    }

    private func row(_ title: String, symbol: String, tint: Color, count: Int? = nil, highlight: Color? = nil) -> some View {
        HStack(spacing: 10) {
            // Line icon in the text colour, like OpenChamber's sidebar: colour is kept for status.
            Image(systemName: Theme.line(symbol))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer()
            if let count {
                if let highlight {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.soft(highlight).opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.soft(highlight))
                } else {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 1)
    }
}
