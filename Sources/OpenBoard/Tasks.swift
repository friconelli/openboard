import SwiftUI
import AppKit

/// Messages to Claude or Codex at set times, run by launchd even when OpenBoard is closed.
/// Each task is a LaunchAgent that runs a small zsh script: the agent in print mode in the
/// task's folder, output appended to a log, a macOS notification at the end.
struct ScheduledTask: Codable, Identifiable, Hashable {
    enum Repeat: String, Codable, CaseIterable, Identifiable {
        case daily, weekdays, weekly, hourly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: return "Ogni giorno"
            case .weekdays: return "Lun–ven"
            case .weekly: return "Ogni settimana"
            case .hourly: return "Ogni N ore"
            }
        }
    }

    var id = UUID().uuidString.lowercased()
    var title = ""
    var provider: Provider = .claude
    var folder = ""
    var prompt = ""
    var repeatRule: Repeat = .daily
    var hour = 9
    var minute = 0
    /// 1 = Monday … 7 = Sunday (launchd uses 0/7 = Sunday, 1 = Monday).
    var weekday = 1
    var everyHours = 4
    var accountID: String?
    var model: String?
    /// Claude: permission mode for an unattended run. Codex: sandbox.
    var claudeMode = "acceptEdits"
    var codexSandbox = "workspace-write"
    var enabled = true
    var created = Date()

    var label: String { "com.federicomancinelli.openboard.task.\(id)" }

    var scheduleDescription: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch repeatRule {
        case .daily: return "Ogni giorno alle \(time)"
        case .weekdays: return "Dal lunedì al venerdì alle \(time)"
        case .weekly:
            let names = ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"]
            return "Ogni \(names[max(0, min(6, weekday - 1))]) alle \(time)"
        case .hourly: return everyHours == 1 ? "Ogni ora" : "Ogni \(everyHours) ore"
        }
    }

    func nextRun(after now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        if repeatRule == .hourly { return now.addingTimeInterval(TimeInterval(everyHours * 3600)) }
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), candidate > now else { continue }
            let weekdayISO = (calendar.component(.weekday, from: candidate) + 5) % 7 + 1   // 1 = Monday
            switch repeatRule {
            case .weekdays where weekdayISO > 5: continue
            case .weekly where weekdayISO != weekday: continue
            default: return candidate
            }
        }
        return nil
    }
}

enum TaskScheduler {
    static var folder: URL { ClaudePaths.home.appendingPathComponent(".openboard/tasks") }
    static var storeURL: URL { ClaudePaths.appSupport.appendingPathComponent("tasks.json") }
    static var agents: URL { ClaudePaths.home.appendingPathComponent("Library/LaunchAgents") }

