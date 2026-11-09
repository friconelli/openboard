import SwiftUI
import AppKit

enum Theme {
    /// “Caldo”: dark, warm and inky, after OpenChamber's default theme (OKLCH-harmonised neutrals
    /// with an orange accent). “Sistema”: macOS light/dark with the original coral.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, warm
        var id: String { rawValue }
        var title: String { self == .system ? "Originale" : "Caldo" }
    }

    /// Light, dark or whatever macOS is using; independent of the palette.
    enum Mode: String, CaseIterable, Identifiable {
        case auto, light, dark
        static let key = "colorMode"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatico"
            case .light: return "Chiaro"
            case .dark: return "Scuro"
            }
        }
        var scheme: ColorScheme? {
            switch self {
            case .auto: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    static let appearanceKey = "appearance"
    static var appearance: Appearance {
        // "warm" was the dark-only theme of the first version: it is now the warm palette.
        Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }
    static var isWarm: Bool { appearance == .warm }

    static func hex(_ value: UInt32, alpha: Double = 1) -> Color { Color(nsColor: nsHex(value, alpha: alpha)) }

    private static func nsHex(_ value: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// A colour that follows light and dark mode, from OpenChamber's warm light and dark palettes.
    static func warm(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsHex(dark, alpha: alpha) : nsHex(light, alpha: alpha)
        })
    }

    static var coral: Color { isWarm ? warm(light: 0xB35017, dark: 0xDA7C47) : Color(red: 0.85, green: 0.47, blue: 0.34) }
    static var accent: Color { coral }
    static var clay: Color { isWarm ? warm(light: 0x8A3A10, dark: 0xA8522A) : Color(red: 0.60, green: 0.26, blue: 0.20) }
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [coral, clay], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var cardBackground: Color { isWarm ? warm(light: 0xFFFFFF, dark: 0x1B1918) : Color(nsColor: .controlBackgroundColor) }
    /// Page background; nil leaves the system one.
    static var pageBackground: Color? { isWarm ? warm(light: 0xFDFCFA, dark: 0x120F0E) : nil }
    static var sidebarBackground: Color? { isWarm ? warm(light: 0xF3F2F0, dark: 0x0E0C0B) : nil }
    static var hairline: Color { isWarm ? warm(light: 0xE6E3DE, dark: 0x242323, alpha: 0.75) : Color.primary.opacity(0.08) }
    static let cardRadius: CGFloat = 16

    // Muted status colours (OpenChamber's success/warning/error/info tokens, light and dark).
    static var success: Color { warm(light: 0x5E8F3A, dark: 0x76AD4F) }
    static var warning: Color { warm(light: 0xA86A0E, dark: 0xC67F13) }
    static var danger: Color { warm(light: 0xB8483A, dark: 0xDA5B4A) }
    static var info: Color { warm(light: 0x3A80BC, dark: 0x479FE6) }

    /// Dusty versions of the system colours, used for icons and badges.
    static let dusty: [Color] = [
        warm(light: 0x4F8A8B, dark: 0x6FA8A9),   // teal
        warm(light: 0xB0703A, dark: 0xC98C55),   // amber
        warm(light: 0x6E8F55, dark: 0x8AAA6E),   // sage
        warm(light: 0x8A6FA8, dark: 0xA48BC0),   // lavender
        warm(light: 0x5B7FA8, dark: 0x7C9CC2),   // slate blue
        warm(light: 0xA86A7F, dark: 0xC28A9C),   // rose
        warm(light: 0x8C7A62, dark: 0xA8977E),   // taupe
    ]

    /// The outline version of an SF Symbol: OpenChamber draws line icons (Remix Icon), filled
    /// shapes only for status.
    static func line(_ symbol: String) -> String {
        let outline = symbol.replacingOccurrences(of: ".fill", with: "")
        return NSImage(systemSymbolName: outline, accessibilityDescription: nil) != nil ? outline : symbol
    }

    /// The dusty counterpart of a system colour, so tints stay recognisable but quieter.
    static func soft(_ color: Color) -> Color {
        switch color {
        case .teal, .mint, .cyan: return dusty[0]
        case .orange, .yellow, .brown: return dusty[1]
        case .green: return dusty[2]
        case .purple, .indigo: return dusty[3]
        case .blue: return dusty[4]
        case .pink, .red: return dusty[5]
        case .gray: return dusty[6]
        default: return color
        }
    }

    static func color(forContext context: String) -> Color {
        switch context.lowercased() {
        case "personale", "personal": return dusty[5]
        case "lavoro", "work", "studiogusto": return dusty[3]
        default:
            return dusty[context.unicodeScalars.reduce(0) { $0 + Int($1.value) } % dusty.count]
        }
    }

    static func symbol(forContext context: String) -> String {
        switch context.lowercased() {
        case "personale", "personal": return "person.fill"
        case "lavoro", "work", "studiogusto": return "building.2.fill"
        default: return "square.stack.fill"
        }
    }

    /// Stable colour per account name.
    static func color(forAccount name: String) -> Color {
        let palette: [Color] = [dusty[4], dusty[3], dusty[0], dusty[5], dusty[2], dusty[1]]
        if name == "predefinito" { return dusty[6] }
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

struct AccountBadge: View {
    let account: ClaudeAccount
    var compact = false

    var body: some View {
        let color = Theme.color(forAccount: account.name)
        Label(account.name, systemImage: "person.crop.circle")
            .labelStyle(.titleAndIcon)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1 : 2)
            .background(color.opacity(0.11), in: Capsule())
            .foregroundStyle(color)
            .help(account.email ?? account.name)
    }
}

struct ContextBadge: View {
    let context: String?

    var body: some View {
        if let context {
            Label(context, systemImage: Theme.symbol(forContext: context))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.color(forContext: context).opacity(0.11), in: Capsule())
                .foregroundStyle(Theme.color(forContext: context))
        } else {
            Label("Da assegnare", systemImage: "tray")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusDot: View {
    let busy: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(busy ? Theme.warning : Theme.success)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(busy ? Theme.warning : Theme.success, lineWidth: 2)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(pulse ? 0 : 0.7)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

// MARK: - Building blocks

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    /// A quiet tile: the tint as a light wash with the glyph in the tint, instead of a solid
    /// gradient block, so a page full of icons doesn't shout.
    var body: some View {
        let color = Theme.soft(tint)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: Theme.line(symbol))
                    .font(.system(size: size * 0.44, weight: .regular))
                    .foregroundStyle(color)
            )
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// Header shared by detail pages: icon tile, title, badge and explanation.
struct PageHeader<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.bold())
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.brandGradient)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SelectionCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}

