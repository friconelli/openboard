import SwiftUI
import AppKit

/// Thin wrapper around the `git` command line.
enum Git {
    /// Output of `git <arguments>` run in `folder`, nil when git fails.
    static func run(_ arguments: [String], in folder: String) -> String? {
        let result = execute(arguments, in: folder)
        return result.status == 0 ? result.output : nil
    }

    static func execute(_ arguments: [String], in folder: String) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    struct Change: Identifiable, Hashable {
        let path: String
        let code: String
        var id: String { path }
        var label: String {
            switch code.trimmingCharacters(in: .whitespaces) {
            case "M", "MM", "AM": return "modificato"
            case "A": return "aggiunto"
            case "D": return "eliminato"
            case "R": return "rinominato"
            case "??": return "nuovo"
            default: return code
            }
        }
    }

    struct Commit: Identifiable, Hashable {
        let hash: String
        let subject: String
        let author: String
        let date: Date?
        var id: String { hash }
    }

    struct Status {
        var root = ""
        var branch = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes: [Change] = []
        var log: [Commit] = []
    }

    /// nil when `folder` is not inside a git repository.
    static func status(of folder: String) -> Status? {
        guard let root = run(["rev-parse", "--show-toplevel"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var status = Status(root: root)
        let porcelain = run(["status", "--porcelain=v1", "--branch", "-uall"], in: root) ?? ""
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3))
                let parts = header.components(separatedBy: "...")
                status.branch = parts[0].replacingOccurrences(of: "No commits yet on ", with: "")
                if parts.count > 1 {
                    let rest = parts[1]
                    status.upstream = rest.components(separatedBy: " ").first
                    if let ahead = rest.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                        status.ahead = Int(rest[ahead].split(separator: " ").last ?? "") ?? 0
                    }
                    if let behind = rest.range(of: #"behind (\d+)"#, options: .regularExpression) {
                        status.behind = Int(rest[behind].split(separator: " ").last ?? "") ?? 0
                    }
                }
            } else if line.count > 3 {
                let code = String(line.prefix(2))
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                status.changes.append(Change(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), code: code))
            }
        }
        let log = run(["log", "-20", "--format=%H%x1f%s%x1f%an%x1f%cI"], in: root) ?? ""
        status.log = log.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 4 else { return nil }
            return Commit(hash: fields[0], subject: fields[1], author: fields[2], date: ISO8601DateFormatter().date(from: fields[3]))
        }
        return status
    }

    static func diff(_ change: Change, root: String) -> String {
        if change.code == "??" {
            let text = (try? String(contentsOfFile: (root as NSString).appendingPathComponent(change.path), encoding: .utf8)) ?? "(file binario)"
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        return run(["diff", "--no-color", "HEAD", "--", change.path], in: root) ?? ""
    }
}

/// Git for the chat's folder: what changed, a commit (message optionally written by Claude),
/// push and pull, recent history. The OpenChamber git panel, cut down to the daily essentials.
struct GitSheet: View {
    @ObservedObject var store: DeckStore
    let folder: String

