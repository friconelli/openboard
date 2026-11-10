import SwiftUI
import AppKit

/// What “Nuova chat” should open with: a folder already chosen, an orchestrator.
struct NewChatRequest {
    var folder: String?
    var team = false
}

/// The chat list organised like OpenChamber's sidebar: pinned chats on top, then one group per
/// project (folder) with its chats by recency, orchestrators with their agents nested below,
/// “Mostra altre” after the first few. One project can be put in focus: the list then shows only
/// that one, with every agent at work.
struct SidebarProject: Identifiable {
    let id: String
    var name: String { id == ClaudePaths.home.path ? "~" : URL(fileURLWithPath: id).lastPathComponent }
    var chats: [ChatSession]
    var last: Date
}

enum SidebarRowState: Equatable {
    case idle, running(Date?), permission, unseen, queued, done, failed, stopped
}

extension ChatsView {
    static let initialLimit = 7
    static let focusLimit = 20

    // MARK: - Tree

    /// Roots shown in the list: every matching chat, an agent under its orchestrator instead.
    var sidebarRoots: [ChatSession] {
        let parents = store.workerParents
        let byID = Dictionary(store.chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var roots: [ChatSession] = []
        for chat in filtered {
            let root = parents[chat.id].flatMap { byID[$0] } ?? chat
            if seen.insert(root.id).inserted { roots.append(root) }
        }
        return roots
    }

    var pinnedRoots: [ChatSession] {
        guard ui.focusedProject == nil else { return [] }
        let order = store.config.pinnedChats ?? []
        return sidebarRoots.filter(store.isPinned)
            .sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }

    var sidebarProjects: [SidebarProject] {
        let pinned = Set(pinnedRoots.map(\.id))
        var groups: [String: SidebarProject] = [:]
        for chat in sidebarRoots where !pinned.contains(chat.id) {
            let key = chat.workingDirectory
            if let focus = ui.focusedProject, key != focus { continue }
            let last = lastActivity(chat)
            if groups[key] == nil {
                groups[key] = SidebarProject(id: key, chats: [chat], last: last)
            } else {
                groups[key]!.chats.append(chat)
                groups[key]!.last = max(groups[key]!.last, last)
            }
        }
        return groups.values
            .map { project in
                var project = project
                // Pinned chats lead their project when the pinned zone is hidden (focus).
                project.chats.sort { a, b in
                    let pa = store.isPinned(a), pb = store.isPinned(b)
                    if pa != pb { return pa }
                    return lastActivity(a) > lastActivity(b)
                }
                return project
            }
            .sorted { $0.last > $1.last }
    }

    private func lastActivity(_ chat: ChatSession) -> Date {
        if store.liveChats[chat.id]?.isRunning == true { return Date() }
        if let team = store.team(for: chat.id), team.isActive { return Date() }
        return chat.modifiedAt
    }

    // MARK: - State

    func rowState(_ chat: ChatSession) -> SidebarRowState {
        if let live = store.liveChats[chat.id] {
            if live.pendingPermission != nil { return .permission }
            if live.isRunning { return .running(live.turnStartedAt) }
        }
        if store.activeSessions.contains(where: { $0.sessionId == chat.id && $0.status == "busy" }) { return .running(nil) }
        if store.unseenChats.contains(chat.id) { return .unseen }
        return .idle
    }

    func workerState(_ worker: AgentWorker, chat: ChatSession?) -> SidebarRowState {
        switch worker.status {
        case .queued: return .queued
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        case .running:
            if let chat { let state = rowState(chat); if state != .idle { return state } }
            return .running(worker.startedAt)
        }
    }

    /// A collapsed orchestrator shows the most urgent state among itself and its agents.
    func aggregateState(_ chat: ChatSession) -> SidebarRowState {
        let own = rowState(chat)
        let agents = store.workerChats(of: chat.id).map { workerState($0.worker, chat: $0.chat) }
        if own == .permission || agents.contains(.permission) { return .permission }
        if case .running = own { return own }
        if let running = agents.first(where: { if case .running = $0 { return true } else { return false } }) { return running }
        return own
    }

    func isExpanded(_ chat: ChatSession) -> Bool {
        if ui.expanded.contains(chat.id) { return true }
        if ui.collapsedTeams.contains(chat.id) { return false }
        // Teams at work and every team of the project in focus open by themselves.
        return ui.focusedProject != nil || (store.team(for: chat.id)?.isActive ?? false)
    }

    func toggleExpanded(_ chat: ChatSession) {
        if isExpanded(chat) {
            ui.expanded.remove(chat.id)
            ui.collapsedTeams.insert(chat.id)
        } else {
            ui.collapsedTeams.remove(chat.id)
            ui.expanded.insert(chat.id)
        }
    }

    // MARK: - Views

    @ViewBuilder
    var sidebarList: some View {
        let projects = sidebarProjects
        let pinned = pinnedRoots
        let searching = !ui.query.isEmpty
        List(selection: $ui.selection) {
            if let focus = ui.focusedProject {
                FocusHeader(store: store, path: focus, chats: projects.first?.chats ?? []) { ui.focusedProject = nil }
                    .sidebarRowInsets()
                    .selectionDisabled()
            }
            if !pinned.isEmpty {
                ZoneCaption(title: "Fissate", symbol: "pin")
                    .sidebarRowInsets()
                    .selectionDisabled()
                ForEach(pinned) { chat in chatNode(chat, depth: 0, inPinnedZone: true) }
            }
            if ui.focusedProject == nil && !pinned.isEmpty && !projects.isEmpty {
                ZoneCaption(title: "Progetti", symbol: "folder")
                    .sidebarRowInsets()
                    .selectionDisabled()
            }
            ForEach(projects) { project in
                let collapsed = !searching && ui.focusedProject == nil && ui.collapsedProjects.contains(project.id)
                if ui.focusedProject == nil {
                    ProjectHeaderRow(
                        store: store, project: project, collapsed: collapsed,
                        toggle: { ui.toggleProject(project.id) },
                        focus: { ui.focusedProject = project.id }
                    )
                    .sidebarRowInsets()
                    .selectionDisabled()
                }
                if !collapsed {
                    let limit = searching ? Int.max : (ui.shown[project.id] ?? (ui.focusedProject == nil ? Self.initialLimit : Self.focusLimit))
                    ForEach(project.chats.prefix(limit)) { chat in chatNode(chat, depth: 0, inPinnedZone: false) }
                    if !searching && (project.chats.count > limit || limit > Self.initialLimit && ui.shown[project.id] != nil) {
                        ShowMoreRow(hidden: max(0, project.chats.count - limit),
                                    more: { ui.shown[project.id] = limit + Self.initialLimit },
                                    less: { ui.shown[project.id] = nil })
                            .sidebarRowInsets()
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(Theme.isWarm ? .hidden : .automatic)
        .environment(\.defaultMinListRowHeight, 10)
    }

    @ViewBuilder
    private func chatNode(_ chat: ChatSession, depth: Int, inPinnedZone: Bool) -> some View {
        let agents = store.workerChats(of: chat.id)
        let isTeam = store.isOrchestrator(chat)
        let expanded = (isExpanded(chat) || !ui.query.isEmpty) && !agents.isEmpty
        SidebarChatRow(
            chat: chat,
            title: chat.displayTitle,
            depth: depth,
            state: expanded || agents.isEmpty ? rowState(chat) : aggregateState(chat),
            isTeam: isTeam,
            agentsSummary: isTeam ? Self.agentsSummary(store.team(for: chat.id)) : nil,
            hasChildren: !agents.isEmpty,
            expanded: expanded,
            pinned: store.isPinned(chat) && !inPinnedZone,
            isWorking: store.isWorking(chat),
            openInTerminal: store.isOpenInTerminal(chat.id),
            description: store.description(for: chat),
            toggle: { toggleExpanded(chat) }
        )
        .tag(chat.id)
        .sidebarRowInsets()
        .contextMenu { contextMenu(for: chat) }
        if expanded {
            ForEach(agents, id: \.worker.id) { entry in
                agentNode(entry.worker, chat: entry.chat, orchestratorID: chat.id, depth: depth + 1)
            }
        }
    }

    @ViewBuilder
    private func agentNode(_ worker: AgentWorker, chat: ChatSession?, orchestratorID: String, depth: Int) -> some View {
        let row = SidebarAgentRow(worker: worker, depth: depth, state: workerState(worker, chat: chat))
            .sidebarRowInsets()
            .contextMenu {
                if worker.status == .running || worker.status == .queued {
                    Button("Ferma questo agente") { store.stopWorker(worker.id, of: orchestratorID) }
                }
                if let chat {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([chat.fileURL]) }
                    Button("Archivia") { store.archive([chat]) }
                }
            }
        if let chat {
            row.tag(chat.id)
        } else {
            row.selectionDisabled()
        }
    }

    static func agentsSummary(_ team: AgentTeam?) -> String? {
        guard let team, !team.workers.isEmpty else { return nil }
        let running = team.running.count, queued = team.queued.count
        if running + queued == 0 { return AgentTeams.agents(team.workers.count) }
        return "\(running) al lavoro" + (queued > 0 ? " · \(queued) in coda" : "")
    }
}

private extension View {
    func sidebarRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            .listRowSeparator(.hidden)
    }
}

// MARK: - Rows

struct StateMark: View {
    let state: SidebarRowState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running(let since):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                if let since {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(since, context.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .help("Al lavoro")
        case .permission:
            Image(systemName: "exclamationmark.shield.fill").font(.caption).foregroundStyle(.orange)
                .help("Aspetta un tuo permesso")
        case .unseen:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .help("Ha finito: risposta da leggere")
        case .queued:
            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary).help("In coda")
        case .done:
            Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).help("Finito e chiuso")
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).help("Fermato da un errore")
        case .stopped:
            Image(systemName: "stop.circle").font(.caption).foregroundStyle(.tertiary).help("Fermato")
        }
    }