/// Floating bottom bar for the destructive "move to Trash" action.
struct ActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let bar = HStack(spacing: 12) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

        Group {
            if #available(macOS 26.0, *) {
                bar.glassEffect(.regular, in: Capsule())
            } else {
                bar
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

extension View {
    /// Prominent button style: Liquid Glass on macOS 26, bordered prominent before.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryButton() -> some View {
        if #available(macOS 26.0, *) {
            // Neutral glass: the window tint is for prominent actions only.
            self.buttonStyle(.glass).tint(nil)
        } else {
            self.buttonStyle(.bordered).tint(nil)
        }
    }
}


/// Lays children out left to right and wraps to a new line when the row is full, so nothing is squeezed or truncated.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            // An item wider than the row (a long path) is given the row and truncates itself.
            if width.isFinite, size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if used > 0, used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((index, size))
            used += (used > 0 ? spacing : 0) + size.width
        }
        return rows
    }
}

/// How much of Claude's context window a chat fills when it is resumed: a small bar plus the
/// figure, green under half, orange towards the auto-compaction point, red beyond it.
struct ContextMeter: View {
    let tokens: Int
    /// nil: 200k, or 1M once the chat is past 200k (it could only get there on a 1M-context model).
    var window: Int? = nil
    var compact = false

    private var limit: Int { window ?? (tokens > 200_000 ? 1_000_000 : 200_000) }

    private var fraction: Double { min(1, Double(tokens) / Double(limit)) }
    private var tint: Color { fraction < 0.5 ? Theme.success : fraction < 0.8 ? Theme.warning : Theme.danger }

    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: compact ? 36 : 56, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(3, (compact ? 36 : 56) * fraction), height: 5)
                }
            Text(Self.format(tokens))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("Circa \(Self.format(tokens)) token di contesto su \(Self.format(limit)) (\(Int(fraction * 100))%)")
    }

    static func format(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
            : tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
    }
}

/// Bottom toast for the last undoable operation: message, “Annulla” and a bar that runs out.
struct UndoToast: View {
    let action: UndoAction
    let onUndo: () -> Void
    let onClose: () -> Void

    static let duration: TimeInterval = 10
    @State private var remaining: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text(action.message)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Annulla", action: onUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .fontWeight(.semibold)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            GeometryReader { geometry in
                Capsule().fill(Theme.accent.opacity(0.6))
                    .frame(width: geometry.size.width * remaining, height: 2)
            }
            .frame(height: 2)
        }
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .task(id: action.id) {
            remaining = 1
            withAnimation(.linear(duration: Self.duration)) { remaining = 0 }
            try? await Task.sleep(for: .seconds(Self.duration))
            if !Task.isCancelled { onClose() }
        }
    }
}

/// OpenChamber-style context ring: 18 pt, 2 pt stroke, track at 30%, green/orange/red.
struct ContextRing: View {
    let tokens: Int
    var size: CGFloat = 18

    private var limit: Int { tokens > 200_000 ? 1_000_000 : 200_000 }
    private var fraction: Double { min(1, Double(tokens) / Double(limit)) }
    private var tint: Color { fraction < 0.5 ? Theme.success : fraction < 0.8 ? Theme.warning : Theme.danger }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .help("Contesto alla ripresa: circa \(ContextMeter.format(tokens)) token su \(ContextMeter.format(limit)) (\(Int(fraction * 100))%)")
    }
}

/// How tall chat rows are: description and badges, or one line like OpenChamber's minimal mode.
enum RowDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    static let key = "rowDensity"
    var id: String { rawValue }
    var title: String { self == .comfortable ? "Dettagliate" : "Compatte" }
}

/// A TextEditor with a placeholder that sits exactly where the caret and the first character go.
/// NSTextView (behind TextEditor) draws text 5 pt in from the left (line fragment padding) and
/// flush with the top; the placeholder gets the same offsets plus the editor's own padding.
struct PlaceholderTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var padding: CGFloat = 8

    private static let lineFragmentPadding: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, padding + Self.lineFragmentPadding)
                    .padding(.trailing, padding)
                    .padding(.top, padding)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(padding)
        }
        .font(.body)
    }
}
