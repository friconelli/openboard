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
    case archived
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
    case tasks

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
        case "tasks": self = .tasks
        case "archive": self = .chats(.archived)
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
    @State private var showRemote = false
    @ObservedObject private var remote = RemoteServer.shared
    @StateObject private var chatsUI = ChatsUI()
    /// Which chats the list on the left shows.
    @State private var listScope: ChatScope = .all
    @AppStorage(Theme.appearanceKey) private var appearance: Theme.Appearance = .system
    @AppStorage(Theme.Mode.key) private var mode: Theme.Mode = .auto

    var body: some View {
        NavigationSplitView {
            chatList
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                rail
            }
            .background(Theme.pageBackground ?? .clear)
        }
        .onChange(of: section) { _, value in
            if case .chats(let scope) = value { listScope = scope }
        }
        .onChange(of: chatsUI.selection) { _, value in
            // Picking a chat in the list while a page is open brings the chat back.
            if !value.isEmpty, case .chats = section {} else if !value.isEmpty { section = .chats(listScope) }
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
        .onReceive(NotificationCenter.default.publisher(for: .showRemote)) { _ in showRemote = true }
        .sheet(isPresented: $showRemote) { RemoteAccessSheet() }
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
            RemoteServer.shared.refresh()
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
            RemoteServer.shared.attach(store)
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
            if defaults.bool(forKey: "debugRemoteSheet") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showRemote = true }
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

    /// Left column, like OpenChamber: which chats (scope menu), search and the list itself;
    /// plan usage and progress at the bottom.
    private var chatList: some View {
        VStack(spacing: 0) {
            scopeMenu
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ChatsView(store: store, scope: listScope, focusedChatID: $focusedChatID, ui: chatsUI, mode: .list)
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
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
            .background(Theme.sidebarBackground ?? .clear)
    }

    private func count(_ scope: ChatScope) -> Int {
        switch scope {
        case .all: return store.visibleChats.count
        case .archived: return store.archivedChats.count
        case .working: return store.workingChats.count
        case .smart(let filter): return store.visibleChats.filter { store.matches($0, filter) }.count
        case .context(let context): return store.visibleChats.filter { store.context(for: $0) == context }.count
        case .unassigned: return store.visibleChats.filter { store.context(for: $0) == nil }.count
        }
    }

    private func scopeLabel(_ scope: ChatScope) -> (title: String, symbol: String) {
        switch scope {
        case .all: return ("Tutte le chat", "bubble.left.and.bubble.right")
        case .archived: return ("Archivio", "archivebox")
        case .working: return ("In lavorazione", "flag")
        case .smart(let filter): return (filter.title, Theme.line(filter.symbol))
        case .context(let context): return (context, Theme.line(Theme.symbol(forContext: context)))
        case .unassigned: return ("Da assegnare", "tray")
        }
    }

    private func scopeButton(_ scope: ChatScope) -> some View {
        let label = scopeLabel(scope)
        return Button {
            section = .chats(scope)
        } label: {
            Label("\(label.title)  \(count(scope))", systemImage: label.symbol)
        }
    }

    /// The list's filter: what used to be the sidebar sections, in one menu.
    private var scopeMenu: some View {
        let current = scopeLabel(listScope)
        return Menu {
            Section("Chat") {
                scopeButton(.all)
                scopeButton(.working)
                ForEach(store.config.contexts, id: \.self) { scopeButton(.context($0)) }
                scopeButton(.unassigned)
            }
            let smart = SmartFilter.allCases.filter { !(store.config.hiddenSmartFilters ?? []).contains($0.rawValue) && count(.smart($0)) > 0 }
            if !smart.isEmpty {
                Section("Filtri") {
                    ForEach(smart) { scopeButton(.smart($0)) }
                }
            }
            Section {
                scopeButton(.archived)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current.symbol).foregroundStyle(Theme.accent)
                Text(current.title).font(.headline)
                Text("\(count(listScope))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Quali chat mostrare: tutte, in lavorazione, per contesto, filtri, archivio")
    }

    /// Right rail: the app's pages, as OpenChamber's icon rail.
    private var rail: some View {
        let attention = store.activeSessions.filter { $0.status != "busy" }.count
        let advice = store.visibleChats.filter { store.hasAdvice(for: $0) }.count
        return VStack(spacing: 6) {
            railButton("Chat", "bubble.left.and.bubble.right", isOn: { if case .chats = section { return true }; return false }()) {
                section = .chats(listScope)
            }
            Divider().frame(width: 28).padding(.vertical, 4)
            railButton("Panoramica", "square.grid.2x2", badge: attention, isOn: section == .overview) { section = .overview }
            railButton("Nuova chat guidata", "sparkles", isOn: section == .compose) { section = .compose }
            railButton("Consigli", "lightbulb", badge: advice, isOn: section == .insights) { section = .insights }
            railButton("Attività programmate", "clock.arrow.circlepath", isOn: section == .tasks) { section = .tasks }
            railButton("Aree di lavoro", "folder", isOn: section == .areas) { section = .areas }
            railButton("Memoria", "brain.head.profile", isOn: section == .memory) { section = .memory }
            Spacer()
            railButton(remote.status == .running ? "iPhone collegabile: mostra il link (⌘L)" : "Link per iPhone (⌘L)", "iphone",
                       isOn: remote.status == .running) { showRemote = true }
            railButton("Sessioni attive", "bolt.horizontal", badge: store.activeSessions.count, isOn: section == .active) { section = .active }
            railButton("Account", "person.2", isOn: section == .accounts) { section = .accounts }
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(Theme.sidebarBackground ?? Color(nsColor: .windowBackgroundColor))
    }

    private func railButton(_ title: String, _ symbol: String, badge: Int = 0, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isOn ? Theme.accent : .secondary)
                .frame(width: 36, height: 34)
                .background(isOn ? Theme.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
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
                ChatsView(store: store, scope: scope, focusedChatID: $focusedChatID, ui: chatsUI, mode: .detail)
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
            case .tasks:
                TasksView(store: store)
            case .compose:
                ComposeView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            }
    }
}
