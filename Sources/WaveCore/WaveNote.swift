import Foundation

public struct WaveNote: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var folder: String
    /// Markdown without the first-level title, which is stored as the file's H1.
    public var content: String
    public var modifiedAt: Date
    public var attachments: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        folder: String = "Inbox",
        content: String = "",
        modifiedAt: Date = .now,
        attachments: [String] = []
    ) {
        self.id = id
        self.title = title
        self.folder = folder
        self.content = content
        self.modifiedAt = modifiedAt
        self.attachments = attachments
    }

    public var markdown: String {
        let heading = "# \(title.trimmingCharacters(in: .whitespacesAndNewlines))"
        let body = content.trimmingCharacters(in: .newlines)
        return body.isEmpty ? "\(heading)\n" : "\(heading)\n\n\(body)\n"
    }

    /// Plain-text excerpt used in search palettes and backlink previews.
    public var snippet: String {
        let cleaned = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- `")) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
        return String(cleaned.prefix(140))
    }
}
