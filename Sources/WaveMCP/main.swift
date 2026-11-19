import Foundation
import WaveCore
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif

private let protocolVersion = "2025-11-25"
private let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
private let vault = VaultStore()
private let writeEnabled = ProcessInfo.processInfo.environment["WAVE_MCP_WRITE"] == "1"
private let writeTools: Set<String> = ["create_note", "update_note"]

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "JSON invalide."]])
        continue
    }
    guard let message = object as? [String: Any], message["jsonrpc"] as? String == "2.0",
          let method = message["method"] as? String else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Requête JSON-RPC invalide."]])
        continue
    }

    // JSON-RPC notifications intentionally have no response.
    guard let id = message["id"] else {
        continue
    }

    let result: [String: Any]
    do {
        if ["tools/call", "resources/list", "resources/read"].contains(method) {
            let toolName = (message["params"] as? [String: Any])?["name"] as? String ?? ""
            let writing = method == "tools/call" && writeTools.contains(toolName)
            result = try vault.coordinated(writing: writing) { coordinatedVault in
                try handle(method: method, message: message, vault: coordinatedVault)
            }
        } else {
            result = try handle(method: method, message: message, vault: vault)
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    } catch {
        if method == "tools/call" {
            send(["jsonrpc": "2.0", "id": id, "result": [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true
            ]])
        } else {
            let knownMethods: Set<String> = [
                "initialize", "ping", "tools/list", "tools/call", "resources/list", "resources/read"
            ]
            let code = knownMethods.contains(method) ? -32603 : -32601
            send(["jsonrpc": "2.0", "id": id, "error": [
                "code": code,
                "message": error.localizedDescription
            ]])
        }
    }
}

