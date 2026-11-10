import Foundation

/// An orchestrator chat and the agents it started.
///
/// The orchestrator is an ordinary Claude chat with extra instructions: it splits the work into
/// small tasks and writes each one as an `<agente titolo="…">…</agente>` block. When its turn
/// ends, OpenBoard starts one chat per block in the same folder (a few at a time, the rest
/// wait). Each agent does its task, writes a short report and is closed; the report goes back to
/// the orchestrator as a message, which decides what comes next.
struct AgentTeam: Codable, Hashable {
    var directory: String
    var maxParallel: Int = 3
    var workers: [AgentWorker] = []

    var running: [AgentWorker] { workers.filter { $0.status == .running } }
    var queued: [AgentWorker] { workers.filter { $0.status == .queued } }
    var isActive: Bool { workers.contains { $0.status == .running || $0.status == .queued } }
}

struct AgentWorker: Codable, Hashable, Identifiable {
    enum Status: String, Codable {
        case queued, running, done, failed, stopped

        var title: String {
            switch self {
            case .queued: return "In coda"
            case .running: return "Al lavoro"
            case .done: return "Finito"
            case .failed: return "Errore"
            case .stopped: return "Fermato"
            }
        }
    }

    var id = UUID().uuidString
    /// The agent's chat, once it has started.
    var chatID: String?
    var title: String
    var task: String
    var status: Status = .queued
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var report: String?
}

enum AgentTeams {
    static let defaultParallel = 3

    static func agents(_ count: Int) -> String { count == 1 ? "1 agente" : "\(count) agenti" }

    static func orchestratorPrompt(parallel: Int) -> String {
        """
        Sei l'ORCHESTRATORE di una squadra di agenti in OpenBoard. Il tuo compito è coordinare, non svolgere tu il lavoro pesante.

        Come lavori:
        - Capisci l'obiettivo (leggi i file che servono per pianificare) e dividilo in compiti piccoli, concreti e verificabili.
        - Affida ogni compito a un agente scrivendo nella risposta un blocco così, esattamente con questo formato:
        <agente titolo="Titolo breve del compito">
        Istruzioni complete e autosufficienti: obiettivo, file e cartelle coinvolti, cosa NON toccare, come verificare il risultato, cosa riportare.
        </agente>
        - Puoi scrivere più blocchi nella stessa risposta: partono in parallelo, al massimo \(parallel) alla volta, gli altri aspettano il loro turno.
        - Gli agenti lavorano nella tua stessa cartella ma NON vedono questa conversazione né gli altri agenti: scrivi tutto quello che serve. Non dare a due agenti in parallelo gli stessi file; se un compito dipende da un altro, affidalo dopo aver ricevuto il resoconto del primo.
        - Dopo aver affidato i compiti chiudi la risposta e aspetta. Ogni agente, quando finisce, ti manda un messaggio che inizia con "[Agente" con il suo resoconto, poi si chiude.
        - Quando ricevi un resoconto: controlla il risultato se serve, affida i compiti successivi oppure, quando è tutto finito, fai all'utente un riepilogo chiaro di cosa è stato fatto e cosa resta aperto.
        - Le modifiche ai file falle fare agli agenti; tu leggi, pianifichi, verifichi e rispondi all'utente.
        - Non usare blocchi <agente> per esempi o spiegazioni: ogni blocco avvia davvero un agente.
        """
    }

    static let workerPrompt = """
        Sei un AGENTE di una squadra coordinata da un orchestratore in OpenBoard. Ti viene affidato un solo compito.
        - Fai solo quel compito, nella cartella corrente, senza allargarlo e senza toccare altro.
        - Non puoi fare domande a nessuno: se qualcosa non è chiaro scegli l'opzione più prudente e dillo nel resoconto.
        - Quando hai finito, chiudi con un RESOCONTO breve: cosa hai fatto, file toccati, come hai verificato, problemi o dubbi aperti. Il resoconto viene passato all'orchestratore e poi questa chat si chiude.
        """

    struct ParsedTask: Equatable {
        let title: String
        let task: String
    }

    private static let blockPattern = try! NSRegularExpression(
        pattern: #"<agente(?:\s+titolo\s*=\s*"([^"]*)")?\s*>([\s\S]*?)</agente\s*>"#,
        options: [.caseInsensitive])

