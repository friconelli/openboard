import Foundation

/// The words Claude Code shows while it works ("Razzmatazzing…", "Clauding…", "Pondering…").
///
/// They are picked by the terminal app itself, never sent in its output: OpenBoard reads the same
/// list from the `claude` program installed on this Mac (so it follows its version) and honours
/// the `spinnerVerbs` setting of the account (`{"mode": "append" | "replace", "verbs": [...]}`),
/// like the terminal does. The list is not copied into OpenBoard.
enum SpinnerVerbs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var builtIn: [String]?

    /// A verb for a new turn, or nil when the list can't be read yet.
    static func random(configDir: URL?) -> String? {
        var verbs = loaded() ?? []
        if let custom = customVerbs(configDir) {
            verbs = custom.replace ? (custom.verbs.isEmpty ? verbs : custom.verbs) : verbs + custom.verbs
        }
        return verbs.randomElement()
    }

    /// Reads the list in the background the first time (the program is a few hundred MB).
    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = loaded() }
    }

    private static func loaded() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        if let builtIn { return builtIn }
        let binary = ClaudeAssistant.binaryPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let cacheKey = "spinnerVerbs." + (binary?.lastPathComponent ?? "")
        if let cached = UserDefaults.standard.stringArray(forKey: cacheKey), !cached.isEmpty {
            builtIn = cached
            return cached
        }
        guard let binary, let list = extract(from: binary) else { return nil }
        UserDefaults.standard.set(list, forKey: cacheKey)
        builtIn = list
        return list
    }

    /// Finds the array literal that holds "Clauding" and reads it.
    static func extract(from binary: URL) -> [String]? {
        guard let data = try? Data(contentsOf: binary, options: .alwaysMapped),
              let marker = data.range(of: Data("\"Clauding\",".utf8)) else { return nil }
        let window = 12_000
        let start = max(data.startIndex, marker.lowerBound - window)
        let end = min(data.endIndex, marker.upperBound + window)
        let chunk = data[start..<end]
        guard let open = chunk[..<marker.lowerBound].lastIndex(of: UInt8(ascii: "[")),
              let close = chunk[marker.upperBound...].firstIndex(of: UInt8(ascii: "]")) else { return nil }
        var text = String(decoding: data[open...close], as: UTF8.self)
        // JavaScript escapes (\xE9) are not valid JSON: turn them into é.
        text = text.replacingOccurrences(of: #"\\x([0-9A-Fa-f]{2})"#, with: #"\\u00$1"#, options: .regularExpression)
        guard let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String],
              list.count > 20, list.allSatisfy({ $0.count < 40 }) else { return nil }
        return list
    }

    private static func customVerbs(_ configDir: URL?) -> (replace: Bool, verbs: [String])? {
        let dir = configDir ?? ClaudePaths.home.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let setting = json["spinnerVerbs"] as? [String: Any],
              let verbs = setting["verbs"] as? [String] else { return nil }
        return (setting["mode"] as? String == "replace", verbs)
    }
}
