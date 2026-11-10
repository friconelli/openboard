import SwiftUI
import AppKit

/// Text of the terminal style drawn by AppKit's own text view: one selectable block per message
/// (drag across paragraphs, ⌘C, ⌘A inside it), links that open in the browser with a click,
/// bare https:// addresses turned into links. SwiftUI's Text selects one paragraph at a time and
/// leaves bare addresses dead.
struct SelectableText: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Term.link),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: attributed) != true {
            view.textStorage?.setAttributedString(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 600)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        return CGSize(width: width, height: max(height, 1))
    }
}

/// Markdown turned into terminal text: monospaced, bold and italic kept, `code` highlighted,
/// headings bold, bullets indented, code blocks on a darker band, tables in columns.
enum TerminalRender {
    static var font: NSFont { .monospacedSystemFont(ofSize: Term.fontSize, weight: .regular) }
    static var boldFont: NSFont { .monospacedSystemFont(ofSize: Term.fontSize, weight: .bold) }

    static func plain(_ text: String, color: NSColor = NSColor(Term.text)) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph()])
        linkify(result)
        return result
    }

    static func markdown(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = MarkdownView.parse(text)
        for (index, block) in blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n\n", attributes: [.font: font])) }
            switch block {
            case .heading(_, let text):
                out.append(inline(text, base: boldFont))
            case .paragraph(let text):
                out.append(inline(text))
            case .bullet(let items):
                for (i, item) in items.enumerated() {
                    if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
                    let marker = item.marker.trimmingCharacters(in: .whitespaces)
                    let depth = item.marker.prefix { $0 == " " }.count / 2
                    let line = NSMutableAttributedString(string: marker + " ", attributes: [.font: font, .foregroundColor: NSColor(Term.dim)])
                    line.append(inline(item.text))
                    let indent = CGFloat(depth) * 16
                    let width = (marker + " ").size(withAttributes: [.font: font]).width
                    line.addAttribute(.paragraphStyle, value: paragraph(first: indent, head: indent + width), range: NSRange(location: 0, length: line.length))
                    out.append(line)
                }
            case .quote(let text):
                let line = NSMutableAttributedString(string: "▎ ", attributes: [.font: font, .foregroundColor: NSColor(Term.claude)])
                line.append(inline(text, color: NSColor(Term.dim)))
                out.append(line)
            case .code(_, let code):
                out.append(NSAttributedString(string: code, attributes: [
                    .font: font, .foregroundColor: NSColor(Term.text),
                    .backgroundColor: NSColor(Term.promptBackground), .paragraphStyle: paragraph(),
                ]))
            case .table(let rows):
                let columns = rows.map(\.count).max() ?? 0
                let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
                for (r, row) in rows.enumerated() {
                    if r > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
                    let cells = (0..<columns).map { column -> String in
                        let cell = column < row.count ? row[column] : ""
                        return cell.padding(toLength: min(widths[column], 40), withPad: " ", startingAt: 0)
                    }
                    out.append(inline(cells.joined(separator: " │ "), base: r == 0 ? boldFont : font))
                }
            case .rule:
                out.append(NSAttributedString(string: String(repeating: "─", count: 40), attributes: [.font: font, .foregroundColor: NSColor(Term.dim)]))
            }
        }
        linkify(out)
        return out
    }

    /// Inline markdown (bold, italic, `code`, links) in the terminal font.
    private static func inline(_ text: String, base: NSFont = font, color: NSColor = NSColor(Term.text)) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color, .paragraphStyle: paragraph()]
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits))
                attributes[.font] = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
            }
            if intent.contains(.code) {
                attributes[.foregroundColor] = NSColor(Term.claude)
            }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    private static func paragraph(first: CGFloat = 0, head: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = first
        style.headIndent = head
        style.lineSpacing = 2
        return style
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bare addresses (https://…, www.…) become links, where there isn't one already.
    static func linkify(_ text: NSMutableAttributedString) {
        let string = text.string
        detector?.enumerateMatches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) { match, _, _ in
            guard let match, let url = match.url, url.scheme?.hasPrefix("http") == true else { return }
            var existing: Any?
            existing = text.attribute(.link, at: match.range.location, effectiveRange: nil)
            if existing == nil { text.addAttribute(.link, value: url, range: match.range) }
        }
    }
}