    static func load() -> [ScheduledTask] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTask].self, from: data)) ?? []
    }

    static func save(_ tasks: [ScheduledTask]) {
        if let data = try? JSONEncoder().encode(tasks) { try? data.write(to: storeURL, options: .atomic) }
    }

    static func script(for task: ScheduledTask) -> URL { folder.appendingPathComponent("\(task.id).zsh") }
    static func log(for task: ScheduledTask) -> URL { folder.appendingPathComponent("\(task.id).log") }
    static func plist(for task: ScheduledTask) -> URL { agents.appendingPathComponent("\(task.label).plist") }

    /// The zsh script launchd runs.
    static func scriptText(for task: ScheduledTask, account: ClaudeAccount?) -> String {
        let q = Launcher.shellQuote
        var command: String
        switch task.provider {
        case .claude:
            guard let binary = ClaudeAssistant.binaryPath else { return "echo 'claude non trovato'; exit 1" }
            command = (account.map { $0.isDefault ? "" : "CLAUDE_CONFIG_DIR=\(q($0.configDir.path)) " } ?? "")
                + "\(q(binary)) -p \(q(task.prompt)) --permission-mode \(task.claudeMode)"
                + (task.model.map { " --model \($0)" } ?? "")
        case .codex:
            guard let binary = Codex.binaryPath else { return "echo 'codex non trovato'; exit 1" }
            command = "\(q(binary)) exec --skip-git-repo-check -s \(task.codexSandbox) -C \(q(task.folder))"
                + (task.model.map { " -m \($0)" } ?? "") + " \(q(task.prompt))"
        }
        let title = task.title.isEmpty ? "Attività OpenBoard" : task.title
        return """
        #!/bin/zsh -l
        # OpenBoard scheduled task: \(title.replacingOccurrences(of: "\n", with: " "))
        mkdir -p \(q(folder.path))
        cd \(q(task.folder)) || exit 1
        echo "\\n===== $(date '+%Y-%m-%d %H:%M:%S') =====" >> \(q(log(for: task).path))
        \(command) < /dev/null >> \(q(log(for: task).path)) 2>&1
        code=$?
        if [ $code -eq 0 ]; then msg="Completata"; else msg="Finita con errore ($code)"; fi
        osascript -e "display notification \\"$msg\\" with title \\"OpenBoard\\" subtitle \(q(title).replacingOccurrences(of: "'", with: ""))" >/dev/null 2>&1
        echo "===== esito $code =====" >> \(q(log(for: task).path))
        exit $code

        """
    }

    static func plistData(for task: ScheduledTask) throws -> Data {
        var plist: [String: Any] = [
            "Label": task.label,
            "ProgramArguments": ["/bin/zsh", script(for: task).path],
            "WorkingDirectory": task.folder,
            "StandardOutPath": log(for: task).path,
            "StandardErrorPath": log(for: task).path,
            "RunAtLoad": false,
        ]
        let time: [String: Int] = ["Hour": task.hour, "Minute": task.minute]
        switch task.repeatRule {
        case .daily: plist["StartCalendarInterval"] = time
        case .weekdays: plist["StartCalendarInterval"] = (1...5).map { time.merging(["Weekday": $0]) { a, _ in a } }
        case .weekly: plist["StartCalendarInterval"] = time.merging(["Weekday": task.weekday % 7]) { a, _ in a }
        case .hourly: plist["StartInterval"] = max(1, task.everyHours) * 3600
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Writes the script and the LaunchAgent and (re)loads it; with `enabled` false it is unloaded.
    static func install(_ task: ScheduledTask, account: ClaudeAccount?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try scriptText(for: task, account: account).write(to: script(for: task), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script(for: task).path)
        unload(task)
        guard task.enabled else {
            try? fm.removeItem(at: plist(for: task))
            return
        }
        try plistData(for: task).write(to: plist(for: task), options: .atomic)
        let result = launchctl(["bootstrap", "gui/\(getuid())", plist(for: task).path])
        if result != 0 { throw ChatOperationError.io("launchctl non ha caricato l'attività (codice \(result))") }
    }

    static func unload(_ task: ScheduledTask) {
        _ = launchctl(["bootout", "gui/\(getuid())/\(task.label)"])
    }

    static func remove(_ task: ScheduledTask) {
        unload(task)
        let fm = FileManager.default
        for url in [plist(for: task), script(for: task)] { try? fm.removeItem(at: url) }
    }

    /// Runs the task now, outside the schedule (launchd kickstart when loaded, the script otherwise).
    static func runNow(_ task: ScheduledTask, account: ClaudeAccount?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try scriptText(for: task, account: account).write(to: script(for: task), atomically: true, encoding: .utf8)
        if task.enabled, launchctl(["kickstart", "gui/\(getuid())/\(task.label)"]) == 0 { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script(for: task).path]
        process.currentDirectoryURL = URL(fileURLWithPath: task.folder)
        try process.run()
    }

    static func lastLog(_ task: ScheduledTask) -> String? {
        guard let text = try? String(contentsOf: log(for: task), encoding: .utf8) else { return nil }
        let runs = text.components(separatedBy: "\n===== ")
        return runs.last.map { "===== " + $0 }.map { String($0.suffix(4000)) }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - Views

struct TasksView: View {
    @ObservedObject var store: DeckStore
    @State private var editing: ScheduledTask?
    @State private var logTask: ScheduledTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(symbol: "clock.arrow.circlepath", tint: Theme.coral, title: "Attività programmate",
                           subtitle: "Messaggi a Claude o Codex a orari fissi. Partono anche con OpenBoard chiuso, se il Mac è acceso.") {
                    Button {
                        editing = ScheduledTask(folder: store.recentFolders.first?.path ?? store.config.projectsRoot,
                                                accountID: store.preferredAccount?.id)
                    } label: { Label("Nuova attività", systemImage: "plus") }
                        .prominentButton()
                        .tint(Theme.accent)
                }
                if store.tasks.isEmpty {
                    EmptyStateView(symbol: "clock", title: "Nessuna attività",
                                   message: "Per esempio: ogni mattina alle 9 “controlla che i siti rispondano e riassumi i problemi”.")
                        .frame(height: 260)
                }
                ForEach(store.tasks) { task in card(task) }
            }
            .padding(24)
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "debugTaskEditor") { editing = ScheduledTask(folder: store.config.projectsRoot) }
        }
        .sheet(item: $editing) { task in
            TaskEditor(store: store, task: task) { saved in store.saveTask(saved) }
        }
        .sheet(item: $logTask) { task in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Ultima esecuzione di “\(task.title)”").font(.headline)
                    Spacer()
                    Button("Apri il registro completo") { NSWorkspace.shared.open(TaskScheduler.log(for: task)) }
                    Button("Chiudi") { logTask = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(14)
                Divider()
                ScrollView {
                    Text(TaskScheduler.lastLog(task) ?? "Non è ancora stata eseguita.")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .frame(width: 760, height: 480)
        }
    }

    private func card(_ task: ScheduledTask) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProviderBadge(provider: task.provider)
                    Text(task.title.isEmpty ? "Senza titolo" : task.title).font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { task.enabled }, set: { value in
                        var updated = task
                        updated.enabled = value
                        store.saveTask(updated)
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(task.enabled ? "Attiva: parte da sola" : "In pausa")
                }
                Text(task.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 12) {
                    Label(task.scheduleDescription, systemImage: "calendar")
                    if task.enabled, let next = task.nextRun() {
                        Label("prossima \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", systemImage: "clock")
                    }
                    Label(URL(fileURLWithPath: task.folder).lastPathComponent, systemImage: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Esegui ora") { store.runTaskNow(task) }
                    Button("Ultimo esito") { logTask = task }
                    Button("Modifica") { editing = task }
                    Spacer()
                    Button("Elimina", role: .destructive) { store.deleteTask(task) }
                }
                .controlSize(.small)
            }
        }
    }
}

