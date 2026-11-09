import SwiftUI

@main
struct OpenBoardApp: App {
    var body: some Scene {
        WindowGroup("OpenBoard") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            DeckCommands()
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") {
                    Task { await Updater.shared.check() }
                }
                Button("Configurazione guidata…") {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
            }
        }
    }
}
