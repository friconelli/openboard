import SwiftUI

extension Notification.Name {
    static let showPalette = Notification.Name("showPalette")
    static let showSection = Notification.Name("showSection")
    static let resetSmartFilters = Notification.Name("resetSmartFilters")
    static let newChat = Notification.Name("newChat")
}

/// Menu bar commands: the palette, jumps to sections and the look of the app.
struct DeckCommands: Commands {
    @AppStorage(Theme.appearanceKey) private var appearance: Theme.Appearance = .system
    @AppStorage(RowDensity.key) private var density: RowDensity = .comfortable
    @AppStorage(Theme.Mode.key) private var mode: Theme.Mode = .auto
    @AppStorage(Notifier.enabledKey) private var notifications = true

    private func go(_ name: String) {
        NotificationCenter.default.post(name: .showSection, object: name)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nuova chat…") { NotificationCenter.default.post(name: .newChat, object: nil) }
                .keyboardShortcut("n")
        }
        CommandMenu("Vai") {
            Button("Cerca chat e comandi…") { NotificationCenter.default.post(name: .showPalette, object: nil) }
                .keyboardShortcut("k")
            Divider()
            Button("Panoramica") { go("overview") }.keyboardShortcut("0")
            Button("Tutte le chat") { go("chats") }.keyboardShortcut("1")
            Button("In lavorazione") { go("working") }.keyboardShortcut("2")
            Button("Consigli") { go("insights") }.keyboardShortcut("3")
            Button("Aree di lavoro") { go("areas") }.keyboardShortcut("4")
            Button("Sessioni attive") { go("active") }.keyboardShortcut("5")
            Divider()
            Button("Nuova chat guidata") { go("compose") }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Picker("Tema", selection: $appearance) {
                ForEach(Theme.Appearance.allCases) { Text($0.title).tag($0) }
            }
            Picker("Chiaro o scuro", selection: $mode) {
                ForEach(Theme.Mode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Righe delle chat", selection: $density) {
                ForEach(RowDensity.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Notifiche (Claude ha finito, chiede un permesso)", isOn: $notifications)
            Button("Mostra i filtri nascosti") { NotificationCenter.default.post(name: .resetSmartFilters, object: nil) }
            Divider()
        }
    }
}

/// ⌘K: jump to any chat or page by typing. ↑↓ to move, ↩ to open, ⌘↩ to resume the chat.
struct CommandPalette: View {
    @ObservedObject var store: DeckStore
    let onSection: (DeckSection) -> Void
    let onChat: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        enum Kind { case section(DeckSection), chat(ChatSession) }
        let id: String
        let title: String
        let subtitle: String?
        let symbol: String
        let tint: Color
        let kind: Kind
    }

    private var sections: [Item] {
        let pages: [(String, String, Color, DeckSection)] = [
            ("Panoramica", "square.grid.2x2.fill", .teal, .overview),
            ("Tutte le chat", "bubble.left.and.bubble.right.fill", Theme.coral, .chats(.all)),
            ("In lavorazione", "flag.fill", .orange, .chats(.working)),
            ("Nuova chat guidata", "sparkles", Theme.coral, .compose),
            ("Consigli", "lightbulb.fill", .yellow, .insights),
            ("Aree di lavoro", "folder.fill", .orange, .areas),
            ("Memoria", "brain.head.profile", .purple, .memory),
            ("Sessioni attive", "bolt.horizontal.fill", .green, .active),
            ("Account", "person.2.fill", .blue, .accounts),
        ] + SmartFilter.allCases.map { ($0.title, $0.symbol, $0.tint, .chats(.smart($0))) }
        return pages.map { Item(id: "s-\($0.0)", title: $0.0, subtitle: nil, symbol: $0.1, tint: $0.2, kind: .section($0.3)) }
    }

    private var items: [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
        let pages = sections.filter { words.isEmpty || matches($0.title) }
        let chats = store.chats
            .filter { chat in
                words.isEmpty || matches("\(chat.displayTitle) \(chat.projectName) \(store.description(for: chat) ?? "") \(chat.id)")
            }
            .sorted { lhs, rhs in
                // Titles that match come before matches in the description.
                let l = words.isEmpty || matches(lhs.displayTitle)
                let r = words.isEmpty || matches(rhs.displayTitle)
                return l != r ? l : lhs.modifiedAt > rhs.modifiedAt
            }
            .prefix(words.isEmpty ? 6 : 30)
            .map { chat in
                Item(id: chat.id, title: chat.displayTitle,
                     subtitle: "\(chat.projectName) · \(relative(chat.modifiedAt))",
                     symbol: store.activeSessionIDs.contains(chat.id) ? "bolt.fill" : "bubble.left",
                     tint: store.activeSessionIDs.contains(chat.id) ? .green : .secondary, kind: .chat(chat))
            }
        return words.isEmpty ? Array(chats) + pages : pages + chats
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca una chat o vai a una pagina", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(list, resume: false) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if list.isEmpty {
                            Text("Nessun risultato")
                                .foregroundStyle(.secondary)
                                .padding(14)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            row(item, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { highlighted = index; open(list, resume: false) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "scegli")
                hint("↩", "apri")
                hint("⌘↩", "riprendi la chat")
                hint("esc", "chiudi")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 620, height: 440)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            open(list, resume: true)
            return .handled
        }
    }

    private func open(_ list: [Item], resume: Bool) {
        guard list.indices.contains(highlighted) else { return }
        switch list[highlighted].kind {
        case .section(let section):
            onSection(section)
        case .chat(let chat):
            if resume, let account = store.preferredAccount {
                store.resume(chat, with: account)
            }
            onChat(chat.id)
        }
        dismiss()
    }

    private func row(_ item: Item, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(item.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if case .chat(let chat) = item.kind, store.contextTokens(for: chat) > 0 {
                ContextRing(tokens: store.contextTokens(for: chat), size: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