    /// The `<agente>` blocks in an orchestrator's answer.
    static func parseTasks(_ text: String) -> [ParsedTask] {
        let range = NSRange(text.startIndex..., in: text)
        return blockPattern.matches(in: text, range: range).compactMap { match in
            guard let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
            let body = text[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            var title = Range(match.range(at: 1), in: text).map { String(text[$0]) }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if title.isEmpty { title = String(body.split(separator: "\n").first?.prefix(60) ?? "Compito") }
            return ParsedTask(title: title, task: body)
        }
    }

    /// The orchestrator's answer for reading: each block becomes a small heading.
    static func displayText(_ text: String) -> String {
        guard text.range(of: "<agente", options: .caseInsensitive) != nil else { return text }
        var result = text.replacingOccurrences(of: #"<agente(?:\s+titolo\s*=\s*"([^"]*)")?\s*>"#,
                                               with: "\n**→ Agente: $1**\n", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"</agente\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        return result
    }

    static func taskMessage(_ worker: AgentWorker) -> String {
        "Compito: \(worker.title)\n\n\(worker.task)"
    }

    static func reportMessage(_ worker: AgentWorker, team: AgentTeam) -> String {
        let outcome: String
        switch worker.status {
        case .failed: outcome = "si è fermato con un errore"
        case .stopped: outcome = "è stato fermato"
        default: outcome = "ha finito"
        }
        var text = "[Agente «\(worker.title)» \(outcome)]\n\n"
        let report = (worker.report ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        text += report.isEmpty ? "(nessun resoconto)" : String(report.prefix(6000))
        let running = team.running.count, queued = team.queued.count
        if running + queued == 0 {
            text += "\n\n— Tutti gli agenti hanno finito."
        } else {
            text += "\n\n— Ancora al lavoro: \(running)" + (queued > 0 ? ", in coda: \(queued)" : "")
        }
        return text
    }
}

// MARK: - Store

extension DeckStore {
    func team(for chatID: String) -> AgentTeam? { config.teams?[chatID] }

    func isOrchestrator(_ chat: ChatSession) -> Bool { config.teams?[chat.id] != nil }

    /// Agent chat id → its orchestrator's chat id.
    var workerParents: [String: String] {
        var map: [String: String] = [:]
        for (parent, team) in config.teams ?? [:] {
            for worker in team.workers { if let id = worker.chatID { map[id] = parent } }
        }
        return map
    }

    func worker(chatID: String) -> (parent: String, worker: AgentWorker)? {
        for (parent, team) in config.teams ?? [:] {
            if let worker = team.workers.first(where: { $0.chatID == chatID }) { return (parent, worker) }
        }
        return nil
    }

    /// Chats of an orchestrator's agents, in the order they were assigned.
    func workerChats(of orchestratorID: String) -> [(worker: AgentWorker, chat: ChatSession?)] {
        guard let team = team(for: orchestratorID) else { return [] }
        return team.workers.map { worker in (worker, worker.chatID.flatMap { id in chats.first { $0.id == id } }) }
    }

    /// The instructions a chat starts with: its role in a team and the project's milestones.
    func systemPrompt(for chatID: String, folder: String) -> String? {
        var parts: [String] = []
        if let team = team(for: chatID) { parts.append(AgentTeams.orchestratorPrompt(parallel: team.maxParallel)) }
        if worker(chatID: chatID) != nil { parts.append(AgentTeams.workerPrompt) }
        if let milestones = milestonesPrompt(for: folder) { parts.append(milestones) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func startOrchestrator(in folder: String, account: ClaudeAccount?, model: String?, mode: LiveChat.PermissionMode,
                           parallel: Int = AgentTeams.defaultParallel, message: String) -> ChatSession {
        let id = UUID().uuidString.lowercased()
        var teams = config.teams ?? [:]
        teams[id] = AgentTeam(directory: folder, maxParallel: parallel)
        config.teams = teams
        config.save()
        return startLiveChat(in: folder, account: account, model: model, mode: mode, message: message, id: id)
    }

    /// Turns an existing chat into an orchestrator: from its next message it can delegate.
    func makeOrchestrator(_ chat: ChatSession) {
        guard !isOrchestrator(chat), !chat.isCodex else { return }
        var teams = config.teams ?? [:]
        teams[chat.id] = AgentTeam(directory: chat.workingDirectory)
        config.teams = teams
        config.save()
        // The instructions go in when Claude starts: the next message restarts it with them.
        objectWillChange.send()
    }

    func setParallel(_ count: Int, for orchestratorID: String) {
        guard var team = team(for: orchestratorID) else { return }
        team.maxParallel = max(1, min(count, 8))
        config.teams?[orchestratorID] = team
        config.save()
        pumpTeam(orchestratorID)
    }

    private func updateTeam(_ orchestratorID: String, _ change: (inout AgentTeam) -> Void) {
        guard var team = config.teams?[orchestratorID] else { return }
        change(&team)
        config.teams?[orchestratorID] = team
        config.save()
    }

    /// Called whenever a chat's turn ends.
    func teamTurnFinished(_ live: LiveChat) {
        let id = live.chatID
        if team(for: id) != nil {
            let tasks = AgentTeams.parseTasks(live.lastTurnText)
            guard !tasks.isEmpty else { return }
            updateTeam(id) { team in
                team.workers += tasks.map { AgentWorker(title: $0.title, task: $0.task) }
            }
            pumpTeam(id)
            return
        }
        guard let (parent, worker) = worker(chatID: id), worker.status == .running else { return }
        // A turn that ends with a question for permission denied, or with Claude still queued, is not the end.
        guard live.queue.isEmpty else { return }
        let error = live.lastTurnError
        updateTeam(parent) { team in
            guard let index = team.workers.firstIndex(where: { $0.id == worker.id }) else { return }
            team.workers[index].status = error == nil ? .done : .failed
            team.workers[index].finishedAt = Date()
            let text = live.lastTurnText
            team.workers[index].report = error.map { text.isEmpty ? $0 : text + "\n\nErrore: " + $0 } ?? text
        }
        finishWorker(worker.id, chatID: id, parent: parent)
    }

    /// Reports to the orchestrator, closes the agent's chat and starts the next one waiting.
    private func finishWorker(_ workerID: String, chatID: String?, parent: String) {
        if let chatID {
            // Let the view reload the finished transcript first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.closeLiveChat(chatID) }
        }
        pumpTeam(parent)
        guard let team = team(for: parent), let worker = team.workers.first(where: { $0.id == workerID }),
              let chat = chats.first(where: { $0.id == parent }) else { return }
        let orchestrator = liveChat(for: chat)
        orchestrator.send(AgentTeams.reportMessage(worker, team: team))
    }

    /// Starts waiting agents while there is room.
    func pumpTeam(_ orchestratorID: String) {
        guard let team = team(for: orchestratorID) else { return }
        let room = team.maxParallel - team.running.count
        guard room > 0 else { return }
        let parent = liveChats[orchestratorID]
        for worker in team.queued.prefix(room) {
            let chatID = UUID().uuidString.lowercased()
            updateTeam(orchestratorID) { team in
                guard let index = team.workers.firstIndex(where: { $0.id == worker.id }) else { return }
                team.workers[index].chatID = chatID
                team.workers[index].status = .running
                team.workers[index].startedAt = Date()
            }
            // Same account and model as the orchestrator; a plan-only orchestrator still gets agents that work.
            let mode = parent?.mode == .plan ? LiveChat.PermissionMode.standard : (parent?.mode ?? .standard)
            let chat = startLiveChat(in: team.directory, account: parent?.account ?? preferredAccount, model: parent?.model,
                                     mode: mode, message: AgentTeams.taskMessage(worker), id: chatID)
            if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index].title = worker.title }
        }
        objectWillChange.send()
    }

    /// Stops every agent of a team, running or waiting.
    func stopTeam(_ orchestratorID: String) {
        guard let team = team(for: orchestratorID) else { return }
        for worker in team.workers where worker.status == .running || worker.status == .queued {
            stopWorker(worker.id, of: orchestratorID, report: false)
        }
    }

    func stopWorker(_ workerID: String, of orchestratorID: String, report: Bool = true) {
        guard let worker = team(for: orchestratorID)?.workers.first(where: { $0.id == workerID }),
              worker.status == .running || worker.status == .queued else { return }
        updateTeam(orchestratorID) { team in
            guard let index = team.workers.firstIndex(where: { $0.id == workerID }) else { return }
            team.workers[index].status = .stopped
            team.workers[index].finishedAt = Date()
            team.workers[index].report = "Fermato dall'utente."
        }
        if let chatID = worker.chatID, let live = liveChats[chatID] {
            live.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.closeLiveChat(chatID) }
        }
        if report, let team = team(for: orchestratorID), let stopped = team.workers.first(where: { $0.id == workerID }),
           let chat = chats.first(where: { $0.id == orchestratorID }) {
            liveChat(for: chat).send(AgentTeams.reportMessage(stopped, team: team))
        }
        pumpTeam(orchestratorID)
        objectWillChange.send()
    }

    /// Agents that were working when the app closed are gone: mark them so.
    func recoverTeams() {
        guard var teams = config.teams else { return }
        var changed = false
        for (id, var team) in teams {
            for index in team.workers.indices where team.workers[index].status == .running && liveChats[team.workers[index].chatID ?? ""] == nil {
                team.workers[index].status = .stopped
                team.workers[index].report = "Interrotto: OpenBoard è stato chiuso mentre lavorava."
                team.workers[index].finishedAt = team.workers[index].finishedAt ?? Date()
                changed = true
            }
            teams[id] = team
        }
        guard changed else { return }
        config.teams = teams
        config.save()
    }

    /// Open in a terminal, not just running inside OpenBoard.
    func isOpenInTerminal(_ chatID: String) -> Bool {
        let own = Set(liveChats.values.compactMap(\.pid))
        return activeSessions.contains { $0.sessionId == chatID && !own.contains($0.pid) }
    }

    // MARK: - Pinned

    func isPinned(_ chat: ChatSession) -> Bool { config.pinnedChats?.contains(chat.id) ?? false }

    func setPinned(_ pinned: Bool, for chats: [ChatSession]) {
        var list = config.pinnedChats ?? []
        let ids = chats.map(\.id)
        list.removeAll { ids.contains($0) }
        if pinned { list.insert(contentsOf: ids, at: 0) }
        config.pinnedChats = list
        config.save()
        objectWillChange.send()
    }
}
