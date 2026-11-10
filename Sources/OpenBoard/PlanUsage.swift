import SwiftUI

/// How much of the Claude plan each account has used: the 5-hour session and the week, with
/// when each resets. Read from Claude Code's own `/usage`, which in print mode answers locally
/// (no model turn, no cost) and with `--no-session-persistence` leaves no chat behind.
enum PlanUsage {
    struct Window: Equatable {
        var percent: Int
        var resets: Date?
    }

    struct Snapshot: Equatable {
        var session: Window?
        var week: Window?
        /// Other weekly limits Claude Code lists (per model), by label.
        var others: [String: Window] = [:]
        var updated = Date()
    }

    static func fetch(_ account: ClaudeAccount) async throws -> Snapshot {
        guard let binary = ClaudeAssistant.binaryPath else { throw ChatOperationError.io("Non trovo il comando claude") }
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-p", "/usage", "--no-session-persistence", "--output-format", "json"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment = ProcessInfo.processInfo.environment
            if !account.isDefault { environment["CLAUDE_CONFIG_DIR"] = account.configDir.path }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = json["result"] as? String else {
                throw ChatOperationError.io("/usage non ha risposto")
            }
            let snapshot = parse(text)
            guard snapshot.session != nil || snapshot.week != nil else {
                throw ChatOperationError.io(String(text.prefix(200)))
            }
            return snapshot
        }.value
    }

    /// Lines like “Current session: 22% used · resets Nov 9 at 1:59pm (Europe/Rome)” and
    /// “Current week (all models): 70% used · resets Nov 10 at 7:59pm (Europe/Rome)”.
    static func parse(_ text: String, now: Date = Date()) -> Snapshot {
        var snapshot = Snapshot()
        let pattern = #"^Current (session|week(?: \(([^)]*)\))?):\s*(\d+)% used(?:\s*·\s*resets\s+(.+?))?(?:\s*\(([^)]+)\))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return snapshot }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
            guard let kind = group(1), let percent = group(3).flatMap(Int.init) else { continue }
            let zone = group(5).flatMap(TimeZone.init(identifier:)) ?? .current
            let window = Window(percent: percent, resets: group(4).flatMap { date(from: $0, zone: zone, now: now) })
            if kind == "session" {
                snapshot.session = window
            } else if let label = group(2), label != "all models" {
                snapshot.others[label] = window
            } else {
                snapshot.week = window
            }
        }
        return snapshot
    }

    static func date(from text: String, zone: TimeZone, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let cleaned = text.trimmingCharacters(in: .whitespaces)

        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, h:mma", "MMM d"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: cleaned) else { continue }
            var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            parts.year = calendar.component(.year, from: now)
            guard var result = calendar.date(from: parts) else { continue }
            // The year isn't written: a date well in the past belongs to next year.
            if result < now.addingTimeInterval(-86_400) { result = calendar.date(byAdding: .year, value: 1, to: result) ?? result }
            return result
        }
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: cleaned) else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            guard var result = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now) else { continue }
            if result < now { result = calendar.date(byAdding: .day, value: 1, to: result) ?? result }
            return result
        }
        return nil
    }

    enum Pace { case fine, fast, tooFast }

    /// Where usage is heading at the current rate: fine, a bit fast (close to the limit at the
    /// reset) or too fast (the limit comes before the reset, at `exhausted`).
    static func pace(_ window: Window, hours: Double, now: Date = Date()) -> (pace: Pace, exhausted: Date?)? {
        guard let resets = window.resets, window.percent > 0 else { return nil }
        let total = hours * 3600
        let remaining = max(0, resets.timeIntervalSince(now))
        let elapsed = total - remaining
        guard elapsed > total * 0.05, window.percent < 100 else { return nil }
        let rate = Double(window.percent) / elapsed            // % per second
        let atReset = Double(window.percent) + rate * remaining
        if atReset <= 85 { return (.fine, nil) }
        if atReset <= 100 { return (.fast, nil) }
        return (.tooFast, now.addingTimeInterval((100 - Double(window.percent)) / rate))
    }

    /// “tra 1 h 12 min”, “tra 3 gg”.
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "tra \(days) g \(hours) h" : "tra \(days) g" }
        if hours > 0 { return "tra \(hours) h \(minutes) min" }
        return minutes > 0 ? "tra \(minutes) min" : "a momenti"
    }
}

