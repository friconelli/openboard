import SwiftUI
import AppKit

/// Files a chat changed, read from its transcript (Edit, MultiEdit, Write, NotebookEdit).
enum ChangedFiles {
    struct Edit: Sendable {
        let tool: String
        let old: String
        let new: String
    }

    struct File: Identifiable, Sendable {
        let path: String
        var edits: [Edit]
        var lastChange: Date?
        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    static func scan(_ url: URL) -> [File] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        var files: [String: File] = [:]
        let needle = Array(#""tool_use""#.utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { line, length in
                guard ChatIndexer.contains(line, length, needle),
                      let json = (try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length))) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let blocks = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
                let date = (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let tool = block["name"] as? String, editTools.contains(tool),
                          let input = block["input"] as? [String: Any],
                          let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) else { continue }
                    var file = files[path] ?? File(path: path, edits: [], lastChange: nil)
                    switch tool {
                    case "MultiEdit":
                        for edit in input["edits"] as? [[String: Any]] ?? [] {
                            file.edits.append(Edit(tool: tool, old: edit["old_string"] as? String ?? "", new: edit["new_string"] as? String ?? ""))
                        }
                    case "Write":
                        file.edits.append(Edit(tool: tool, old: "", new: input["content"] as? String ?? ""))
                    case "NotebookEdit":
                        file.edits.append(Edit(tool: tool, old: "", new: input["new_source"] as? String ?? ""))
                    default:
                        file.edits.append(Edit(tool: tool, old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? ""))
                    }
                    file.lastChange = date ?? file.lastChange
                    files[path] = file
                }
            }
        }
        return files.values.sorted { ($0.lastChange ?? .distantPast) > ($1.lastChange ?? .distantPast) }
    }

    /// The diff of `path` against the last commit when it is in a git repository, nil otherwise.
    static func gitDiff(for path: String) -> String? {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder),
              Git.run(["rev-parse", "--is-inside-work-tree"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        let tracked = Git.run(["ls-files", "--error-unmatch", path], in: folder) != nil
        if !tracked {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return "nuovo file, non ancora in git\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        let diff = Git.run(["diff", "--no-color", "HEAD", "--", path], in: folder) ?? ""
        return diff.isEmpty ? "" : diff
    }

    /// The edits as a diff-like text, for files outside git.
    static func editsAsDiff(_ file: File) -> String {
        file.edits.map { edit in
            let header = "@@ \(edit.tool) @@"
            let removed = edit.old.isEmpty ? [] : edit.old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
            let added = edit.new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
            return ([header] + removed + added).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// A unified diff with added and removed lines coloured.
struct DiffText: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(background(for: line))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
        .background(Theme.cardBackground)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return Theme.info }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return Theme.success }
        if line.hasPrefix("-") { return Theme.danger }
        return .primary
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Theme.success.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.danger.opacity(0.10) }
        return .clear
    }
}

/// Files a chat changed, each with its diff (from git when possible, otherwise from the edits).
struct ChangedFilesSheet: View {
    let chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var files: [ChangedFiles.File] = []
    @State private var selected: String?
    @State private var diff = ""
    @State private var fromGit = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("File modificati in “\(chat.displayTitle)”", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                EmptyStateView(symbol: "doc", title: "Nessun file modificato", message: "Claude non ha ancora usato Edit o Write in questa chat.")
            } else {
                HSplitView {
                    List(files, selection: $selected) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1)
                            Text(file.path.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text("\(file.edits.count) modific\(file.edits.count == 1 ? "a" : "he")\(file.lastChange.map { " · \(relative($0))" } ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .tag(file.path)
                        .contextMenu {
                            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                            Button("Apri") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
                        }
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    VStack(alignment: .leading, spacing: 0) {
                        if selected != nil {
                            Text(fromGit ? "Differenze rispetto all'ultimo commit" : "Modifiche fatte da Claude (la cartella non è in git)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                            DiffText(text: diff.isEmpty ? "Nessuna differenza: le modifiche sono già nel commit." : diff)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 980, height: 620)
        .task {
            let url = chat.fileURL
            files = await Task.detached { ChangedFiles.scan(url) }.value
            selected = files.first?.path
            loading = false
        }
        .onChange(of: selected) { _, path in
            guard let path, let file = files.first(where: { $0.path == path }) else { return }
            Task {
                let git = await Task.detached { ChangedFiles.gitDiff(for: path) }.value
                fromGit = git != nil
                diff = git ?? ChangedFiles.editsAsDiff(file)
            }
        }
    }
}

/// The conversation as Markdown, for sharing or keeping.
enum MarkdownExport {
    static func markdown(for chat: ChatSession) -> String {
        let messages = TranscriptReader.read(chat.fileURL, limit: 100_000).messages
        var lines = ["# \(chat.displayTitle)", ""]
        if let started = chat.startedAt { lines.append("*\(started.formatted(date: .long, time: .shortened)) · \(chat.workingDirectory)*\n") }
        for message in messages {
            switch message.kind {
            case .user: lines.append("## Tu\n\n\(message.text)\n")
            case .assistant: lines.append("**Claude**\n\n\(message.text)\n")
            case .command: lines.append("`\(message.text)`\n")
            case .tools(let tools): lines.append(tools.map { "> 🔧 \($0)" }.joined(separator: "\n") + "\n")
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func save(_ chat: ChatSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = chat.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(for: chat).write(to: url, atomically: true, encoding: .utf8)
    }
}