struct TaskEditor: View {
    @ObservedObject var store: DeckStore
    @State var task: ScheduledTask
    let onSave: (ScheduledTask) -> Void
    @Environment(\.dismiss) private var dismiss

    private var formRows: Int {
        (task.provider == .claude ? 7 : 6) + (task.repeatRule == .weekly ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task.title.isEmpty ? "Nuova attività" : task.title).font(.title2.bold())
            Form {
                TextField("Titolo", text: $task.title, prompt: Text("Es. Controllo mattutino dei siti"))
                Picker("Agente", selection: $task.provider) {
                    ForEach(Provider.allCases.filter { $0 == .claude || Codex.isInstalled }) { Text($0.title).tag($0) }
                }
                HStack {
                    TextField("Cartella", text: $task.folder)
                    Button("Scegli…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.directoryURL = URL(fileURLWithPath: task.folder)
                        if panel.runModal() == .OK, let url = panel.url { task.folder = url.path }
                    }
                }
                Picker("Quando", selection: $task.repeatRule) {
                    ForEach(ScheduledTask.Repeat.allCases) { Text($0.title).tag($0) }
                }
                if task.repeatRule == .hourly {
                    Stepper("Ogni \(task.everyHours) ore", value: $task.everyHours, in: 1...24)
                } else {
                    HStack {
                        Stepper("Ore \(task.hour)", value: $task.hour, in: 0...23)
                        Stepper("Minuti \(String(format: "%02d", task.minute))", value: $task.minute, in: 0...59, step: 5)
                    }
                    if task.repeatRule == .weekly {
                        Picker("Giorno", selection: $task.weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(["Lunedì", "Martedì", "Mercoledì", "Giovedì", "Venerdì", "Sabato", "Domenica"][day - 1]).tag(day)
                            }
                        }
                    }
                }
                if task.provider == .claude {
                    Picker("Account", selection: $task.accountID) {
                        ForEach(store.accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Permessi", selection: $task.claudeMode) {
                        Text("Accetta modifiche ai file").tag("acceptEdits")
                        Text("Solo piano, nessuna modifica").tag("plan")
                        Text("Nega ciò che chiederebbe conferma").tag("dontAsk")
                        Text("Tutto senza chiedere").tag("bypassPermissions")
                    }
                } else {
                    Picker("Sandbox", selection: $task.codexSandbox) {
                        ForEach(LiveChat.CodexSandbox.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }
            .formStyle(.grouped)
            // A grouped form insets itself by 20 pt: taken back so it lines up with the title
            // and the box below. Sized to its rows, so it never scrolls.
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)   // the taken-back margin must not cover the title
            .frame(height: 40 + 37.4 * CGFloat(formRows))
            .padding(-20)
            PlaceholderTextEditor(placeholder: "Cosa deve fare, ogni volta", text: $task.prompt)
                .frame(minHeight: 90)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            Text("Nessuno risponde alle domande durante un'attività: i permessi scelti qui valgono per tutta l'esecuzione.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salva") { onSave(task); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || task.folder.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620, height: 680)
    }
}
