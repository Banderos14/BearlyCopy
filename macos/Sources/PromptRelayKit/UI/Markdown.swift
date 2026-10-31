import SwiftUI

/// A small Markdown reader for reports: headings, paragraphs, lists,
/// quotes, tables, rules and fenced code, with inline styling from
/// Foundation's Markdown parser. It is for **display only**: every copy uses
/// the original text, never what is rendered here.
public enum Markdown {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(indent: Int, marker: String, text: String)
        case quote(String)
        case code(language: String, text: String)
        case table([String])
        case rule
    }

    /// Parses line by line; anything unusual stays a paragraph, so no text
    /// is ever dropped from the reader.
    public static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fenceMarker(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                // A fence indented inside a list item: its lines carry the same
                // indent, which is layout, not code (as in CommonMark).
                let indent = line.prefix { $0 == " " }.count
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence), t.allSatisfy({ $0 == fence.first }) { break }
                    let lead = min(indent, lines[i].prefix { $0 == " " }.count)
                    body.append(String(lines[i].dropFirst(lead))); i += 1
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush(); blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.table(rows))
                continue
            } else if trimmed.hasPrefix(">") {
                flush(); blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let item = listItem(line) {
                flush(); blocks.append(item)
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        return blocks
    }

    static func fenceMarker(_ trimmed: String) -> String? {
        for ch in ["`", "~"] {
            let run = trimmed.prefix { String($0) == ch }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func listItem(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .listItem(indent: indent / 2, marker: "•", text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 4 {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, ".)".contains(dot), after.dropFirst().first == " " {
                return .listItem(indent: indent / 2, marker: "\(digits).", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// Inline Markdown (bold, italic, code, links); plain text if it does not parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Parsed blocks for recently shown texts, so scrolling and redraws do
    /// not parse a long report again.
    @MainActor static func blocks(_ text: String) -> [Block] {
        if let hit = cache.first(where: { $0.0 == text }) { return hit.1 }
        let parsed = parse(text)
        cache.insert((text, parsed), at: 0)
        if cache.count > 6 { cache.removeLast() }
        return parsed
    }
    @MainActor private static var cache: [(String, [Block])] = []
}

/// Renders parsed blocks on the island's dark surfaces.
struct MarkdownBlocksView: View {
    let blocks: [Markdown.Block]
    /// Lines shown of each code block (nil: all; the reader shows all).
    var codeLineLimit: Int?
    var fontSize: CGFloat = 13

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
    }

    @ViewBuilder
    private func view(_ block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(.system(size: level == 1 ? fontSize + 4 : level == 2 ? fontSize + 2 : fontSize + 0.5, weight: .semibold))
                .foregroundStyle(Island.primary)
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .font(.system(size: fontSize)).lineSpacing(2.5)
                .foregroundStyle(Island.primary)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(Island.secondary).monospacedDigit()
                Text(Markdown.inline(text)).foregroundStyle(Island.primary).lineSpacing(2)
            }
            .font(.system(size: fontSize))
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Island.secondary).frame(width: 2)
                Text(Markdown.inline(text)).font(.system(size: fontSize)).foregroundStyle(Island.secondary)
            }
        case .code(let language, let text):
            CodeBlockView(language: language, text: text, lineLimit: codeLineLimit, fontSize: fontSize - 1.5)
        case .table(let rows):
            CodeBlockView(language: "", text: rows.joined(separator: "\n"), lineLimit: codeLineLimit, fontSize: fontSize - 1.5)
        case .rule:
            Rectangle().fill(Island.hairline).frame(height: 1).padding(.vertical, 2)
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let text: String
    let lineLimit: Int?
    let fontSize: CGFloat

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let shown = lineLimit.map { Array(lines.prefix($0)) } ?? lines
        VStack(alignment: .leading, spacing: 4) {
            if !language.isEmpty {
                Text(language).font(.system(size: 10, weight: .semibold)).foregroundStyle(Island.tertiary)
            }
            // In the reader (no line limit) a long line shows its scroller, so it is clear there is more to the right.
            ScrollView(.horizontal, showsIndicators: lineLimit == nil) {
                Text(shown.joined(separator: "\n"))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Island.primary.opacity(0.9))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
            }
            if shown.count < lines.count {
                Text("+\(lines.count - shown.count) more lines").font(.system(size: 10)).foregroundStyle(Island.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Island.code))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.isEmpty ? "Code" : "\(language) code")
    }
}
