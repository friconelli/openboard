import Foundation

/// A Claude Code skill: a folder with a `SKILL.md` (name and description in the front matter,
/// instructions below). Claude sees every enabled skill's name and description in every chat,
/// and reads the instructions only when it uses the skill: the descriptions are what costs
/// tokens all the time.
struct SkillItem: Identifiable, Hashable {
    enum Source: Hashable {
        case personal
        case project(String)
        case plugin(String)
    }

    var id: String { file.path }
    let name: String
    let description: String
    let body: String
    /// The SKILL.md (in the first account that has it, for personal skills).
    let file: URL
    let source: Source
    var enabled: Bool

    /// What its description adds to every chat.
    var tokens: Int { SkillLibrary.tokens(name: name, description: description) }
}

struct PluginItem: Identifiable, Hashable {
    var id: String { key }
    /// `name@marketplace`, as in settings.json.
    let key: String
    var name: String { String(key.split(separator: "@").first ?? Substring(key)) }
    let skills: [SkillItem]
    var enabled: Bool
    var tokens: Int { skills.reduce(0) { $0 + $1.tokens } }
}

enum SkillLibrary {
    static let disabledFolder = "skills-off"

    static func tokens(name: String, description: String) -> Int {
        // Listed as "- name: description"; long descriptions are cut in the listing.
        (name.count + min(description.count, 1_536) + 6) * 10 / 35
    }

    // MARK: - Reading

