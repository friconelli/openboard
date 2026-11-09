import SwiftUI
import AppKit

/// “Su cosa lavoriamo?”: folder, account, model and first message for a new chat, started in
/// OpenBoard (or in the terminal). Modelled on OpenChamber's empty chat with its draft presets.
struct NewChatSheet: View {
    @ObservedObject var store: DeckStore
    var initialFolder: String?
    let onStarted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder: String?
    @State private var search = ""
    @State private var message = ""
    @State private var accountID: String?
    @State private var model: String?
    @State private var mode: LiveChat.PermissionMode = .manual
    @State private var inTerminal = false
    @FocusState private var messageFocused: Bool

    private struct Preset: Identifiable {
        let title: String
        let symbol: String
        let text: String
        var id: String { title }
    }

    private let presets = [
        Preset(title: "Esplora il progetto", symbol: "map",
               text: "Esplora questa cartella e spiegami com'è organizzata: a cosa serve, file principali, come si avvia e cosa andrebbe sistemato."),
        Preset(title: "Riprendiamo", symbol: "arrow.uturn.backward",
               text: "Guarda lo stato attuale di questa cartella (file modificati di recente, git status e ultimi commit se c'è un repo) e dimmi a che punto siamo e cosa resta da fare."),
        Preset(title: "Valuta le opzioni", symbol: "scale.3d",
               text: "Devo decidere come fare questa cosa: …\nProponimi 2 o 3 strade con pro e contro e dimmi quale sceglieresti."),
        Preset(title: "Correggi un problema", symbol: "ladybug",
               text: "C'è un problema: …\nTrova la causa prima di cambiare qualcosa, poi proponimi la correzione."),
        Preset(title: "Rivedi le modifiche", symbol: "checklist",
               text: "Rivedi le modifiche non ancora committate in questa cartella: bug, casi limite, cose da semplificare."),
    ]

    private let models: [(String, String?)] = [("Predefinito", nil), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku")]

    private var folderChoices: [(path: String, detail: String, symbol: String)] {
        var seen: Set<String> = []
        var list: [(String, String, String)] = []
        for recent in store.recentFolders.prefix(12) where seen.insert(recent.path).inserted {
            list.append((recent.path, "\(recent.count) chat · \(relative(recent.last))", "clock"))
        }
        for area in store.areas where seen.insert(area.path).inserted {
            list.append((area.path, "area\(area.context.map { " · \($0)" } ?? "")", "tray"))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { $0.0.localizedCaseInsensitiveContains(query) }
    }

    private var folderName: String {
        folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Su cosa lavoriamo\(folder == nil ? "?" : " in \(folderName)?")")
                .font(.title2.bold())

            HStack(alignment: .top, spacing: 18) {
                folderPicker
                    .frame(width: 280)
                VStack(alignment: .leading, spacing: 12) {
                    messageEditor
                    presetsRow
                    optionsRow
                }
            }

            HStack {
                Picker("", selection: $inTerminal) {
                    Text("In OpenBoard").tag(false)
                    Text("In \(Launcher.terminalName)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Dove far partire la chat")
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(inTerminal ? "Apri in \(Launcher.terminalName)" : "Inizia") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(folder == nil || (!inTerminal && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 860, height: 520)
        .onAppear {
            folder = initialFolder ?? store.recentFolders.first?.path
            accountID = store.preferredAccount?.id
            messageFocused = true
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cartella").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtra", text: $search).textFieldStyle(.plain)
            }
            .padding(7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(folderChoices, id: \.path) { choice in
                        Button {
                            folder = choice.path
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: choice.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(fileURLWithPath: choice.path).lastPathComponent).lineLimit(1)
                                    Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(folder == choice.path ? Theme.accent.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(choice.path)
                    }
                }
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Scegli"
                panel.directoryURL = URL(fileURLWithPath: folder ?? store.config.projectsRoot)
                if panel.runModal() == .OK, let url = panel.url { folder = url.path }
            } label: {
                Label("Altra cartella…", systemImage: "folder.badge.plus")
            }
            .controlSize(.small)
            if let folder {
                Text(folder.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var messageEditor: some View {
        PlaceholderTextEditor(placeholder: inTerminal ? "Primo messaggio (facoltativo)" : "Cosa deve fare Claude?", text: $message)
            .focused($messageFocused)
        .frame(minHeight: 200)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(messageFocused ? Theme.accent.opacity(0.45) : Theme.hairline))
    }

    private var presetsRow: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(presets) { preset in
                Button {
                    message = preset.text
                    messageFocused = true
                } label: {
                    Label(preset.title, systemImage: preset.symbol)
                }
                .secondaryButton()
                .controlSize(.small)
                .help(preset.text)
            }
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            Picker("Account", selection: $accountID) {
                ForEach(store.accounts) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Account")
            Image(systemName: "cpu").foregroundStyle(.secondary).padding(.leading, 6)
            Picker("Modello", selection: $model) {
                ForEach(models, id: \.0) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Modello")
            if !inTerminal {
                Image(systemName: "shield").foregroundStyle(.secondary).padding(.leading, 6)
                Picker("Permessi", selection: $mode) {
                    ForEach(LiveChat.PermissionMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help(mode.detail)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func start() {
        guard let folder else { return }
        let account = accountID.flatMap(store.account(id:))
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if inTerminal {
            guard let account else { return }
            if text.isEmpty {
                store.newChat(in: folder, with: account)
            } else {
                store.handle(Launcher.newChat(in: folder, account: account, model: model, prompt: text))
            }
            dismiss()
            return
        }
        let chat = store.startLiveChat(in: folder, account: account, model: model, mode: mode, message: text)
        onStarted(chat.id)
        dismiss()
    }
}