private func handle(method: String, message: [String: Any], vault: VaultStore) throws -> [String: Any] {
    switch method {
    case "initialize":
        let params = message["params"] as? [String: Any] ?? [:]
        let requested = params["protocolVersion"] as? String ?? protocolVersion
        return [
            "protocolVersion": supportedVersions.contains(requested) ? requested : protocolVersion,
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["subscribe": false, "listChanged": false]
            ],
            "serverInfo": ["name": "wave-notes", "version": "0.4.0"],
            "instructions": writeEnabled
                ? "Wave peut lire et modifier les notes Markdown locales, ainsi que consulter les tâches, tags, rétroliens et la carte d'idées. Utilisez read_note avant update_note et transmettez la révision retournée pour éviter d'écraser des changements récents."
                : "Wave donne accès en lecture seule aux notes Markdown locales, aux tâches, aux tags, aux rétroliens et à la carte d'idées. Utilisez search_notes, list_tasks, list_tags, read_backlinks, read_note ou read_mind_map."
        ]
    case "ping":
        return [:]
    case "tools/list":
        var tools: [[String: Any]] = [
            [
                "name": "list_notes",
                "description": "Liste les notes Markdown de Wave, éventuellement filtrées par dossier.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["folder": ["type": "string", "description": "Nom du dossier à filtrer"]],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "search_notes",
                "description": "Recherche dans les titres, dossiers, hashtags et contenus des notes Wave (supporte #tag, title:, folder:, has:attachment, has:task, \"phrase\", -exclusion).",
                "inputSchema": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "Requête de recherche"]],
                    "required": ["query"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "read_note",
                "description": "Lit le contenu Markdown complet d'une note Wave et retourne sa révision pour update_note.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Identifiant UUID retourné par list_notes ou search_notes"]],
                    "required": ["id"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "read_mind_map",
                "description": "Lit les nœuds et les liens de la carte d'idées Wave.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "read_attachment",
                "description": "Extrait le texte d'une pièce jointe PDF, DOCX ou texte liée à une note Wave.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "Identifiant UUID de la note"],
                        "filename": ["type": "string", "description": "Nom exact de la pièce jointe retourné par list_notes"]
                    ],
                    "required": ["note_id", "filename"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "list_tasks",
                "description": "Liste les tâches Markdown (- [ ] / - [x]) dans l'ensemble des notes Wave.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "completed": ["type": "boolean", "description": "Filtrer par statut (false = à faire par défaut, true = terminées)"]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "list_tags",
                "description": "Liste tous les hashtags utilisés dans les notes Wave avec leur nombre d'occurrences.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "read_backlinks",
                "description": "Retourne les notes qui référencent une note donnée via un lien interne [[Titre]].",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Identifiant UUID de la note cible"]],
                    "required": ["id"],
                    "additionalProperties": false
                ]
            ]
        ]
        if writeEnabled {
            tools += [
                [
                    "name": "create_note",
                    "description": "Crée une note Wave. content est le corps Markdown, sans titre H1. Retourne l'UUID et la révision.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string", "description": "Titre de la note"],
                            "content": ["type": "string", "description": "Corps Markdown, sans titre H1"],
                            "folder": ["type": "string", "description": "Dossier, Inbox par défaut"]
                        ],
                        "required": ["title"],
                        "additionalProperties": false
                    ]
                ],
                [
                    "name": "update_note",
                    "description": "Modifie une note existante. Lire d'abord la note avec read_note et fournir sa révision. Les champs omis restent inchangés.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "UUID de la note"],
                            "revision": ["type": "string", "description": "Révision retournée par read_note"],
                            "title": ["type": "string", "description": "Nouveau titre"],
                            "content": ["type": "string", "description": "Nouveau corps Markdown, sans titre H1"],
                            "folder": ["type": "string", "description": "Nouveau dossier"]
                        ],
                        "required": ["id", "revision"],
                        "additionalProperties": false
                    ]
                ]
            ]
        }
        return ["tools": tools]
    case "resources/list":
        let notes = try vault.listNotes()
        var resources: [[String: Any]] = notes.map { note in
            [
                "uri": "wave://notes/\(note.id.uuidString)",
                "name": note.title,
                "description": "\(note.folder == "Inbox" ? "Documents" : note.folder) · Markdown",
                "mimeType": "text/markdown"
            ] as [String: Any]
        }
        resources.append([
            "uri": "wave://mind-map",
            "name": "Carte d'idées",
            "description": "Nœuds et connexions de la mind map Wave",
            "mimeType": "text/markdown"
        ])
        return ["resources": resources]
    case "resources/read":
        let params = message["params"] as? [String: Any] ?? [:]
        let uri = params["uri"] as? String ?? ""
        if uri == "wave://mind-map" {
            return ["contents": [[
                "uri": uri,
                "mimeType": "text/markdown",
                "text": mindMapMarkdown(try vault.loadMindMap())
            ]]]
        }
        guard uri.hasPrefix("wave://notes/"),
              let id = UUID(uuidString: String(uri.dropFirst("wave://notes/".count))),
              let note = try vault.readNote(id: id) else {
            throw MCPError.message("Note Wave introuvable pour l'URI \(uri).")
        }
        return ["contents": [[
            "uri": uri,
            "mimeType": "text/markdown",
            "text": note.markdown
        ]]]
    case "tools/call":
        return try callTool(message["params"] as? [String: Any] ?? [:], vault: vault)
    default:
        throw MCPError.message("Méthode inconnue : \(method)")
    }
}

