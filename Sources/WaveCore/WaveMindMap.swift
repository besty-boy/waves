import Foundation

public struct WaveMindMapNode: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String
    public var colorToken: String
    public var x: Double
    public var y: Double
    public var noteID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        colorToken: String = "blue",
        x: Double,
        y: Double,
        noteID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.colorToken = colorToken
        self.x = x
        self.y = y
        self.noteID = noteID
    }
}

public struct WaveMindMapEdge: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var from: UUID
    public var to: UUID

    public init(id: UUID = UUID(), from: UUID, to: UUID) {
        self.id = id
        self.from = from
        self.to = to
    }
}

public struct WaveMindMap: Codable, Hashable, Sendable {
    public var nodes: [WaveMindMapNode]
    public var edges: [WaveMindMapEdge]

    public init(nodes: [WaveMindMapNode], edges: [WaveMindMapEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public static func starter() -> WaveMindMap {
        let root = WaveMindMapNode(
            title: "Article · Productivité",
            subtitle: "Projet principal",
            colorToken: "blue",
            x: 0.50,
            y: 0.50
        )
        let ideas = [
            WaveMindMapNode(title: "Idée centrale", subtitle: "Pourquoi mieux organiser ses idées ?", colorToken: "violet", x: 0.20, y: 0.50),
            WaveMindMapNode(title: "Recherche", subtitle: "Sources et références", colorToken: "mint", x: 0.80, y: 0.22),
            WaveMindMapNode(title: "Plan", subtitle: "Structure de l’article", colorToken: "amber", x: 0.82, y: 0.50),
            WaveMindMapNode(title: "Exemples", subtitle: "Cas concrets à raconter", colorToken: "mint", x: 0.80, y: 0.78)
        ]
        return WaveMindMap(
            nodes: [root] + ideas,
            edges: ideas.map { WaveMindMapEdge(from: root.id, to: $0.id) }
        )
    }
}
