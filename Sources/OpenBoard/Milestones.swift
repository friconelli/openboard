import SwiftUI

/// A goal of a project that every chat started there carries with it: OpenBoard adds the
/// project's milestones to Claude's instructions (`--append-system-prompt`) in the app, in the
/// terminal and for orchestrators and agents.
struct Milestone: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var text: String
    var done = false
}

extension DeckStore {
    /// Milestones of a folder: its own and those of the folders that contain it.
    func milestones(for folder: String) -> [(project: String, milestones: [Milestone])] {
        (config.milestones ?? [:])
            .filter { folder == $0.key || folder.hasPrefix($0.key + "/") }
            .filter { !$0.value.isEmpty }
            .sorted { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value) }
    }

    func ownMilestones(for folder: String) -> [Milestone] { config.milestones?[folder] ?? [] }

    func setMilestones(_ list: [Milestone], for folder: String) {
        var all = config.milestones ?? [:]
        let clean = list.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        all[folder] = clean.isEmpty ? nil : clean
        config.milestones = all
        config.save()
        objectWillChange.send()
    }

    func milestonesPrompt(for folder: String) -> String? {
        let groups = milestones(for: folder)
        guard !groups.isEmpty else { return nil }
        var text = """
            MILESTONE DEL PROGETTO (decise dall'utente in OpenBoard). Tienile presenti in tutto quello che fai: ogni scelta deve andare verso di esse e non contraddirle. Se una richiesta va contro una milestone, fallo notare prima di procedere. Quando una milestone ti sembra raggiunta, dillo all'utente.
            """
        for group in groups {
            text += "\n\nProgetto \(URL(fileURLWithPath: group.project).lastPathComponent):"
            for (index, milestone) in group.milestones.enumerated() {
                text += "\n\(index + 1). [\(milestone.done ? "x" : " ")] \(milestone.text)\(milestone.done ? " (raggiunta)" : "")"
            }
        }
        return text
    }
}

/// Edit the milestones of a project.
struct MilestonesSheet: View {
    @ObservedObject var store: DeckStore
    let folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Milestone] = []
    @State private var newText = ""
    @FocusState private var newFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Milestone di \(URL(fileURLWithPath: folder).lastPathComponent)", systemImage: "flag.checkered")
                    .font(.title2.bold())
                Text("Gli obiettivi che Claude deve tenere presenti in tutto quello che fa in questo progetto: ogni chat, orchestratore e agente li riceve nelle sue istruzioni, anche in \(Launcher.terminalName). Le chat già aperte li prendono dal prossimo messaggio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($items) { $item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $item.done)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .help("Raggiunta")
                            TextField("Milestone", text: $item.text, axis: .vertical)
                                .textFieldStyle(.plain)
                                .strikethrough(item.done)
                                .foregroundStyle(item.done ? .secondary : .primary)
                            Button {
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Togli")
                        }
                        .padding(8)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                        TextField("Nuova milestone, es. “Il sito deve restare veloce su mobile (LCP < 2,5 s)”", text: $newText)
                            .textFieldStyle(.plain)
                            .focused($newFocused)
                            .onSubmit(add)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(minHeight: 180)

            if let inherited = store.milestones(for: folder).first(where: { $0.project != folder }) {
                Text("Valgono anche le \(inherited.milestones.count) milestone di \(URL(fileURLWithPath: inherited.project).lastPathComponent), la cartella che contiene questa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salva") {
                    add()
                    store.setMilestones(items, for: folder)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 480)
        .onAppear {
            items = store.ownMilestones(for: folder)
            newFocused = true
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        items.append(Milestone(text: text))
        newText = ""
    }
}

/// The milestones in short, for the project in focus.
struct MilestonesSummary: View {
    @ObservedObject var store: DeckStore
    let folder: String
    let edit: () -> Void

    var body: some View {
        let list = store.ownMilestones(for: folder)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Milestone", systemImage: "flag.checkered")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !list.isEmpty {
                    Text("\(list.filter(\.done).count)/\(list.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(list.isEmpty ? "Aggiungi" : "Modifica", action: edit)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(list) { milestone in
                Button {
                    var updated = list
                    if let index = updated.firstIndex(where: { $0.id == milestone.id }) { updated[index].done.toggle() }
                    store.setMilestones(updated, for: folder)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: milestone.done ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(milestone.done ? Theme.accent : .secondary)
                        Text(milestone.text)
                            .font(.caption)
                            .strikethrough(milestone.done)
                            .foregroundStyle(milestone.done ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .help(milestone.done ? "Segna come da fare" : "Segna come raggiunta")
            }
        }
    }
}

struct IdentifiedPath: Identifiable {
    let id: String
}

/// Shows the milestones sheet when a project asks for it (`.editMilestones`).
struct MilestonesHost: ViewModifier {
    @ObservedObject var store: DeckStore
    @State private var target: IdentifiedPath?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .editMilestones)) { note in
                target = (note.object as? String).map(IdentifiedPath.init)
            }
            .sheet(item: $target) { target in MilestonesSheet(store: store, folder: target.id) }
    }
}
