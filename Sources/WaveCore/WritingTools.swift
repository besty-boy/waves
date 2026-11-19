import Foundation
import NaturalLanguage

/// Editor ranges always use UTF-16, matching AppKit and UIKit selections.
public enum WriterFocus: String, CaseIterable, Codable, Sendable {
    case off, sentence, paragraph, typewriter
    public var label: String {
        switch self {
        case .off: return "Désactivé"
        case .sentence: return "Phrase"
        case .paragraph: return "Paragraphe"
        case .typewriter: return "Machine à écrire"
        }
    }
}

public struct DocumentHeading: Identifiable, Equatable, Sendable {
    public let id: String
    public let level: Int
    public let title: String
    public let utf16Location: Int

    public init(level: Int, title: String, utf16Location: Int) {
        self.id = "\(utf16Location)-\(level)-\(title)"
        self.level = level
        self.title = title
        self.utf16Location = utf16Location
    }
}

public struct DocumentTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let lineIndex: Int
    public let text: String
    public let completed: Bool

    public init(lineIndex: Int, text: String, completed: Bool) {
        self.id = "\(lineIndex)-\(completed ? "x" : "o")-\(text)"
        self.lineIndex = lineIndex
        self.text = text
        self.completed = completed
    }
}

public struct WaveTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let icon: String
    public let defaultTitle: String
    public let folder: String
    public let content: String

    public init(id: String, name: String, icon: String, defaultTitle: String, folder: String = "Inbox", content: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.defaultTitle = defaultTitle
        self.folder = folder
        self.content = content
    }

    public static func dailyTitle(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func daily(for date: Date = .now) -> WaveTemplate {
        let title = dailyTitle(for: date)
        let readable = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
        return WaveTemplate(
            id: "daily",
            name: "Note du jour",
            icon: "calendar",
            defaultTitle: title,
            folder: "Journal",
            content: """
            *\(readable.capitalized)*

            ## Priorités
            - [ ] 

            ## Notes

            ## Bilan
            """
        )
    }

    public static let meeting = WaveTemplate(
        id: "meeting",
        name: "Compte-rendu de réunion",
        icon: "person.2",
        defaultTitle: "Réunion — \(dailyTitle())",
        folder: "Inbox",
        content: """
        **Participants :** 
        **Contexte :** 

        ## Points abordés
        - 

        ## Décisions
        - 

        ## Actions
        - [ ] 
        """
    )

    public static let reflection = WaveTemplate(
        id: "reflection",
        name: "Réflexion / Article",
        icon: "doc.text",
        defaultTitle: "Nouvelle réflexion",
        folder: "Inbox",
        content: """
        ## Idée clé

        ## Développement

        ## Questions ouvertes
        - 

        ## Références
        """
    )

    public static let checklist = WaveTemplate(
        id: "checklist",
        name: "Liste de tâches",
        icon: "checklist",
        defaultTitle: "Plan d’action",
        folder: "Inbox",
        content: """
        ## Maintenant
        - [ ] 

        ## Ensuite
        - [ ] 

        ## Plus tard
        - [ ] 
        """
    )

    public static var builtIn: [WaveTemplate] {
        [daily(), meeting, reflection, checklist]
    }
}

public struct WritingStatistics: Equatable, Sendable {
    public let words: Int
    public let characters: Int
    public let sentences: Int
    public let tasks: Int
    public let completedTasks: Int
    public var readingMinutes: Int { words == 0 ? 0 : max(1, Int(ceil(Double(words) / 200))) }

    public init(_ text: String) {
        characters = text.count
        let tokens = NLTokenizer(unit: .word)
        tokens.string = text
        var count = 0
        tokens.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in count += 1; return true }
        words = count
        let sentenceTokens = NLTokenizer(unit: .sentence)
        sentenceTokens.string = text
        count = 0
        sentenceTokens.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
            return true
        }
        sentences = count
        let matches = WritingTools.matches(#"(?m)^\s*[-*+] \[([ xX])\] "#, in: text)
        tasks = matches.count
        completedTasks = matches.filter { (text as NSString).substring(with: $0.range(at: 1)).lowercased() == "x" }.count
    }
}