private func callTool(_ params: [String: Any], vault: VaultStore) throws -> [String: Any] {
    let name = params["name"] as? String ?? ""
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    let text: String

    switch name {
    case "list_notes":
        let rawFolder = arguments["folder"] as? String
        let folder = rawFolder?.localizedCaseInsensitiveCompare("Documents") == .orderedSame ? "Inbox" : rawFolder
        let notes = try vault.listNotes(folder: folder)
        text = notes.isEmpty ? "Aucune note trouvée." : notes.map(summary).joined(separator: "\n")
    case "search_notes":
        guard let query = arguments["query"] as? String else {
            throw MCPError.message("Le paramètre query est requis.")
        }
        let notes = try vault.searchNotes(query: query)
        text = notes.isEmpty
            ? "Aucun résultat pour « \(query) »."
            : notes.map { note in
                "\(summary(note))\nExtrait : \(String(note.content.prefix(360)))"
            }.joined(separator: "\n\n")
    case "read_note":
        guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw MCPError.message("L'identifiant UUID de la note est invalide.")
        }
        guard let note = try vault.readNote(id: id) else {
            throw MCPError.message("Note Wave introuvable : \(rawID)")
        }
        return noteResult(note, text: note.markdown)
    case "create_note":
        try requireWriteAccess()
        guard let rawTitle = try optionalString("title", in: arguments) else {
            throw MCPError.message("Le titre de la note est requis.")
        }
        let title = try validTitle(rawTitle)
        let content = try optionalString("content", in: arguments) ?? ""
        let folder = try optionalString("folder", in: arguments) ?? "Inbox"
        let note = try vault.createNote(title: title, folder: folder, content: content)
        return noteResult(note, text: "Note créée : \(note.title) (id: \(note.id.uuidString), révision: \(revision(for: note))).")
    case "update_note":
        try requireWriteAccess()
        guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw MCPError.message("L'identifiant UUID de la note est invalide.")
        }
        guard let expectedRevision = arguments["revision"] as? String, !expectedRevision.isEmpty else {
            throw MCPError.message("La révision retournée par read_note est requise.")
        }
        guard let original = try vault.readNote(id: id) else {
            throw MCPError.message("Note Wave introuvable : \(rawID)")
        }
        guard revision(for: original) == expectedRevision else {
            throw MCPError.message("Cette note a changé depuis sa lecture. Relisez-la avant de la modifier.")
        }
        var updated = original
        if let title = try optionalString("title", in: arguments) {
            updated.title = try validTitle(title)
        }
        if let content = try optionalString("content", in: arguments) { updated.content = content }
        if let folder = try optionalString("folder", in: arguments) { updated.folder = VaultStore.normalizedFolderName(folder) }
        guard updated.title != original.title || updated.content != original.content || updated.folder != original.folder else {
            throw MCPError.message("Aucune modification à enregistrer.")
        }
        updated.modifiedAt = .now
        try vault.updateNote(updated, replacing: original)
        guard let saved = try vault.readNote(id: id) else {
            throw MCPError.message("La note modifiée est introuvable.")
        }
        return noteResult(saved, text: "Note modifiée : \(saved.title) (id: \(saved.id.uuidString), révision: \(revision(for: saved))).")
    case "read_mind_map":
        text = mindMapMarkdown(try vault.loadMindMap())
    case "read_attachment":
        guard let rawID = arguments["note_id"] as? String,
              let id = UUID(uuidString: rawID),
              let filename = arguments["filename"] as? String else {
            throw MCPError.message("Les paramètres note_id et filename sont requis.")
        }
        guard let note = try vault.readNote(id: id), note.attachments.contains(filename) else {
            throw MCPError.message("Pièce jointe introuvable dans cette note.")
        }
        text = try extractAttachmentText(at: vault.attachmentURL(noteID: id, filename: filename))
    case "list_tasks":
        let filterCompleted = arguments["completed"] as? Bool ?? false
        let notes = try vault.listNotes()
        var lines: [String] = []
        for note in notes {
            let matching = WritingTools.tasks(in: note.content).filter { $0.completed == filterCompleted }
            for task in matching {
                let box = task.completed ? "[x]" : "[ ]"
                lines.append("- \(box) \(task.text) — \(note.title) (id: \(note.id.uuidString))")
            }
        }
        text = lines.isEmpty ? "Aucune tâche trouvée." : lines.joined(separator: "\n")
    case "list_tags":
        let notes = try vault.listNotes()
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in WritingTools.tags(in: note.content) {
                counts[tag, default: 0] += 1
            }
        }
        let sorted = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        text = sorted.isEmpty
            ? "Aucun hashtag trouvé."
            : sorted.map { "#\($0.key) (\($0.value))" }.joined(separator: "\n")
    case "read_backlinks":
        guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw MCPError.message("L'identifiant UUID de la note est invalide.")
        }
        guard let target = try vault.readNote(id: id) else {
            throw MCPError.message("Note Wave introuvable : \(rawID)")
        }
        let needle = target.title.lowercased()
        let linking = try vault.listNotes().filter { candidate in
            candidate.id != target.id
                && WritingTools.wikiLinks(in: candidate.content).contains { $0.lowercased() == needle }
        }
        text = linking.isEmpty
            ? "Aucun rétrolien vers « \(target.title) »."
            : linking.map(summary).joined(separator: "\n")
    default:
        throw MCPError.message("Outil Wave inconnu : \(name)")
    }

    return ["content": [["type": "text", "text": text]], "isError": false]
}