    static func elapsed(_ since: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

/// Tree slot: indentation, then a chevron for rows with children.
private struct TreeSlot: View {
    let depth: Int
    let hasChildren: Bool
    let expanded: Bool
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle().fill(Theme.hairline).frame(width: 1).padding(.horizontal, 6.5).frame(maxHeight: .infinity)
            }
            Group {
                if hasChildren {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Nascondi gli agenti" : "Mostra gli agenti")
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
        }
    }
}

struct SidebarChatRow: View {
    let chat: ChatSession
    let title: String
    let depth: Int
    let state: SidebarRowState
    let isTeam: Bool
    let agentsSummary: String?
    let hasChildren: Bool
    let expanded: Bool
    let pinned: Bool
    let isWorking: Bool
    let openInTerminal: Bool
    let description: String?
    let toggle: () -> Void
    @AppStorage(RowDensity.key) private var density: RowDensity = .comfortable

    private var emphasis: Bool {
        switch state {
        case .unseen, .permission: return true
        default: return false
        }
    }

    private var active: Bool {
        if case .running = state { return true }
        return emphasis
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            TreeSlot(depth: depth, hasChildren: hasChildren, expanded: expanded, toggle: toggle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isTeam {
                        Image(systemName: "person.3.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                            .help("Orchestratore: affida i compiti ad agenti")
                    }
                    if chat.isCodex { ProviderBadge(provider: .codex, iconOnly: true) }
                    Text(title)
                        .fontWeight(emphasis ? .semibold : .regular)
                        .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.82))
                        .lineLimit(1)
                        .help(description ?? chat.preview ?? "")
                    Spacer(minLength: 4)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    if isWorking { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                    if openInTerminal, case .idle = state {
                        StatusDot(busy: false).help("Aperta in un terminale")
                    }
                    StateMark(state: state)
                }
                if density == .comfortable {
                    HStack(spacing: 6) {
                        if let agentsSummary {
                            Text(agentsSummary).foregroundStyle(Theme.accent)
                        } else if let line = description ?? chat.preview, line != title {
                            Text(line).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(relative(chat.modifiedAt)).monospacedDigit().fixedSize()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, density == .comfortable ? 5 : 4)
        .contentShape(Rectangle())
    }
}

struct SidebarAgentRow: View {
    let worker: AgentWorker
    let depth: Int
    let state: SidebarRowState

    private var finished: Bool { worker.status != .running && worker.status != .queued }

    var body: some View {
        HStack(spacing: 6) {
            TreeSlot(depth: depth, hasChildren: false, expanded: false)
            Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(finished ? Color.secondary : Theme.accent)
            Text(worker.title)
                .font(.callout)
                .foregroundStyle(finished ? .secondary : .primary)
                .lineLimit(1)
                .help(worker.report.map { "Resoconto:\n\($0.prefix(600))" } ?? worker.task)
            Spacer(minLength: 4)
            StateMark(state: state)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct ZoneCaption: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .padding(.leading, 4)
    }
}

private struct ShowMoreRow: View {
    let hidden: Int
    let more: () -> Void
    let less: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if hidden > 0 {
                Button("Mostra altre (\(hidden))", action: more)
            }
            Button("Mostra meno", action: less)
                .opacity(hidden > 0 ? 0 : 1)
                .disabled(hidden > 0)
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 26)
        .padding(.vertical, 3)
    }
}

/// Project group header: chevron, folder, name; on hover new chat, orchestrator, focus and menu.
private struct ProjectHeaderRow: View {
    @ObservedObject var store: DeckStore
    let project: SidebarProject
    let collapsed: Bool
    let toggle: () -> Void
    let focus: () -> Void
    @State private var hovering = false