public enum WritingTools {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }

    public static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = regex(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    public static func tags(in text: String) -> [String] {
        // A Markdown heading and a URL fragment are not library tags.
        let withoutCode = text.replacingOccurrences(of: #"(?s)```.*?```|`[^`\n]*`"#, with: "", options: .regularExpression)
        let result = matches(#"(?<![\p{L}\p{N}/:#])#([\p{L}\p{N}_-]+)"#, in: withoutCode)
            .map { (withoutCode as NSString).substring(with: $0.range(at: 1)).lowercased() }
        return Array(Set(result)).sorted()
    }

    /// Extracts Markdown headings outside fenced code blocks with their UTF-16 offset for instant navigation.
    public static func headings(in text: String) -> [DocumentHeading] {
        let lines = text.components(separatedBy: "\n")
        var result: [DocumentHeading] = []
        var offset = 0
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
            } else if !inFence, let match = matches(#"^(#{1,6})\s+(.+?)\s*$"#, in: trimmed).first {
                let ns = trimmed as NSString
                let level = match.range(at: 1).length
                let title = ns.substring(with: match.range(at: 2))
                result.append(DocumentHeading(level: level, title: title, utf16Location: offset))
            }
            offset += (line as NSString).length + 1
        }
        return result
    }

    /// Extracts Markdown checklist items outside fenced code blocks.
    public static func tasks(in text: String) -> [DocumentTask] {
        let lines = text.components(separatedBy: "\n")
        var result: [DocumentTask] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence, let match = matches(#"^\s*[-*+]\s+\[([ xX])\]\s*(.*)$"#, in: line).first {
                let ns = line as NSString
                let marker = ns.substring(with: match.range(at: 1)).lowercased()
                let title = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                result.append(DocumentTask(lineIndex: index, text: title, completed: marker == "x"))
            }
        }
        return result
    }

    /// Toggles the checkbox on a specific 0-based line of a note body.
    public static func togglingTask(atLine lineIndex: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return text }
        let line = lines[lineIndex]
        if let match = matches(#"^(\s*[-*+]\s+\[)([ xX])(\]\s*.*)$"#, in: line).first {
            let ns = line as NSString
            let prefix = ns.substring(with: match.range(at: 1))
            let state = ns.substring(with: match.range(at: 2)).lowercased()
            let suffix = ns.substring(with: match.range(at: 3))
            lines[lineIndex] = prefix + (state == "x" ? " " : "x") + suffix
            return lines.joined(separator: "\n")
        }
        return text
    }

    /// Extracts unique internal `[[Note Title]]` links outside code blocks/inline code, preserving order.
    public static func wikiLinks(in text: String) -> [String] {
        let withoutCode = text.replacingOccurrences(of: #"(?s)```.*?```|`[^`\n]*`"#, with: "", options: .regularExpression)
        let ns = withoutCode as NSString
        var seen: Set<String> = []
        var ordered: [String] = []
        for match in matches(#"\[\[([^\]\n]+)\]\]"#, in: withoutCode) {
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            let key = target.lowercased()
            if seen.insert(key).inserted {
                ordered.append(target)
            }
        }
        return ordered
    }

    public static func focusRange(in text: String, caret: Int, mode: WriterFocus) -> NSRange {
        let string = text as NSString
        let length = string.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, caret), length)
        guard mode == .sentence || mode == .paragraph else { return NSRange(location: 0, length: length) }
        // Work on a window around the caret so long documents stay fast while typing.
        let windowRadius = 4000
        let windowStart = max(0, location - windowRadius)
        let windowEnd = min(length, location + windowRadius)
        let windowRange = string.rangeOfComposedCharacterSequences(for: NSRange(location: windowStart, length: windowEnd - windowStart))
        let window = string.substring(with: windowRange)
        let localCaret = location - windowRange.location
        if mode == .sentence {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = window
            var result: NSRange?
            let windowLength = (window as NSString).length
            tokenizer.enumerateTokens(in: window.startIndex..<window.endIndex) { range, _ in
                let ns = NSRange(range, in: window)
                if localCaret >= ns.location && (localCaret < NSMaxRange(ns) || localCaret == windowLength && NSMaxRange(ns) == windowLength) {
                    result = ns; return false
                }
                return true
            }
            if let result { return NSRange(location: windowRange.location + result.location, length: result.length) }
        }
        // Blank lines, rather than soft wraps, delimit a writing paragraph.
        let boundaries = matches(#"\n[\t ]*\n"#, in: window).map(\.range)
        let start = boundaries.last(where: { NSMaxRange($0) <= localCaret }).map(NSMaxRange) ?? 0
        let end = boundaries.first(where: { $0.location >= localCaret })?.location ?? (window as NSString).length
        return NSRange(location: windowRange.location + start, length: max(0, end - start))
    }

    /// Filename remains usable when the writer removes the document's first H1.
    public static func document(_ markdown: String, fallbackTitle: String) -> (title: String, body: String) {
        let first = markdown.prefix(while: { $0 != "\n" })
        guard first.hasPrefix("# ") else {
            return (fallbackTitle, markdown)
        }
        let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = markdown.firstIndex(of: "\n") else { return (title.isEmpty ? "Sans titre" : title, "") }
        var body = markdown[markdown.index(after: newline)...]
        if body.first == "\n" { body = body.dropFirst() }
        return (title.isEmpty ? "Sans titre" : title, String(body))
    }

    public struct SearchQuery {
        private struct Term {
            let text: String
            let excluded: Bool
        }
        private let terms: [Term]

        public init(_ query: String) {
            terms = WritingTools.matches(#"-?"[^"]+"|\S+"#, in: query).map { match in
                var text = (query as NSString).substring(with: match.range)
                let excluded = text.hasPrefix("-")
                if excluded { text.removeFirst() }
                return Term(text: text.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), excluded: excluded)
            }
        }

        public func matches(_ note: WaveNote, cachedTags: [String]? = nil) -> Bool {
            terms.allSatisfy { term in
                let text = term.text
                let lower = text.lowercased()
                let found: Bool
                if text.hasPrefix("#") {
                    found = (cachedTags ?? WritingTools.tags(in: note.content)).contains(String(text.dropFirst()).lowercased())
                } else if lower.hasPrefix("title:") {
                    found = note.title.localizedCaseInsensitiveContains(String(text.dropFirst(6)))
                } else if lower.hasPrefix("folder:") {
                    let needle = String(text.dropFirst(7))
                    let displayFolder = note.folder == "Inbox" ? "Documents" : note.folder
                    found = note.folder.localizedCaseInsensitiveContains(needle)
                        || displayFolder.localizedCaseInsensitiveContains(needle)
                } else if lower == "has:attachment" || lower == "has:attachments" || lower == "has:file" {
                    found = !note.attachments.isEmpty
                } else if lower == "has:task" || lower == "has:tasks" {
                    found = !WritingTools.tasks(in: note.content).isEmpty
                } else {
                    let displayFolder = note.folder == "Inbox" ? "Documents" : note.folder
                    found = (note.title + "\n" + note.content + "\n" + note.folder + "\n" + displayFolder)
                        .localizedCaseInsensitiveContains(text)
                }
                return term.excluded ? !found : found
            }
        }
    }

    public static func search(_ query: String, in note: WaveNote) -> Bool {
        SearchQuery(query).matches(note)
    }

    public static func styleIssues(in text: String) -> [NSRange] {
        // Local revision suggestions, deliberately conservative and editable by the writer.
        let fillers = #"(?i)\b(en fait|en réalité|très|vraiment|absolument|totalement|basically|actually|very|really|quite|just)\b"#
        let repetitions = #"(?i)\b([\p{L}]+)(\s+\1)\b"#
        return matches(fillers, in: text).map(\.range) + matches(repetitions, in: text).map(\.range)
    }
}