/// Plan usage of every account, always on screen at the bottom of the sidebar.
struct PlanUsagePanel: View {
    @ObservedObject var store: DeckStore
    @AppStorage("usagePanelCollapsed") private var collapsed = false

    var body: some View {
        // The default ~/.claude is usually the same login as one of the named accounts.
        let named = store.accounts.filter { !$0.isDefault }
        let accounts = (named.isEmpty ? store.accounts : named).filter { store.planUsage[$0.id] != nil }
        let codex = store.planUsage[DeckStore.codexUsageKey]
        if !accounts.isEmpty || codex != nil {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    header(accounts: accounts, codex: codex)
                    if !collapsed {
                    ForEach(accounts) { account in
                        if let usage = store.planUsage[account.id] {
                            block(account.name, tint: Theme.color(forAccount: account.name), usage, now: context.date)
                        }
                    }
                    if let codex {
                        block("Codex", tint: Theme.soft(.blue), codex, now: context.date)
                            .help("Dall'ultima sessione di Codex, aggiornato \(relative(codex.updated))")
                    }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                .padding(12)
            }
            .contextMenu { Button("Aggiorna consumo") { store.refreshPlanUsage(force: true) } }
            .help("Consumo del piano Claude letto da /usage, aggiornato ogni 5 minuti. Clic destro per aggiornare ora.")
        }
    }

    /// Always visible: click to fold the panel down to the 5-hour figure of each account.
    private func header(accounts: [ClaudeAccount], codex: PlanUsage.Snapshot?) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text("Consumo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if collapsed {
                    ForEach(accounts) { account in
                        if let usage = store.planUsage[account.id] { compact(account.name, usage) }
                    }
                    if let codex { compact("Codex", codex) }
                }
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Espandi il consumo del piano" : "Comprimi il consumo del piano")
    }

    private func compact(_ name: String, _ usage: PlanUsage.Snapshot) -> some View {
        let percent = max(usage.session?.percent ?? 0, usage.week?.percent ?? 0)
        let tint = percent < 60 ? Theme.success : percent < 85 ? Theme.warning : Theme.danger
        return HStack(spacing: 3) {
            Text(name).foregroundStyle(.secondary)
            Text("\(percent)%").fontWeight(.semibold).foregroundStyle(tint)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .help("\(name): 5 ore \(usage.session?.percent ?? 0)%, settimana \(usage.week?.percent ?? 0)%")
    }

    private func block(_ name: String, tint: Color, _ usage: PlanUsage.Snapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            if let session = usage.session { bar("5h", session, now: now); paceLine(session, hours: 5, now: now) }
            if let week = usage.week { bar("Sett.", week, now: now); paceLine(week, hours: 168, now: now) }
        }
    }

    @ViewBuilder
    private func paceLine(_ window: PlanUsage.Window, hours: Double, now: Date) -> some View {
        if let pace = PlanUsage.pace(window, hours: hours, now: now), pace.pace != .fine {
            Text(pace.exhausted.map { "ritmo troppo alto: finisce \(PlanUsage.countdown(to: $0, now: now))" } ?? "ritmo un po' alto")
                .font(.caption2)
                .foregroundStyle(pace.pace == .tooFast ? Theme.danger : Theme.warning)
                .padding(.leading, 36)
                .help("Al ritmo di consumo di adesso, prima che il limite si azzeri")
        }
    }

    private func bar(_ label: String, _ window: PlanUsage.Window, now: Date) -> some View {
        let fraction = min(1, Double(window.percent) / 100)
        let tint = fraction < 0.6 ? Theme.success : fraction < 0.85 ? Theme.warning : Theme.danger
        // One line per limit: label, bar, percentage, time to reset.
        return HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(3, geometry.size.width * fraction))
                }
            }
            .frame(height: 5)
            Text("\(window.percent)%")
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
            if let resets = window.resets {
                Text(PlanUsage.countdown(to: resets, now: now).replacingOccurrences(of: "tra ", with: ""))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
                    .help("Si azzera \(resets.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))")
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
    }
}