    private var agentsAtWork: Int {
        project.chats.reduce(0) { $0 + (store.team(for: $1.id)?.running.count ?? 0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Image(systemName: collapsed ? "folder" : "folder.fill")
                .font(.callout)
                .foregroundStyle(Theme.accent.opacity(0.85))
            Text(project.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if !store.ownMilestones(for: project.id).isEmpty {
                Image(systemName: "flag.checkered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Ha delle milestone: le ricevono tutte le chat del progetto")
            }
            if agentsAtWork > 0 {
                Label("\(agentsAtWork)", systemImage: "person.3.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .help("\(AgentTeams.agents(agentsAtWork)) al lavoro")
            }
            Spacer(minLength: 4)
            // Both always laid out, one visible: hovering must not change the row's size.
            ZStack(alignment: .trailing) {
                Text("\(project.chats.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0 : 1)
                ProjectButtons(store: store, path: project.id, focus: focus)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .frame(height: 20)
        }
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .help(project.id.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
        .contextMenu { ProjectMenuItems(path: project.id, focus: focus) }
    }
}

private struct ProjectButtons: View {
    @ObservedObject var store: DeckStore
    let path: String
    var focus: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            if let focus {
                iconButton("scope", "Lavora solo su questo progetto", action: focus)
            }
            iconButton("person.3", "Nuovo orchestratore con agenti in questo progetto") {
                NotificationCenter.default.post(name: .newChat, object: NewChatRequest(folder: path, team: true))
            }
            iconButton("plus", "Nuova chat in questo progetto") {
                NotificationCenter.default.post(name: .newChat, object: NewChatRequest(folder: path))
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct ProjectMenuItems: View {
    let path: String
    let focus: (() -> Void)?

    var body: some View {
        Button("Nuova chat qui…") {
            NotificationCenter.default.post(name: .newChat, object: NewChatRequest(folder: path))
        }
        Button("Nuovo orchestratore con agenti…") {
            NotificationCenter.default.post(name: .newChat, object: NewChatRequest(folder: path, team: true))
        }
        Button("Milestone…") { NotificationCenter.default.post(name: .editMilestones, object: path) }
        if let focus {
            Button("Lavora solo su questo progetto", action: focus)
        }
        Divider()
        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
}

/// Top of the list when one project is in focus: the way back, the project and its agents.
private struct FocusHeader: View {
    @ObservedObject var store: DeckStore
    let path: String
    let chats: [ChatSession]
    let close: () -> Void

    private var teams: [AgentTeam] { chats.compactMap { store.team(for: $0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: close) {
                Label("Tutti i progetti", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(path.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                ProjectButtons(store: store, path: path)
            }
            MilestonesSummary(store: store, folder: path) {
                NotificationCenter.default.post(name: .editMilestones, object: path)
            }
            .padding(.top, 2)
            let running = teams.reduce(0) { $0 + $1.running.count }
            let queued = teams.reduce(0) { $0 + $1.queued.count }
            if running + queued > 0 {
                Label("\(running) al lavoro" + (queued > 0 ? " · \(queued) in coda" : ""), systemImage: "person.3.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contextMenu { ProjectMenuItems(path: path, focus: nil) }
    }
}