    static func parse(_ url: URL) -> (name: String, description: String, body: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var name = url.deletingLastPathComponent().lastPathComponent
        var description = ""
        var body = text
        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                let front = Array(lines[1..<end])
                body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
                var i = 0
                while i < front.count {
                    let line = front[i]
                    if line.hasPrefix("name:") {
                        name = unquote(String(line.dropFirst(5)))
                    } else if line.hasPrefix("description:") {
                        var value = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                        if value.isEmpty || value == ">" || value == "|" || value == ">-" || value == "|-" {
                            var parts: [String] = []
                            while i + 1 < front.count, front[i + 1].hasPrefix(" ") || front[i + 1].isEmpty {
                                i += 1
                                parts.append(front[i].trimmingCharacters(in: .whitespaces))
                            }
                            value = parts.joined(separator: " ")
                        }
                        description = unquote(value)
                    }
                    i += 1
                }
            }
        }
        return (name, description, body)
    }

    private static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
            if first == "\"" { text = text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
            else { text = text.replacingOccurrences(of: "''", with: "'") }
        }
        return text
    }

    private static func skills(in folder: URL, source: SkillItem.Source, enabled: Bool) -> [SkillItem] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            let file = entry.appendingPathComponent("SKILL.md")
            guard let parsed = parse(file) else { return nil }
            return SkillItem(name: parsed.name, description: parsed.description, body: parsed.body, file: file, source: source, enabled: enabled)
        }
    }

    /// Account folders that hold settings and skills, without duplicates.
    static func configDirs(_ accounts: [ClaudeAccount]) -> [URL] {
        var seen = Set<String>()
        return accounts.map { $0.configDir.resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    /// Personal skills, one per name across accounts.
    static func personal(_ accounts: [ClaudeAccount]) -> [SkillItem] {
        var byName: [String: SkillItem] = [:]
        for dir in configDirs(accounts) {
            for skill in skills(in: dir.appendingPathComponent("skills"), source: .personal, enabled: true)
                + skills(in: dir.appendingPathComponent(disabledFolder), source: .personal, enabled: false) {
                if let existing = byName[skill.name], existing.enabled || !skill.enabled { continue }
                byName[skill.name] = skill
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    static func project(_ folders: [String]) -> [SkillItem] {
        folders.flatMap { folder in
            let base = URL(fileURLWithPath: folder).appendingPathComponent(".claude")
            return skills(in: base.appendingPathComponent("skills"), source: .project(folder), enabled: true)
                + skills(in: base.appendingPathComponent(disabledFolder), source: .project(folder), enabled: false)
        }
        .sorted { $0.name < $1.name }
    }

    static func plugins(_ accounts: [ClaudeAccount]) -> [PluginItem] {
        var result: [String: PluginItem] = [:]
        for dir in configDirs(accounts) {
            let installed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("plugins/installed_plugins.json")))) as? [String: Any]
            let plugins = installed?["plugins"] as? [String: [[String: Any]]] ?? [:]
            let enabled = settings(dir)["enabledPlugins"] as? [String: Bool] ?? [:]
            for (key, installs) in plugins {
                guard let path = installs.first?["installPath"] as? String else { continue }
                let skills = skills(in: URL(fileURLWithPath: path).appendingPathComponent("skills"), source: .plugin(key), enabled: true)
                let on = enabled[key] ?? false
                if var existing = result[key] {
                    existing.enabled = existing.enabled || on
                    result[key] = existing
                } else {
                    result[key] = PluginItem(key: key, skills: skills, enabled: on)
                }
            }
        }
        return result.values.sorted { $0.tokens > $1.tokens }
    }

    private static func settings(_ dir: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json")))) as? [String: Any] ?? [:]
    }

    // MARK: - Writing

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    static func document(name: String, description: String, body: String) -> String {
        let oneLine = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let quoted = "\"" + oneLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return "---\nname: \(name)\ndescription: \(quoted)\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Folders a skill with this scope lives in (personal: every account).
    static func homes(for source: SkillItem.Source, accounts: [ClaudeAccount], enabled: Bool) -> [URL] {
        let folder = enabled ? "skills" : disabledFolder
        switch source {
        case .personal: return configDirs(accounts).map { $0.appendingPathComponent(folder) }
        case .project(let path): return [URL(fileURLWithPath: path).appendingPathComponent(".claude/\(folder)")]
        case .plugin: return []
        }
    }

    /// Writes the skill everywhere it belongs; `previous` is removed when it moved or was renamed.
    static func save(name: String, description: String, body: String, source: SkillItem.Source,
                     accounts: [ClaudeAccount], previous: SkillItem?) throws {
        let fm = FileManager.default
        let slug = slug(name)
        guard !slug.isEmpty else { throw ChatOperationError.io("Dai un nome alla skill") }
        let text = document(name: slug, description: description, body: body)
        let enabled = previous?.enabled ?? true
        let targets = homes(for: source, accounts: accounts, enabled: enabled).map { $0.appendingPathComponent(slug) }
        if let previous, previous.name != slug || previous.source != source {
            try remove(previous, accounts: accounts)
        }
        for folder in targets {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
    }

    /// To the Trash, from every account.
    static func remove(_ skill: SkillItem, accounts: [ClaudeAccount]) throws {
        let folderName = skill.file.deletingLastPathComponent().lastPathComponent
        for home in homes(for: skill.source, accounts: accounts, enabled: skill.enabled) {
            let folder = home.appendingPathComponent(folderName)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        }
    }

    /// Off: the folder moves aside (`skills-off`), so Claude doesn't see it; on: it moves back.
    static func setEnabled(_ skill: SkillItem, _ enabled: Bool, accounts: [ClaudeAccount]) throws {
        let fm = FileManager.default
        let folderName = skill.file.deletingLastPathComponent().lastPathComponent
        let from = homes(for: skill.source, accounts: accounts, enabled: skill.enabled)
        let to = homes(for: skill.source, accounts: accounts, enabled: enabled)
        for (source, destination) in zip(from, to) {
            let folder = source.appendingPathComponent(folderName)
            guard fm.fileExists(atPath: folder.path) else { continue }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = destination.appendingPathComponent(folderName)
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.moveItem(at: folder, to: target)
        }
    }

    /// Turns a plugin on or off in every account that has it installed (settings.json, a copy
    /// kept as settings.json.openboard-backup the first time).
    static func setPlugin(_ key: String, enabled: Bool, accounts: [ClaudeAccount]) throws {
        for dir in configDirs(accounts) {
            let installed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("plugins/installed_plugins.json")))) as? [String: Any]
            guard (installed?["plugins"] as? [String: Any])?[key] != nil else { continue }
            let url = dir.appendingPathComponent("settings.json")
            let backup = dir.appendingPathComponent("settings.json.openboard-backup")
            if !FileManager.default.fileExists(atPath: backup.path), FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            var json = settings(dir)
            var plugins = json["enabledPlugins"] as? [String: Bool] ?? [:]
            plugins[key] = enabled
            json["enabledPlugins"] = plugins
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        }
    }

    /// A first draft from a one-line request, written by Haiku.
    static func draft(_ request: String, account: ClaudeAccount?) async throws -> (name: String, description: String, body: String) {
        let prompt = """
            Scrivi una skill per Claude Code a partire da questa richiesta dell'utente:
            «\(request)»

            Rispondi SOLO con un oggetto JSON con tre campi stringa:
            - "name": nome breve in minuscolo con trattini (es. "controllo-seo")
            - "description": una o due frasi che dicono cosa fa e QUANDO usarla (Claude decide da questa se usarla), max 300 caratteri
            - "body": le istruzioni in Markdown, in italiano, concrete e brevi: passi da seguire, cosa controllare, cosa evitare, formato del risultato
            """
        let answer = try await ClaudeAssistant.ask(prompt, account: account)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let json = (try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8))) as? [String: Any] else {
            throw ChatOperationError.io("Claude non ha restituito una bozza leggibile")
        }
        return (json["name"] as? String ?? "", json["description"] as? String ?? "", json["body"] as? String ?? "")
    }
}
