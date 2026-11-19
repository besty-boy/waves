import Foundation

/// Lightweight metadata fingerprint of the vault, used to skip redundant full reads during background sync.
public struct VaultSnapshotSignature: Equatable, Sendable {
    public struct Entry: Equatable, Hashable, Sendable {
        public let path: String
        public let modifiedAt: TimeInterval
        public let size: Int
    }
    public let entries: [Entry]
}

/// Offline version snapshot for a single note, stored locally in `.Snapshots/<noteID>/`.
public struct NoteSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let markdown: String

    public init(id: String, createdAt: Date, markdown: String) {
        self.id = id
        self.createdAt = createdAt
        self.markdown = markdown
    }

    public var preview: String {
        let cleaned = markdown.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- `")) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ")
        return cleaned.isEmpty ? "Document vide" : String(cleaned.prefix(140))
    }
}

/// Markdown-first storage shared by the Wave app and the Wave MCP process.
public struct VaultStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else if let configuredPath = ProcessInfo.processInfo.environment["WAVE_VAULT_PATH"], !configuredPath.isEmpty {
            self.rootURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        } else if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            self.rootURL = appSupport.appendingPathComponent("Wave", isDirectory: true)
        } else {
            self.rootURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Wave", isDirectory: true)
        }
    }

    public var notesURL: URL {
        rootURL.appendingPathComponent("Notes", isDirectory: true)
    }

    public var mindMapURL: URL {
        rootURL.appendingPathComponent("MindMap.json")
    }

    public var snapshotsURL: URL {
        rootURL.appendingPathComponent(".Snapshots", isDirectory: true)
    }

    /// Coordinate directory access with iCloud Drive and other document providers.
    public func coordinated<T>(writing: Bool = false, _ operation: (VaultStore) throws -> T) throws -> T {
        // Coordination requires an existing root, including for a brand-new local vault.
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        let accessor: (URL) -> Void = { url in
            result = Result { try operation(VaultStore(rootURL: url)) }
        }
        if writing {
            coordinator.coordinate(writingItemAt: rootURL, options: .forMerging, error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: rootURL, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    /// Fast stat-only fingerprint of Notes, Attachments, and Trash directories to avoid re-reading
    /// unchanged Markdown files during background refreshes.
    public func snapshotSignature() throws -> VaultSnapshotSignature {
        try prepare()
        var entries: [VaultSnapshotSignature.Entry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let roots = [notesURL, rootURL.appendingPathComponent("Attachments", isDirectory: true), trashURL]
        let baseCount = rootURL.path.count
        for directory in roots where FileManager.default.fileExists(atPath: directory.path) {
            if let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    let rel = String(url.path.dropFirst(baseCount))
                    let mtime = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                    let size = values?.isDirectory == true ? -1 : (values?.fileSize ?? 0)
                    entries.append(.init(path: rel, modifiedAt: mtime, size: size))
                }
            }
        }
        entries.sort { $0.path < $1.path }
        return VaultSnapshotSignature(entries: entries)
    }

    /// Copy into a shared library without replacing its existing notes or map.
    /// A conflicting UUID becomes a separate copy, including its attachments.
    public func copyContents(to destination: VaultStore) throws {
        try destination.prepare()
        for folder in try listFolders() { try destination.createFolder(folder) }
        for note in try listNotes() {
            let existing = try destination.readNote(id: note.id)
            var target = note
            if let existing, existing.title != note.title || existing.content != note.content || existing.folder != note.folder {
                target = WaveNote(title: note.title + " — copie locale", folder: note.folder,
                                  content: note.content, modifiedAt: note.modifiedAt)
            }
            if existing == nil || target.id != note.id { try destination.updateNote(target) }
            for filename in note.attachments {
                let targetURL = destination.attachmentURL(noteID: target.id, filename: filename)
                if !FileManager.default.fileExists(atPath: targetURL.path) {
                    try destination.addAttachment(noteID: target.id, from: attachmentURL(noteID: note.id, filename: filename))
                }
            }
        }
        if FileManager.default.fileExists(atPath: mindMapURL.path),
           !FileManager.default.fileExists(atPath: destination.mindMapURL.path) {
            try FileManager.default.copyItem(at: mindMapURL, to: destination.mindMapURL)
        }
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Attachments", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// A cheap fingerprint for deciding whether the library needs to be parsed
    /// again. It covers notes, trash metadata, folders and attachments.
    /// A full reload is still performed periodically to cover providers that
    /// preserve file dates while synchronizing changes.
    public func libraryChangeToken() throws -> Int {
        var hasher = Hasher()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .fileSizeKey]
        for directory in [notesURL, trashURL, rootURL.appendingPathComponent("Attachments", isDirectory: true)] {
            hasher.combine(directory.lastPathComponent)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { throw CocoaError(.fileReadUnknown) }
            var entries: [(String, Bool, Int, Date?)] = []
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                entries.append((String(url.path.dropFirst(directory.path.count)),
                                values.isDirectory == true, values.fileSize ?? 0,
                                values.contentModificationDate))
            }
            for entry in entries.sorted(by: { $0.0 < $1.0 }) {
                hasher.combine(entry.0)
                hasher.combine(entry.1)
                hasher.combine(entry.2)
                hasher.combine(entry.3)
            }
        }
        return hasher.finalize()
    }

    public func listFolders() throws -> [String] {
        try prepare()
        let entries = try FileManager.default.contentsOfDirectory(
            at: notesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let folders = entries.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url.lastPathComponent
        }
        return Array(Set(["Inbox"] + folders)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func createFolder(_ name: String) throws {
        if safeFolderName(name) == "Inbox" { try prepare(); return }
        try FileManager.default.createDirectory(
            at: notesURL.appendingPathComponent(safeFolderName(name), isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// Renames a user folder. Cannot rename `Inbox` or overwrite an existing folder.
    @discardableResult
    public func renameFolder(_ oldName: String, to newName: String) throws -> String {
        try prepare()
        let oldSafe = safeFolderName(oldName)
        let newSafe = safeFolderName(newName)
        guard oldSafe != "Inbox", newSafe != "Inbox" else { throw VaultError.invalidFolderName }
        if oldSafe == newSafe { return newSafe }
        let source = notesURL.appendingPathComponent(oldSafe, isDirectory: true)
        let destination = notesURL.appendingPathComponent(newSafe, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { throw VaultError.folderNotFound }
        if FileManager.default.fileExists(atPath: destination.path) { throw VaultError.folderAlreadyExists }
        try FileManager.default.moveItem(at: source, to: destination)
        return newSafe
    }

    /// Deletes a user folder after moving any contained notes safely to `Inbox`.
    public func deleteFolder(_ name: String) throws {
        try prepare()
        let safe = safeFolderName(name)
        guard safe != "Inbox" else { throw VaultError.invalidFolderName }
        let directory = notesURL.appendingPathComponent(safe, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in items {
            let dest = uniqueURL(in: notesURL, filename: item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: dest)
        }
        try FileManager.default.removeItem(at: directory)
    }

    public func loadMindMap() throws -> WaveMindMap {
        try prepare()
        guard FileManager.default.fileExists(atPath: mindMapURL.path) else {
            return WaveMindMap(nodes: [], edges: [])
        }
        return try JSONDecoder().decode(WaveMindMap.self, from: Data(contentsOf: mindMapURL))
    }

    public func saveMindMap(_ mindMap: WaveMindMap, replacing original: WaveMindMap? = nil) throws {
        try prepare()
        if let original, try loadMindMap() != original { throw VaultError.mapChanged }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(mindMap).write(to: mindMapURL, options: .atomic)
    }

    public func listNotes(folder: String? = nil) throws -> [WaveNote] {
        try prepare()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: notesURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var notes: [WaveNote] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let note = try loadNote(at: fileURL)
            if folder == nil || note.folder.localizedCaseInsensitiveCompare(folder!) == .orderedSame {
                notes.append(note)
            }
        }
        return notes.sorted { $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt }
    }

    public func readNote(id: UUID, expectedFolder: String? = nil) throws -> WaveNote? {
        let url = try noteURL(for: id, expectedFolder: expectedFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadNote(at: url)
    }

    @discardableResult
    public func createNote(title: String, folder: String = "Inbox", content: String = "") throws -> WaveNote {
        try prepare()
        let note = WaveNote(title: title, folder: Self.normalizedFolderName(folder), content: content)
        let destination = try destinationURL(for: note)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try note.markdown.write(to: destination, atomically: true, encoding: .utf8)
        return try loadNote(at: destination)
    }

    public func updateNote(_ note: WaveNote, replacing original: WaveNote? = nil) throws {
        try prepare()
        if let original {
            guard let disk = try readNote(id: note.id, expectedFolder: original.folder) else { throw VaultError.noteDeleted }
            guard disk.title == original.title, disk.content == original.content, disk.folder == original.folder else {
                throw VaultError.noteChanged
            }
        }
        let existingURL = try noteURL(for: note.id, expectedFolder: original?.folder ?? note.folder)
        let destination = try destinationURL(for: note)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try note.markdown.write(to: destination, atomically: true, encoding: .utf8)
        if existingURL.standardizedFileURL != destination.standardizedFileURL,
           FileManager.default.fileExists(atPath: existingURL.path) {
            try FileManager.default.removeItem(at: existingURL)
        }
    }

    public func deleteNote(id: UUID) throws {
        let url = try noteURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let attachmentURL = rootURL.appendingPathComponent("Attachments/\(id.uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: attachmentURL.path) {
            try FileManager.default.removeItem(at: attachmentURL)
        }
        deleteSnapshots(for: id)
    }

    // MARK: - Local Offline Snapshots

    /// Records a lightweight local snapshot when enough time elapsed (default 5 min) and text changed.
    public func recordSnapshotIfNeeded(for note: WaveNote, minInterval: TimeInterval = 300, maxPerNote: Int = 10, force: Bool = false) {
        let directory = snapshotsURL.appendingPathComponent(note.id.uuidString, isDirectory: true)
        let existing = listSnapshots(for: note.id)
        if let latest = existing.first {
            if latest.markdown == note.markdown { return }
            if !force && Date().timeIntervalSince(latest.createdAt) < minInterval { return }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
            let file = directory.appendingPathComponent("\(stamp).md")
            try note.markdown.write(to: file, atomically: true, encoding: .utf8)
            // Prune oldest snapshots beyond maxPerNote to keep disk footprint tiny.
            let updated = listSnapshots(for: note.id)
            if updated.count > maxPerNote {
                for stale in updated.dropFirst(maxPerNote) {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale.id))
                }
            }
        } catch {
            // Snapshots are best-effort and must never interrupt writing.
        }
    }

    public func listSnapshots(for noteID: UUID) -> [NoteSnapshot] {
        let directory = snapshotsURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url -> NoteSnapshot? in
            guard url.pathExtension.lowercased() == "md",
                  let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let base = url.deletingPathExtension().lastPathComponent
            let date: Date
            if let seconds = TimeInterval(base) {
                date = Date(timeIntervalSince1970: seconds)
            } else {
                date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            }
            return NoteSnapshot(id: url.lastPathComponent, createdAt: date, markdown: markdown)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func deleteSnapshots(for noteID: UUID) {
        let directory = snapshotsURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Corbeille

    public static let trashRetentionDays = 30

    public var trashURL: URL {
        rootURL.appendingPathComponent("Trash", isDirectory: true)
    }

    /// Moves a note to the trash, keeping its identity, attachments and origin folder.
    public func moveToTrash(_ note: WaveNote) throws {
        try prepare()
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let source = try noteURL(for: note.id, expectedFolder: note.folder)
        let destination = trashURL.appendingPathComponent("\(note.id.uuidString).md")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try note.markdown.write(to: destination, atomically: true, encoding: .utf8)
        }
        try writeTrashMetadata(TrashMetadata(deletedAt: .now, folder: note.folder), for: note.id)
    }

    public func listTrashedNotes() throws -> [TrashedNote] {
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var notes: [TrashedNote] = []
        for fileURL in files where fileURL.pathExtension.lowercased() == "md" {
            var note = try loadNote(at: fileURL)
            let metadata = try? trashMetadata(for: note.id)
            note.folder = metadata?.folder ?? "Inbox"
            let deletedAt = metadata?.deletedAt
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .now
            notes.append(TrashedNote(note: note, deletedAt: deletedAt))
        }
        return notes.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Restores a trashed note to its original folder. If the destination already
    /// exists, the note comes back as a copy instead of overwriting anything.
    @discardableResult
    public func restoreFromTrash(id: UUID) throws -> WaveNote {
        let source = trashURL.appendingPathComponent("\(id.uuidString).md")
        guard FileManager.default.fileExists(atPath: source.path) else { throw VaultError.noteDeleted }
        let folder = (try? trashMetadata(for: id))?.folder ?? "Inbox"
        try prepare()
        let targetDirectory = folder == "Inbox" ? notesURL : notesURL.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let destination = targetDirectory.appendingPathComponent("\(id.uuidString).md")
        if FileManager.default.fileExists(atPath: destination.path) {
            var trashed = try loadNote(at: source)
            trashed.folder = folder
            trashed.title += " — copie"
            let copy = try createNote(title: trashed.title, folder: folder, content: trashed.content)
            for filename in trashed.attachments {
                try addAttachment(noteID: copy.id, from: attachmentURL(noteID: id, filename: filename))
            }
            try deleteFromTrash(id: id)
            return copy
        }
        try FileManager.default.moveItem(at: source, to: destination)
        try removeTrashMetadata(for: id)
        return try readNote(id: id, expectedFolder: folder) ?? loadNote(at: destination)
    }

    /// Removes a trashed note for good, including its attachments and snapshots.
    public func deleteFromTrash(id: UUID) throws {
        let source = trashURL.appendingPathComponent("\(id.uuidString).md")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.removeItem(at: source)
        }
        try removeTrashMetadata(for: id)
        let attachments = rootURL.appendingPathComponent("Attachments/\(id.uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: attachments.path) {
            try FileManager.default.removeItem(at: attachments)
        }
        deleteSnapshots(for: id)
    }

    /// Deletes trashed notes older than the retention delay. Returns the number of removed notes.
    @discardableResult
    public func purgeTrash(olderThan days: Int = VaultStore.trashRetentionDays, now: Date = .now) throws -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let expired = try listTrashedNotes().filter { $0.deletedAt < cutoff }
        for item in expired { try deleteFromTrash(id: item.id) }
        return expired.count
    }

    public func emptyTrash() throws {
        for item in try listTrashedNotes() { try deleteFromTrash(id: item.id) }
    }

    private struct TrashMetadata: Codable {
        var deletedAt: Date
        var folder: String
    }

    private func trashMetadata(for id: UUID) throws -> TrashMetadata {
        let url = trashURL.appendingPathComponent("\(id.uuidString).json")
        return try JSONDecoder().decode(TrashMetadata.self, from: Data(contentsOf: url))
    }

    private func writeTrashMetadata(_ metadata: TrashMetadata, for id: UUID) throws {
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: trashURL.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    private func removeTrashMetadata(for id: UUID) throws {
        let url = trashURL.appendingPathComponent("\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    public func addAttachment(noteID: UUID, from sourceURL: URL) throws -> String {
        try prepare()
        let directory = rootURL.appendingPathComponent("Attachments/\(noteID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceName = sourceURL.lastPathComponent.isEmpty ? "Pièce jointe" : sourceURL.lastPathComponent
        let destination = uniqueURL(in: directory, filename: sourceName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination.lastPathComponent
    }

    /// Saves raw pasted data (e.g. clipboard screenshot) directly as a unique attachment.
    @discardableResult
    public func addAttachmentData(_ data: Data, filename: String, to noteID: UUID) throws -> String {
        try prepare()
        let directory = rootURL.appendingPathComponent("Attachments/\(noteID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let destination = uniqueURL(in: directory, filename: safeName.isEmpty ? "image.png" : safeName)
        try data.write(to: destination, options: .atomic)
        return destination.lastPathComponent
    }

    public func removeAttachment(noteID: UUID, filename: String) throws {
        guard !filename.contains("/"), !filename.contains("\\"), filename != ".", filename != ".." else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = attachmentURL(noteID: noteID, filename: filename)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    public func attachmentURL(noteID: UUID, filename: String) -> URL {
        rootURL.appendingPathComponent("Attachments/\(noteID.uuidString)", isDirectory: true)
            .appendingPathComponent(filename)
    }

    public func searchNotes(query: String) throws -> [WaveNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let search = WritingTools.SearchQuery(needle)
        return try listNotes().filter { search.matches($0) }
    }

    private func loadNote(at url: URL) throws -> WaveNote {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let lines = markdown.components(separatedBy: .newlines)
        let headingIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let heading = headingIndex.map { lines[$0] } ?? ""
        let title = heading.hasPrefix("# ")
            ? String(heading.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            : url.deletingPathExtension().lastPathComponent
        let content: String
        if let headingIndex, heading.hasPrefix("# ") {
            content = lines.dropFirst(headingIndex + 1).drop(while: { $0.isEmpty })
                .joined(separator: "\n").trimmingCharacters(in: .newlines)
        } else {
            content = markdown
        }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let parentDir = url.deletingLastPathComponent().standardizedFileURL
        let notesDir = notesURL.standardizedFileURL
        let folder: String
        if parentDir == notesDir {
            folder = "Inbox"
        } else {
            let relative = parentDir.path.hasPrefix(notesDir.path + "/")
                ? String(parentDir.path.dropFirst(notesDir.path.count + 1))
                : parentDir.lastPathComponent
            folder = relative.split(separator: "/").first.map(String.init) ?? "Inbox"
        }
        let attachmentDirectory = rootURL.appendingPathComponent("Attachments/\(stableID(for: url).uuidString)")
        let attachments = (try? FileManager.default.contentsOfDirectory(
            at: attachmentDirectory,
            includingPropertiesForKeys: nil
        ))?.map(\.lastPathComponent).sorted() ?? []

        return WaveNote(
            id: stableID(for: url),
            title: title.isEmpty ? "Sans titre" : title,
            folder: folder,
            content: content,
            modifiedAt: values?.contentModificationDate ?? .now,
            attachments: attachments
        )
    }

    private func noteURL(for id: UUID, expectedFolder: String? = nil) throws -> URL {
        try prepare()
        if let expectedFolder {
            let folder = safeFolderName(expectedFolder)
            let directory = folder == "Inbox" ? notesURL : notesURL.appendingPathComponent(folder, isDirectory: true)
            let candidate = directory.appendingPathComponent("\(id.uuidString).md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let enumerator = FileManager.default.enumerator(at: notesURL, includingPropertiesForKeys: nil) else {
            return notesURL.appendingPathComponent("\(id.uuidString).md")
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
            if fileURL.deletingPathExtension().lastPathComponent == id.uuidString
                || stableID(for: fileURL) == id {
                return fileURL
            }
        }
        return notesURL.appendingPathComponent("\(id.uuidString).md")
    }

    private func stableID(for fileURL: URL) -> UUID {
        if let id = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent) { return id }

        let relativePath = String(fileURL.path.dropFirst(notesURL.path.count))
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 1_099_511_628_211
        for byte in relativePath.utf8 {
            first = (first ^ UInt64(byte)) &* 1_099_511_628_211
            second = (second ^ (UInt64(byte) &+ 0x9D)) &* 1_099_511_628_211
        }
        var firstBytes = first.bigEndian
        var secondBytes = second.bigEndian
        let bytes = withUnsafeBytes(of: &firstBytes) { Array($0) }
            + withUnsafeBytes(of: &secondBytes) { Array($0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func destinationURL(for note: WaveNote) throws -> URL {
        let folder = safeFolderName(note.folder)
        let directory = folder == "Inbox" ? notesURL : notesURL.appendingPathComponent(folder, isDirectory: true)
        return directory.appendingPathComponent("\(note.id.uuidString).md")
    }

    private func safeFolderName(_ value: String) -> String { Self.normalizedFolderName(value) }

    public static func normalizedFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        return safe.isEmpty || safe == "." || safe == ".." ? "Inbox" : safe
    }

    private func uniqueURL(in directory: URL, filename: String) -> URL {
        let initial = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let base = initial.deletingPathExtension().lastPathComponent
        let ext = initial.pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(index)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

public struct TrashedNote: Identifiable, Hashable, Codable, Sendable {
    public let note: WaveNote
    public let deletedAt: Date

    public init(note: WaveNote, deletedAt: Date = .now) {
        self.note = note
        self.deletedAt = deletedAt
    }

    public var id: UUID { note.id }

    public var expiresAt: Date {
        deletedAt.addingTimeInterval(TimeInterval(VaultStore.trashRetentionDays) * 86_400)
    }

    public func daysRemaining(from date: Date = .now) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(date) / 86_400)))
    }
}

public enum VaultError: LocalizedError {
    case noteDeleted, noteChanged, mapChanged
    case invalidFolderName, folderNotFound, folderAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .noteDeleted:
            "Cette note a été supprimée ailleurs. Votre brouillon est conservé localement. Utilisez « Enregistrer une copie » pour garder votre texte."
        case .noteChanged:
            "Cette note a changé sur un autre appareil. Votre brouillon est conservé localement. Utilisez « Enregistrer une copie » pour garder votre version."
        case .mapChanged:
            "La carte d’idées a changé sur un autre appareil. Votre brouillon est conservé localement. Utilisez « Brouillon » pour réessayer ou enregistrer une copie."
        case .invalidFolderName:
            "Ce nom de dossier n’est pas autorisé."
        case .folderNotFound:
            "Ce dossier est introuvable."
        case .folderAlreadyExists:
            "Un dossier portant ce nom existe déjà."
        }
    }
}