    @Environment(\.dismiss) private var dismiss
    @State private var status: Git.Status?
    @State private var loaded = false
    @State private var selected: String?
    @State private var diff = ""
    @State private var message = ""
    @State private var busy: String?
    @State private var output: String?
    @State private var outputIsError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let status {
                HSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        changesList(status)
                        Divider()
                        commitBox(status)
                        Divider()
                        history(status)
                    }
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                    Group {
                        if selected == nil {
                            EmptyStateView(symbol: "doc.text.magnifyingglass", title: "Scegli un file", message: "Le sue differenze rispetto all'ultimo commit compaiono qui.")
                        } else {
                            DiffText(text: diff.isEmpty ? "Nessuna differenza." : diff)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "Non è un repository git",
                               message: "\(folder.replacingOccurrences(of: ClaudePaths.home.path, with: "~")) non è sotto git.")
            }
            if let output {
                Divider()
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(outputIsError ? Theme.danger : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(width: 1040, height: 660)
        .task { await reload() }
        .onChange(of: selected) { _, path in
            guard let path, let status, let change = status.changes.first(where: { $0.path == path }) else { return }
            Task { diff = await Task.detached { Git.diff(change, root: status.root) }.value }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(status?.branch ?? "Git").font(.headline)
                Text((status?.root ?? folder).replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let status, status.upstream != nil {
                Label("\(status.ahead) da inviare", systemImage: "arrow.up").font(.caption).foregroundStyle(status.ahead > 0 ? Theme.warning : .secondary)
                Label("\(status.behind) da ricevere", systemImage: "arrow.down").font(.caption).foregroundStyle(status.behind > 0 ? Theme.warning : .secondary)
            }
            Spacer()
            if let busy { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }
            if status != nil {
                Button { run("Pull", ["pull", "--ff-only"]) } label: { Label("Pull", systemImage: "arrow.down") }
                    .disabled(busy != nil)
                Button { run("Push", ["push"]) } label: { Label("Push", systemImage: "arrow.up") }
                    .disabled(busy != nil || (status?.ahead ?? 0) == 0 && status?.upstream != nil)
                    .help(status?.upstream == nil ? "Il ramo non ha un remoto: verrà provato git push" : "Invia i commit al remoto")
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Aggiorna")
            }
            Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(14)
    }

    private func changesList(_ status: Git.Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.changes.isEmpty ? "Nessuna modifica" : "\(status.changes.count) file modificati")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10)
            List(status.changes, selection: $selected) { change in
                HStack(spacing: 6) {
                    Text(change.code.trimmingCharacters(in: .whitespaces))
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(change.code == "??" ? Theme.success : change.code.contains("D") ? Theme.danger : Theme.warning)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(URL(fileURLWithPath: change.path).lastPathComponent).lineLimit(1)
                        Text(change.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .tag(change.path)
                .help(change.label)
            }
            .listStyle(.inset)
        }
        .frame(maxHeight: .infinity)
    }

    private func commitBox(_ status: Git.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaceholderTextEditor(placeholder: "Messaggio del commit", text: $message, padding: 6)
                .frame(height: 64)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            HStack {
                Button {
                    writeMessage(status)
                } label: {
                    Label("Scrivi con Claude", systemImage: "sparkles")
                }
                .disabled(status.changes.isEmpty || busy != nil)
                .help("Haiku legge le differenze e propone il messaggio")
                Spacer()
                Button("Commit di tutto") { commitAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(status.changes.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy != nil)
                    .help("git add -A e git commit con questo messaggio")
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func history(_ status: Git.Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ultimi commit").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(status.log) { commit in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(commit.subject).font(.caption).lineLimit(2)
                            Text("\(commit.hash.prefix(7)) · \(commit.author) · \(relative(commit.date))")
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(height: 170)
    }

    // MARK: - Actions

    private func reload() async {
        let folder = folder
        status = await Task.detached { Git.status(of: folder) }.value
        loaded = true
        if let selected, !(status?.changes.contains { $0.path == selected } ?? false) { self.selected = nil }
        if selected == nil { selected = status?.changes.first?.path }
    }

    private func run(_ label: String, _ arguments: [String]) {
        guard let root = status?.root else { return }
        busy = "\(label)…"
        Task {
            let result = await Task.detached { Git.execute(arguments, in: root) }.value
            busy = nil
            outputIsError = result.status != 0
            let text = (result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            output = text.isEmpty ? "\(label) completato" : text
            await reload()
        }
    }

    private func commitAll() {
        guard let root = status?.root else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = "Commit…"
        Task {
            let add = await Task.detached { Git.execute(["add", "-A"], in: root) }.value
            let result = add.status == 0 ? await Task.detached { Git.execute(["commit", "-m", text], in: root) }.value : add
            busy = nil
            outputIsError = result.status != 0
            output = (result.output + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0 { message = "" }
            await reload()
        }
    }

    private func writeMessage(_ status: Git.Status) {
        busy = "Claude scrive il messaggio…"
        let root = status.root
        Task {
            let stat = await Task.detached { Git.run(["diff", "HEAD", "--stat"], in: root) ?? "" }.value
            let diff = await Task.detached { Git.run(["diff", "HEAD", "--no-color"], in: root) ?? "" }.value
            let untracked = status.changes.filter { $0.code == "??" }.map(\.path).joined(separator: ", ")
            let recent = status.log.prefix(5).map(\.subject).joined(separator: "\n")
            do {
                let answer = try await ClaudeAssistant.ask("""
                Scrivi il messaggio di commit per queste modifiche. Segui lo stile dei commit recenti del \
                repository (lingua e forma). Prima riga breve (max 72 caratteri), poi se serve una riga vuota e \
                un elenco puntato. Rispondi SOLO con il messaggio.

                Commit recenti:
                \(recent)

                File nuovi: \(untracked.isEmpty ? "nessuno" : untracked)

                Riepilogo:
                \(stat)

                Differenze:
                \(diff.prefix(40_000))
                """, account: store.preferredAccount)
                message = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                outputIsError = true
                output = error.localizedDescription
            }
            busy = nil
        }
    }
}
