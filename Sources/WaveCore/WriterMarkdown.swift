import Foundation

/// A deliberately small, escaped Markdown renderer. Raw HTML cannot execute code in previews.
public enum WriterMarkdown {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func inline(_ text: String) -> String {
        var html = escape(text)
        var protected: [String] = []
        func replace(_ pattern: String, transform: (NSTextCheckingResult, NSString) -> String) {
            let source = html as NSString
            for match in WritingTools.matches(pattern, in: html).reversed() {
                html = (html as NSString).replacingCharacters(in: match.range, with: transform(match, source))
            }
        }
        func safeURL(_ value: String, image: Bool = false) -> String? {
            let decoded = value.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: decoded) else { return nil }
            if let scheme = url.scheme, !["http", "https", "mailto"].contains(scheme.lowercased()) { return nil }
            if image && url.scheme == "mailto" { return nil }
            if url.scheme == nil && (decoded.hasPrefix("/") || decoded.contains("..")) { return nil }
            return escape(decoded)
        }
        func protect(_ value: String) -> String {
            let token = "\u{E000}\(protected.count)\u{E001}"
            protected.append(value); return token
        }
        replace(#"`([^`\n]+)`"#) { match, source in protect("<code>\(source.substring(with: match.range(at: 1)))</code>") }
        replace(#"!\[([^\]]*)\]\(([^\s)]+)\)"#) { match, source in
            guard let url = safeURL(source.substring(with: match.range(at: 2)), image: true) else { return source.substring(with: match.range) }
            return protect("<img src=\"\(url)\" alt=\"\(source.substring(with: match.range(at: 1)))\" />")
        }
        replace(#"\[([^\]]+)\]\(([^\s)]+)\)"#) { match, source in
            guard let url = safeURL(source.substring(with: match.range(at: 2))) else { return source.substring(with: match.range) }
            return protect("<a href=\"\(url)\">\(source.substring(with: match.range(at: 1)))</a>")
        }
        replace(#"\[\[([^\]]+)\]\]"#) { match, source in
            let title = source.substring(with: match.range(at: 1))
            let decoded = title.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
            let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? decoded
            return protect("<a href=\"wave-note:///\(encoded)\">\(title)</a>")
        }
        replace(#"\*\*\*([^*\n]+)\*\*\*|(?<![\p{L}\p{N}_])___([^_\n]+)___(?![\p{L}\p{N}_])"#) { match, source in
            let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            return "<strong><em>\(source.substring(with: range))</em></strong>"
        }
        replace(#"\*\*([^*]+)\*\*|(?<![\p{L}\p{N}_])__([^_]+)__(?![\p{L}\p{N}_])"#) { match, source in
            let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            return "<strong>\(source.substring(with: range))</strong>"
        }
        replace(#"\*([^*\n]+)\*|(?<![\p{L}\p{N}_])_([^_\n]+)_(?![\p{L}\p{N}_])"#) { match, source in
            let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            return "<em>\(source.substring(with: range))</em>"
        }
        replace(#"~~([^~]+)~~"#) { match, source in "<del>\(source.substring(with: match.range(at: 1)))</del>" }
        for (index, value) in protected.enumerated() { html = html.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: value) }
        return html
    }
    public static func body(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = [], paragraph: [String] = [], quote: [String] = [], code: [String] = []
        var fenced = false, listStack: [(indent: Int, kind: String)] = [], index = 0
        func flushParagraph() {
            if !paragraph.isEmpty {
                output.append("<p>" + inline(paragraph.joined(separator: "\n")).replacingOccurrences(of: "\n", with: "<br>") + "</p>")
                paragraph = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                output.append("<blockquote>" + inline(quote.joined(separator: "\n")).replacingOccurrences(of: "\n", with: "<br>") + "</blockquote>")
                quote = []
            }
        }
        func closeLists(downTo indent: Int = -1) {
            while let last = listStack.last, last.indent > indent {
                output.append("</\(last.kind)>")
                listStack.removeLast()
            }
        }
        func flush() { flushParagraph(); flushQuote() }
        func cells(_ line: String) -> [String] {
            var values = line.components(separatedBy: "|")
            if values.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { values.removeFirst() }
            if values.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { values.removeLast() }
            return values.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func leadingSpaces(_ line: String) -> Int {
            var count = 0
            for ch in line {
                if ch == " " { count += 1 }
                else if ch == "\t" { count += 4 }
                else { break }
            }
            return count
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush(); closeLists()
                if fenced { output.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>"); code = [] }
                fenced.toggle()
            } else if fenced { code.append(line) }
            else if trimmed.isEmpty { flush(); closeLists() }
            else if index + 1 < lines.count, line.contains("|"),
                    !cells(lines[index + 1]).isEmpty,
                    cells(lines[index + 1]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                flush(); closeLists()
                output.append("<table><thead><tr>" + cells(line).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>")
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].isEmpty {
                    output.append("<tr>" + cells(lines[index]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"); index += 1
                }
                output.append("</tbody></table>"); continue
            } else if let heading = WritingTools.matches(#"^(#{1,6}) (.*)$"#, in: trimmed).first {
                flush(); closeLists()
                let level = heading.range(at: 1).length
                output.append("<h\(level)>\(inline((trimmed as NSString).substring(with: heading.range(at: 2))))</h\(level)>")
            } else if ["---", "***", "___"].contains(trimmed) { flush(); closeLists(); output.append("<hr>") }
            else if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph(); closeLists()
                quote.append(trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : "")
            } else if let item = WritingTools.matches(#"^([-*+] |\d+\. )(.*)$"#, in: trimmed).first {
                flush()
                let indent = leadingSpaces(line)
                let kind = trimmed.first?.isNumber == true ? "ol" : "ul"
                closeLists(downTo: indent)
                if let last = listStack.last, last.indent == indent, last.kind != kind {
                    output.append("</\(last.kind)>")
                    listStack.removeLast()
                }
                if listStack.last?.indent != indent {
                    output.append("<\(kind)>")
                    listStack.append((indent, kind))
                }
                let value = (trimmed as NSString).substring(with: item.range(at: 2))
                if value.hasPrefix("[ ] ") || value.lowercased().hasPrefix("[x] ") {
                    let checked = value.lowercased().hasPrefix("[x]")
                    output.append("<li class=\"task\"><span class=\"checkbox\">\(checked ? "☑" : "☐")</span> \(inline(String(value.dropFirst(4))))</li>")
                } else { output.append("<li>\(inline(value))</li>") }
            } else { flushQuote(); closeLists(); paragraph.append(line) }
            index += 1
        }
        flush(); closeLists()
        if fenced { output.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>") }
        return output.joined(separator: "\n")
    }
    public static func html(_ markdown: String, title: String = "Document", fontFamily: String = "Quattro", colorScheme: String = "light dark") -> String {
        let bodyFont: String
        switch fontFamily {
        case "Mono": bodyFont = "'iA Writer Mono S', Menlo, ui-monospace, monospace"
        case "Duo": bodyFont = "'iA Writer Duo S', Menlo, ui-monospace, monospace"
        default: bodyFont = "'iA Writer Quattro S', -apple-system, BlinkMacSystemFont, Georgia, serif"
        }
        let lightVars = "--bg:#fff;--fg:#1d1d1f;--muted:#5e5e63;--border:#e0e0e4;--code-bg:#f5f5f7;--accent:#007cc3"
        let darkVars = "--bg:#161618;--fg:#ececef;--muted:#9e9ea6;--border:#2f2f35;--code-bg:#222226;--accent:#3aa9f5"
        let themeCSS: String
        switch colorScheme {
        case "dark":
            themeCSS = ":root{color-scheme:dark;\(darkVars)}"
        case "light":
            themeCSS = ":root{color-scheme:light;\(lightVars)}"
        default:
            themeCSS = ":root{color-scheme:light dark;\(lightVars)}@media(prefers-color-scheme:dark){:root{\(darkVars)}}"
        }
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title><style>
        \(themeCSS)*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.72 \(bodyFont);-webkit-text-size-adjust:100%}
        article{max-width:720px;margin:0 auto;padding:64px 36px 80px}h1,h2,h3,h4,h5,h6{font-family:-apple-system,BlinkMacSystemFont,sans-serif;line-height:1.3;margin:1.5em 0 .6em;letter-spacing:-0.01em}h1{font-size:2em;margin-top:0}h2{font-size:1.45em}p{margin:0 0 1.25em}
        a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}blockquote{border-left:2px solid var(--border);margin:1em 0;padding-left:1.2em;color:var(--muted)}pre,code{font:.86em/1.6 Menlo,ui-monospace,monospace}code{background:var(--code-bg);padding:2px 5px;border-radius:4px}pre{background:var(--code-bg);padding:18px 20px;border-radius:10px;white-space:pre-wrap;overflow-wrap:anywhere}pre code{background:none;padding:0}img{max-width:100%;height:auto;border-radius:8px}table{border-collapse:collapse;width:100%;margin:1.5em 0;font-size:.92em}td,th{border-bottom:1px solid var(--border);padding:8px;text-align:left}th{font-weight:600}hr{border:0;border-top:1px solid var(--border);margin:2em 0}.task{list-style:none}.checkbox{color:var(--muted)}ul,ol{padding-left:1.4em}@media(max-width:500px){article{padding:30px 22px}body{font-size:16px}}@media print{:root{color-scheme:light;\(lightVars)}article{padding:0}a{color:inherit}}
        </style></head><body><article>\(body(markdown))</article></body></html>
        """
    }
}

/// Portable Word export: a standards-based OOXML package with uncompressed ZIP entries.
public enum WriterWord {
    public static func document(_ markdown: String) -> Data {
        let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        func runs(_ text: String, code: Bool = false) -> String {
            let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            guard let attributed else { return "<w:r><w:t xml:space=\"preserve\">\(WriterMarkdown.escape(text))</w:t></w:r>" }
            return attributed.runs.map { run in
                var properties = ""
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { properties += "<w:b/>" }
                if run.inlinePresentationIntent?.contains(.emphasized) == true { properties += "<w:i/>" }
                if code || run.inlinePresentationIntent?.contains(.code) == true { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
                let value = String(attributed[run.range].characters)
                return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(WriterMarkdown.escape(value))</w:t></w:r>"
            }.joined()
        }
        var code = false
        let paragraphs = markdown.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("```") { code.toggle(); return "" }
            var content = line, style = "Normal"
            if !code, let heading = WritingTools.matches(#"^(#{1,6}) (.*)$"#, in: line).first {
                style = "Heading\(heading.range(at: 1).length)"
                content = (line as NSString).substring(with: heading.range(at: 2))
            } else if !code, line.hasPrefix("> ") { content = String(line.dropFirst(2)); style = "Quote" }
            else if !code, line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { content = "☑ " + String(line.dropFirst(6)) }
            else if !code, line.hasPrefix("- [ ] ") { content = "☐ " + String(line.dropFirst(6)) }
            else if !code, line.hasPrefix("- ") || line.hasPrefix("* ") { content = "• " + String(line.dropFirst(2)) }
            return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runs(content, code: code))</w:p>"
        }.joined()
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"\(namespace)\"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>"
        var styles = "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"120\" w:line=\"300\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/><w:sz w:val=\"24\"/></w:rPr></w:style>"
        for level in 1...6 {
            styles += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(max(24, 42 - level * 4))\"/></w:rPr></w:style>"
        }
        styles += "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:ind w:left=\"360\"/></w:pPr><w:rPr><w:i/><w:color w:val=\"777777\"/></w:rPr></w:style>"
        let entries = [
            ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>"),
            ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
            ("word/document.xml", document),
            ("word/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles xmlns:w=\"\(namespace)\">\(styles)</w:styles>"),
            ("word/_rels/document.xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
        ]
        return archive(entries)
    }
    private static func archive(_ entries: [(String, String)]) -> Data {
        var data = Data(), central = Data()
        func u16(_ value: UInt16, to data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32, to data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func crc(_ bytes: Data) -> UInt32 {
            var value: UInt32 = 0xFFFFFFFF
            for byte in bytes { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 } }
            return value ^ 0xFFFFFFFF
        }
        for (name, text) in entries {
            let filename = Data(name.utf8), content = Data(text.utf8), checksum = crc(content), offset = UInt32(data.count)
            u32(0x04034B50, to: &data); u16(20, to: &data); u16(0, to: &data); u16(0, to: &data)
            u16(0, to: &data); u16(0x21, to: &data); u32(checksum, to: &data)
            u32(UInt32(content.count), to: &data); u32(UInt32(content.count), to: &data)
            u16(UInt16(filename.count), to: &data); u16(0, to: &data); data.append(filename); data.append(content)
            u32(0x02014B50, to: &central); u16(20, to: &central); u16(20, to: &central)
            u16(0, to: &central); u16(0, to: &central); u16(0, to: &central); u16(0x21, to: &central)
            u32(checksum, to: &central); u32(UInt32(content.count), to: &central); u32(UInt32(content.count), to: &central)
            u16(UInt16(filename.count), to: &central); u16(0, to: &central); u16(0, to: &central)
            u16(0, to: &central); u16(0, to: &central); u32(0, to: &central); u32(offset, to: &central); central.append(filename)
        }
        let offset = UInt32(data.count); data.append(central)
        u32(0x06054B50, to: &data); u16(0, to: &data); u16(0, to: &data)
        u16(UInt16(entries.count), to: &data); u16(UInt16(entries.count), to: &data)
        u32(UInt32(central.count), to: &data); u32(offset, to: &data); u16(0, to: &data)
        return data
    }
}
