import SwiftUI
import AppKit
import SwiftTerm

/// A real terminal (zsh) inside OpenBoard, opened in the chat's folder. One per folder, kept
/// alive while you look at other chats, like OpenChamber's terminal dock.
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()
    private var views: [String: LocalProcessTerminalView] = [:]

    func view(for folder: String) -> LocalProcessTerminalView {
        if let existing = views[folder] { return existing }
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(Theme.cardBackground)
        terminal.nativeForegroundColor = .labelColor
        terminal.caretColor = NSColor(Theme.accent)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "it_IT.UTF-8"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(executable: shell, args: ["-l"],
                              environment: environment.map { "\($0.key)=\($0.value)" },
                              execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                              currentDirectory: folder)
        views[folder] = terminal
        return terminal
    }

    func close(_ folder: String) {
        views[folder]?.terminate()
        views[folder] = nil
    }

    func closeAll() {
        for view in views.values { view.terminate() }
        views.removeAll()
    }
}

struct TerminalPanel: NSViewRepresentable {
    let folder: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    /// The terminal view is shared per folder: move it into whichever container shows it.
    private func attach(to container: NSView) {
        let terminal = TerminalStore.shared.view(for: folder)
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}

/// Header strip + terminal, shown under the chat.
struct TerminalDock: View {
    let folder: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(folder.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    TerminalStore.shared.close(folder)
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Chiudi il terminale (termina la shell)")
                Button(action: onClose) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Nascondi (⌘J): la shell resta aperta")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            TerminalPanel(folder: folder)
        }
        .background(Theme.cardBackground)
    }
}
