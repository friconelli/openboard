import SwiftUI

/// What needs attention right now, in one page: sessions waiting for an answer or still working,
/// chats in lavorazione that have stalled, chats that can't be resumed and chats worth slimming.
/// Every row leads to the chat; nothing is changed from here without a click.
struct OverviewView: View {
    @ObservedObject var store: DeckStore
    let onShowChat: (String) -> Void

    private static let stallAfter: TimeInterval = 3 * 24 * 3600

    private var waiting: [ActiveSession] { store.activeSessions.filter { $0.status != "busy" } }
    private var working: [ActiveSession] { store.activeSessions.filter { $0.status == "busy" } }

    private var stalled: [ChatSession] {
        let active = store.activeSessionIDs
        return store.workingChats.filter {
            !active.contains($0.id) && Date().timeIntervalSince($0.modifiedAt) > Self.stallAfter
        }
    }

    /// Chats whose folder is gone: “Riprendi” can't open them until they are moved.
    private var homeless: [ChatSession] {
        store.visibleChats.filter { chat in
            guard let cwd = chat.cwd else { return false }
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) || !isDirectory.boolValue
        }
    }

    private var heavy: [ChatSession] {
        store.visibleChats.filter { store.hasAdvice(for: $0) }
            .sorted { store.contextTokens(for: $0) > store.contextTokens(for: $1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: "square.grid.2x2.fill",
                    tint: Theme.coral,
                    title: "Panoramica",
                    subtitle: waiting.isEmpty && stalled.isEmpty && homeless.isEmpty
                        ? "Niente ti aspetta."
                        : "Cosa chiede la tua attenzione adesso."
                ) { EmptyView() }

                section("Ti aspetta", symbol: "hand.raised.fill", tint: .green,
                        hint: "Sessioni aperte ferme in attesa di una tua risposta",
                        items: waiting.map { session in
                            row(id: session.sessionId, title: title(of: session), detail: "in attesa · \(relative(session.updatedAt ?? session.startedAt))",
                                account: session.accountID, chat: store.chat(id: session.sessionId))
                        })

                section("Al lavoro", symbol: "bolt.fill", tint: .orange,
                        hint: "Claude sta lavorando",
                        items: working.map { session in
                            row(id: session.sessionId, title: title(of: session), detail: "aperta \(relative(session.startedAt))",
                                account: session.accountID, chat: store.chat(id: session.sessionId))
                        })

                section("In lavorazione, ferme", symbol: "flag.fill", tint: .orange,
                        hint: "Chat che segui, non toccate da più di 3 giorni: riprendile o toglile dall'elenco",
                        items: stalled.map { chat in
                            row(id: chat.id, title: chat.displayTitle, detail: "ultima attività \(relative(chat.modifiedAt))", chat: chat) {
                                Button("Togli") { store.setWorking(false, for: [chat]) }
                                    .controlSize(.small)
                                    .help("Togli da In lavorazione: la chat resta dov'è")
                            }
                        })

                section("Da ricollegare", symbol: "folder.badge.questionmark", tint: .red,
                        hint: "La cartella della chat non esiste più: con “Sposta in…” collegala a una che esiste, poi potrai riprenderla",
                        items: homeless.map { chat in
                            row(id: chat.id, title: chat.displayTitle,
                                detail: (chat.cwd ?? "").replacingOccurrences(of: ClaudePaths.home.path, with: "~") + " non esiste", chat: chat)
                        })

                section("Da alleggerire", symbol: "lightbulb.fill", tint: .yellow,
                        hint: "Snellirle fa risparmiare davvero contesto alla ripresa",
                        items: heavy.prefix(8).map { chat in
                            row(id: chat.id, title: chat.displayTitle, detail: relative(chat.modifiedAt), chat: chat)
                        })
            }
            .padding(24)
        }
    }

    private func title(of session: ActiveSession) -> String {
        store.chat(id: session.sessionId)?.displayTitle ?? session.name ?? "Sessione"
    }

    @ViewBuilder
    private func section(_ title: String, symbol: String, tint: Color, hint: String, items: [AnyView]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: Theme.line(symbol)).foregroundStyle(Theme.soft(tint))
                    Text(title).font(.headline)
                    Text("\(items.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .background(Theme.soft(tint).opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.soft(tint))
                }
                .help(hint)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Divider().padding(.leading, 12) }
                            item
                        }
                    }
                }
            }
        }
    }

    private func row(id: String, title: String, detail: String, account: String? = nil, chat: ChatSession?) -> AnyView {
        row(id: id, title: title, detail: detail, account: account, chat: chat) { EmptyView() }
    }

    private func row<Extra: View>(id: String, title: String, detail: String, account: String? = nil, chat: ChatSession?,
                                  @ViewBuilder extra: () -> Extra) -> AnyView {
        AnyView(
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let account = account.flatMap(store.account(id:)) {
                    AccountBadge(account: account, compact: true)
                }
                if let chat, store.contextTokens(for: chat) > 0 {
                    ContextMeter(tokens: store.contextTokens(for: chat), compact: true)
                }
                extra()
                if chat != nil {
                    Button("Apri") { onShowChat(id) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        )
    }
}
