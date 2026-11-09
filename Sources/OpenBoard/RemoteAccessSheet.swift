import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// The iPhone link: on/off, the link, a QR code to frame with the camera (⌘L).
struct RemoteAccessSheet: View {
    @ObservedObject private var server = RemoteServer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = RemoteServer.shared.isEnabled
    @State private var copied = false
    @State private var confirmNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "iphone", tint: Theme.coral, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenBoard su iPhone").font(.title3.bold())
                    Text(statusText).font(.callout).foregroundStyle(statusIsBad ? Theme.danger : .secondary)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: enabled) { _, value in server.setEnabled(value) }
            }

            if enabled, server.status == .running, let link = server.link {
                HStack(alignment: .top, spacing: 18) {
                    if let qr = Self.qr(link) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Inquadralo con la fotocamera dell'iPhone").font(.headline)
                        Text("Sull'iPhone serve l'app Tailscale, accesa e con lo stesso account di questo Mac.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Da Safari: Condividi → Aggiungi alla schermata Home, per averla come un'app.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(copied ? "Copiato" : "Copia link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                            Button("Cambia link…") { confirmNew = true }
                                .help("Crea un link nuovo: quello vecchio smette di funzionare e i telefoni collegati vanno ricollegati")
                        }
                    }
                }
                Text(link)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Label("Chi ha questo link può comandare Claude su questo Mac, se è collegato alla tua rete Tailscale. Non condividerlo.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { server.refresh() }
        .alert("Creare un link nuovo?", isPresented: $confirmNew) {
            Button("Crea", role: .destructive) { server.regenerateToken() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Il link attuale smette di funzionare e i telefoni già collegati dovranno riaprire quello nuovo.")
        }
    }

    private var statusIsBad: Bool {
        switch server.status {
        case .noTailscale, .failed: return true
        default: return false
        }
    }

    private var statusText: String {
        switch server.status {
        case .off: return "Spento. Accendilo per controllare le chat dal telefono."
        case .noTailscale: return "Tailscale non è attivo su questo Mac: aprilo e collegati, poi riaccendi."
        case .starting: return "Avvio…"
        case .running: return "Attivo, solo sulla tua rete Tailscale. Il Mac deve restare acceso."
        case .failed(let message): return "Non riesco ad avviarlo: \(message)"
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
