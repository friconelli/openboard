import SwiftUI

/// Above the composer of an orchestrator (its agents, how many at once, stop) or of an agent
/// (whose it is, its state, back to the orchestrator).
struct TeamBar: View {
    @ObservedObject var store: DeckStore
    let chatID: String
    @State private var showAll = false

    var body: some View {
        Group {
            if let team = store.team(for: chatID) {
                orchestratorBar(team)
            } else if let (parent, worker) = store.worker(chatID: chatID) {
                agentBar(worker, parent: parent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.layout, value: store.team(for: chatID)?.workers ?? [])
        .background(Theme.accent.opacity(0.07))
        .overlay(alignment: .top) { Divider() }
    }

    private func orchestratorBar(_ team: AgentTeam) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Agents arriving, finishing and leaving the active list.
            HStack(spacing: 8) {
                Label("Orchestratore", systemImage: "person.3.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(summary(team))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Stepper("\(team.maxParallel) alla volta", value: Binding(get: { team.maxParallel },
                                                                       set: { store.setParallel($0, for: chatID) }), in: 1...8)
                    .controlSize(.small)
                    .font(.caption)
                    .fixedSize()
                    .help("Quanti agenti lavorano insieme; gli altri aspettano")
                if team.isActive {
                    Button("Ferma tutti", role: .destructive) { store.stopTeam(chatID) }
                        .controlSize(.small)
                }
            }
            if team.workers.isEmpty {
                Text("Scrivi l'obiettivo: l'orchestratore lo divide in compiti e li affida ad agenti, che a fine lavoro gli mandano il resoconto e si chiudono.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let workers = showAll ? team.workers : Array(team.workers.filter { $0.status == .running || $0.status == .queued }.prefix(6))
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(workers) { worker in agentChip(worker).transition(.scale(scale: 0.85).combined(with: .opacity)) }
                    let hidden = team.workers.count - workers.count
                    if hidden > 0 || showAll {
                        Button(showAll ? "Solo attivi" : "Tutti (\(team.workers.count))") { withAnimation(Motion.layout) { showAll.toggle() } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func agentChip(_ worker: AgentWorker) -> some View {
        Button {
            if let id = worker.chatID { NotificationCenter.default.post(name: .focusChat, object: id) }
        } label: {
            HStack(spacing: 5) {
                StateMark(state: state(worker))
                Text(worker.title).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help("\(worker.status.title)\n\n\(worker.report.map { String($0.prefix(500)) } ?? worker.task.prefix(500).description)")
        .contextMenu {
            if worker.status == .running || worker.status == .queued {
                Button("Ferma questo agente") { store.stopWorker(worker.id, of: chatID) }
            }
        }
    }

    private func agentBar(_ worker: AgentWorker, parent: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").foregroundStyle(Theme.accent)
            Text("Agente").font(.callout.weight(.semibold))
            StateMark(state: state(worker))
            Text(worker.status.title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if worker.status == .running || worker.status == .queued {
                Button("Ferma", role: .destructive) { store.stopWorker(worker.id, of: parent) }
                    .controlSize(.small)
            }
            Button {
                NotificationCenter.default.post(name: .focusChat, object: parent)
            } label: {
                Label("Orchestratore", systemImage: "arrow.up.left")
            }
            .controlSize(.small)
            .help(store.chats.first { $0.id == parent }?.displayTitle ?? "")
        }
    }

    private func state(_ worker: AgentWorker) -> SidebarRowState {
        switch worker.status {
        case .queued: return .queued
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        case .running:
            if let id = worker.chatID, store.liveChats[id]?.pendingPermission != nil { return .permission }
            return .running(worker.startedAt)
        }
    }

    private func summary(_ team: AgentTeam) -> String {
        if team.workers.isEmpty { return "nessun agente ancora" }
        let done = team.workers.filter { $0.status == .done }.count
        var parts = ["\(team.running.count) al lavoro"]
        if !team.queued.isEmpty { parts.append("\(team.queued.count) in coda") }
        parts.append("\(done) finiti")
        return parts.joined(separator: " · ")
    }
}
