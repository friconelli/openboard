import SwiftUI
import AppKit

/// Skills page: create and edit skills (personal or of a project), and see what the skills and
/// plugins switched on cost in every chat, with a switch for each.
struct SkillsView: View {
    @ObservedObject var store: DeckStore

    private enum Selection: Hashable {
        case skill(String)
        case plugin(String)
        case new
    }

    @State private var personal: [SkillItem] = []
    @State private var projectSkills: [SkillItem] = []
    @State private var plugins: [PluginItem] = []
    @State private var selection: Selection? = .new
    @State private var error: String?

    private var projectFolders: [String] {
        var folders = store.recentFolders.prefix(25).map(\.path)
        if let focus = UserDefaults.standard.string(forKey: "sidebarFocusedProject"), !folders.contains(focus) { folders.insert(focus, at: 0) }
        return folders
    }

    private var tokensPerChat: Int {
        personal.filter(\.enabled).reduce(0) { $0 + $1.tokens } + plugins.filter(\.enabled).reduce(0) { $0 + $1.tokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Not PageHeader: its subtitle takes its full height whatever the width, which on a
            // page without a scroll view set a minimum window height of thousands of points.
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "wand.and.stars", tint: Theme.accent, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skill").font(.title2.bold())
                    Text("Istruzioni che Claude usa quando servono. Il nome e la descrizione di ogni skill attiva entrano in ogni chat: spegni quelle che non usi per consumare meno token.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("~\(tokensPerChat / 1000)k token")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tokensPerChat > 15_000 ? .orange : .primary)
                    Text("in ogni chat da skill e plugin attivi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(width: 330)
                    .frame(minHeight: 0, maxHeight: .infinity)
                Divider()
                detail
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .background(Theme.pageBackground ?? Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .alert("Operazione non riuscita", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func reload() {
        personal = SkillLibrary.personal(store.accounts)
        projectSkills = SkillLibrary.project(projectFolders)
        plugins = SkillLibrary.plugins(store.accounts)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { self.error = error.localizedDescription }
        reload()
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            Button {
                selection = .new
            } label: {
                Label("Nuova skill", systemImage: "plus")
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .tag(Selection.new)

            Section("Personali · tutti gli account") {
                if personal.isEmpty { Text("Nessuna").foregroundStyle(.secondary) }
                ForEach(personal) { skill in
                    skillRow(skill).tag(Selection.skill(skill.id))
                }
            }
            if !projectSkills.isEmpty {
                Section("Dei progetti") {
                    ForEach(projectSkills) { skill in
                        skillRow(skill).tag(Selection.skill(skill.id))
                    }
                }
            }
            Section("Plugin") {
                ForEach(plugins) { plugin in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { plugin.enabled }, set: { on in
                            attempt { try SkillLibrary.setPlugin(plugin.key, enabled: on, accounts: store.accounts) }
                        }))
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .controlSize(.mini)
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name).lineLimit(1)
                            Text("\(plugin.skills.count) skill").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        weight(plugin.tokens, on: plugin.enabled)
                    }
                    .tag(Selection.plugin(plugin.key))
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(Theme.isWarm ? .hidden : .automatic)
    }

    private func skillRow(_ skill: SkillItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { skill.enabled }, set: { on in
                attempt { try SkillLibrary.setEnabled(skill, on, accounts: store.accounts) }
            }))
            .toggleStyle(.switch)
                        .tint(Theme.accent)
            .controlSize(.mini)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name).lineLimit(1)
                if case .project(let folder) = skill.source {
                    Text(URL(fileURLWithPath: folder).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            weight(skill.tokens, on: skill.enabled)
        }
        .help(skill.description)
    }

    private func weight(_ tokens: Int, on: Bool) -> some View {
        Text(tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(on ? .secondary : .tertiary)
            .strikethrough(!on)
            .help("Token che aggiunge a ogni chat\(on ? "" : " (spenta: zero)")")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .plugin(let key):
            if let plugin = plugins.first(where: { $0.key == key }) { PluginDetail(plugin: plugin) }
        case .skill(let id):
            if let skill = (personal + projectSkills).first(where: { $0.id == id }) {
                SkillEditor(store: store, skill: skill, folders: projectFolders) { saved in
                    reload()
                    if let saved { selection = .skill(saved) } else { selection = .new }
                }
                .id(id)
            }
        case .new, .none:
            SkillEditor(store: store, skill: nil, folders: projectFolders) { saved in
                reload()
                if let saved { selection = .skill(saved) }
            }
            .id("new")
        }
    }
}

private struct PluginDetail: View {
    let plugin: PluginItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(plugin.name).font(.title2.bold())
                Text("\(plugin.skills.count) skill · ~\(plugin.tokens) token in ogni chat quando è acceso. Si accende e spegne con l'interruttore nella lista: vale per tutti gli account in cui è installato, dalla prossima chat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(plugin.skills) { skill in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).font(.callout.weight(.semibold))
                        Text(skill.description).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(20)
        }
    }
}

private struct SkillEditor: View {
    @ObservedObject var store: DeckStore
    let skill: SkillItem?
    let folders: [String]
    /// The saved skill's id, or nil after deleting it.
    let done: (String?) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var scope: SkillItem.Source = .personal
    @State private var request = ""
    @State private var drafting = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var canSave: Bool {
        !SkillLibrary.slug(name).isEmpty && !description.trimmingCharacters(in: .whitespaces).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(skill == nil ? "Nuova skill" : skill!.name).font(.title2.bold())

                if skill == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Falla scrivere a Claude").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack {
                            TextField("Cosa deve saper fare? es. “controlla la SEO di una pagina WordPress prima della pubblicazione”", text: $request)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(draft)
                            Button(action: draft) {
                                if drafting { ProgressView().controlSize(.small) } else { Label("Bozza", systemImage: "sparkles") }
                            }
                            .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty || drafting)
                        }
                    }
                    .padding(12)
                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                field("Nome") {
                    TextField("es. controllo-seo", text: $name).textFieldStyle(.roundedBorder)
                    if !name.isEmpty, SkillLibrary.slug(name) != name {
                        Text("Verrà salvata come “\(SkillLibrary.slug(name))”").font(.caption).foregroundStyle(.secondary)
                    }
                }
                field("Quando usarla") {
                    TextField("Cosa fa e quando Claude deve usarla: è l'unica parte che Claude legge sempre", text: $description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Text("~\(SkillLibrary.tokens(name: SkillLibrary.slug(name), description: description)) token in ogni chat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                field("Istruzioni") {
                    PlaceholderTextEditor(placeholder: "Passi da seguire, controlli, cosa evitare, formato del risultato. Claude le legge solo quando usa la skill.", text: $instructions)
                        .frame(minHeight: 220)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                }
                field("Dove") {
                    Picker("", selection: $scope) {
                        Text("Personale (tutti gli account, tutti i progetti)").tag(SkillItem.Source.personal)
                        Divider()
                        ForEach(folders, id: \.self) { folder in
                            Text("Solo nel progetto \(URL(fileURLWithPath: folder).lastPathComponent)").tag(SkillItem.Source.project(folder))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if case .project(let folder) = scope {
                        Text("In \(folder.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))/.claude/skills: se il progetto è in git puoi committarla e la usa chiunque ci lavori.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }

                HStack {
                    if let skill {
                        Button("Elimina", role: .destructive) { confirmDelete = true }
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.file]) }
                    }
                    Spacer()
                    Button(skill == nil ? "Crea skill" : "Salva") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!canSave)
                }
            }
            .padding(20)
        }
        .onAppear {
            guard let skill else { return }
            name = skill.name
            description = skill.description
            instructions = skill.body
            scope = skill.source
        }
        .alert("Eliminare la skill “\(skill?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Sposta nel Cestino", role: .destructive) {
                guard let skill else { return }
                do { try SkillLibrary.remove(skill, accounts: store.accounts); done(nil) } catch { self.error = error.localizedDescription }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Va nel Cestino da tutti gli account.")
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func draft() {
        let text = request.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !drafting else { return }
        drafting = true
        error = nil
        Task {
            do {
                let result = try await SkillLibrary.draft(text, account: store.preferredAccount)
                name = result.name
                description = result.description
                instructions = result.body
            } catch {
                self.error = error.localizedDescription
            }
            drafting = false
        }
    }

    private func save() {
        do {
            try SkillLibrary.save(name: name, description: description, body: instructions, source: scope,
                                  accounts: store.accounts, previous: skill)
            let slug = SkillLibrary.slug(name)
            let home = SkillLibrary.homes(for: scope, accounts: store.accounts, enabled: skill?.enabled ?? true).first
            done(home?.appendingPathComponent(slug).appendingPathComponent("SKILL.md").path)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