private func requireWriteAccess() throws {
    guard writeEnabled else {
        throw MCPError.message("L'écriture MCP est désactivée. Activez-la dans IA & appareils, puis recopiez la configuration MCP dans le client.")
    }
}

private func optionalString(_ key: String, in arguments: [String: Any]) throws -> String? {
    guard let value = arguments[key] else { return nil }
    guard let text = value as? String else {
        throw MCPError.message("Le paramètre \(key) doit être un texte.")
    }
    return text
}

private func validTitle(_ title: String) throws -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .newlines) == nil else {
        throw MCPError.message("Le titre doit tenir sur une seule ligne et ne peut pas être vide.")
    }
    return trimmed
}

private func revision(for note: WaveNote) -> String {
    let data = Data((note.folder + "\u{0}" + note.markdown).utf8)
    return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func noteResult(_ note: WaveNote, text: String) -> [String: Any] {
    let currentRevision = revision(for: note)
    return [
        "content": [
            ["type": "text", "text": text],
            ["type": "text", "text": "Révision : \(currentRevision)"]
        ],
        "structuredContent": [
            "id": note.id.uuidString,
            "title": note.title,
            "folder": note.folder,
            "content": note.content,
            "markdown": note.markdown,
            "revision": currentRevision
        ],
        "isError": false
    ]
}

private func summary(_ note: WaveNote) -> String {
    let folder = note.folder == "Inbox" ? "Documents" : note.folder
    let attachmentSummary = note.attachments.isEmpty ? "" : " · pièces jointes: \(note.attachments.joined(separator: ", "))"
    return "- \(note.title) [\(folder)] (id: \(note.id.uuidString))\(attachmentSummary)"
}

private func mindMapMarkdown(_ mindMap: WaveMindMap) -> String {
    let nodesByID = Dictionary(mindMap.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let nodes = mindMap.nodes.map { node in
        let link = node.noteID.map { " · note: \($0.uuidString)" } ?? ""
        return "- **\(node.title)** — \(node.subtitle) (id: \(node.id.uuidString)\(link))"
    }
    let links = mindMap.edges.compactMap { edge -> String? in
        guard let from = nodesByID[edge.from], let to = nodesByID[edge.to] else { return nil }
        return "- \(from.title) → \(to.title)"
    }
    return "# Carte d’idées Wave\n\n## Nœuds\n\n\(nodes.joined(separator: "\n"))\n\n## Connexions\n\n\(links.joined(separator: "\n"))"
}

private func extractAttachmentText(at url: URL) throws -> String {
    switch url.pathExtension.lowercased() {
    case "pdf":
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw MCPError.message("Impossible d'ouvrir ce PDF.")
        }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pages.joined(separator: "\n\n")
        guard !text.isEmpty else { throw MCPError.message("Aucun texte extractible dans ce PDF.") }
        return text
        #else
        throw MCPError.message("L'extraction PDF nécessite PDFKit.")
        #endif
    case "docx":
        #if os(macOS)
        return try extractWordDocument(at: url)
        #else
        throw MCPError.message("L'extraction DOCX est disponible avec le serveur MCP macOS.")
        #endif
    case "md", "markdown", "txt", "text", "csv", "json", "xml", "html":
        return try String(contentsOf: url, encoding: .utf8)
    default:
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        throw MCPError.message("Le format .\(url.pathExtension) ne permet pas encore l'extraction de texte.")
    }
}

#if os(macOS)
private func extractWordDocument(at url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", url.path, "word/document.xml"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw MCPError.message("Impossible de lire le document Word : \(error.localizedDescription)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MCPError.message("Le document Word est illisible ou endommagé.")
    }
    let delegate = WordTextDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), !delegate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MCPError.message("Aucun texte extractible dans ce document Word.")
    }
    return delegate.text
}

private final class WordTextDelegate: NSObject, XMLParserDelegate {
    private var isReadingText = false
    var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        if name.hasSuffix(":t") || name == "t" { isReadingText = true }
        if name.hasSuffix(":tab") || name == "tab" { text.append("\t") }
        if name.hasSuffix(":br") || name == "br" { text.append("\n") }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingText { text.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        if name.hasSuffix(":t") || name == "t" { isReadingText = false }
        if name.hasSuffix(":p") || name == "p" { text.append("\n") }
    }
}
#endif

private func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else {
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private enum MCPError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}
