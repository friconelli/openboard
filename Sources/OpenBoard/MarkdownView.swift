import SwiftUI
import AppKit

/// Renders an answer as blocks: headings, paragraphs, lists, quotes, tables and fenced code
/// with a copy button. Inline styles (bold, italic, `code`, links) use AttributedString.
struct MarkdownView: View {
    let text: String

    enum Block: Identifiable {
        case heading(Int, String)
        case paragraph(String)
        case bullet([(marker: String, text: String)])
        case quote(String)
        case code(language: String, code: String)
        case table([[String]])
        case rule

        var id: String {
            switch self {
            case .heading(let level, let text): return "h\(level)\(text.hashValue)"
            case .paragraph(let text): return "p\(text.hashValue)"
            case .bullet(let items): return "b\(items.map(\.text).joined().hashValue)"
            case .quote(let text): return "q\(text.hashValue)"
            case .code(let language, let code): return "c\(language)\(code.hashValue)"
            case .table(let rows): return "t\(rows.flatMap { $0 }.joined().hashValue)"
            case .rule: return "r\(UUID().uuidString)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 2)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary)
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let rows):
            TableBlock(rows: rows)
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [(String, String)] = []
        var quote: [String] = []
        var table: [[String]] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty { flush(); index += 1; continue }
            if let match = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush()
                blocks.append(.heading(trimmed[match].filter { $0 == "#" }.count, String(trimmed[match.upperBound...])))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                if !paragraph.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush() }
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the separator row (|---|:---:|).
                if !cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { table.append(cells) }
            } else if let match = trimmed.range(of: #"^([-*•]|\d+[.)]) "#, options: .regularExpression) {
                if !paragraph.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                let marker = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
                let indent = String(repeating: "  ", count: (line.prefix { $0 == " " }.count) / 2)
                bullets.append((indent + (marker.first?.isNumber == true ? marker : "•"), String(trimmed[match.upperBound...])))
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !bullets.isEmpty || !table.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                if !bullets.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "codice" : language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copiato" : "Copia", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(MarkdownView.inline(column < row.count ? row[column] : ""))
                                .fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
