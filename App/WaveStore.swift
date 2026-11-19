import Foundation
import SwiftUI

/// Zero-idle-CPU file presenter watching the vault directory for external disk / iCloud Drive changes.
private final class VaultFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onExternalChange: @Sendable () -> Void

    init(url: URL, onExternalChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.presentedItemOperationQueue = queue
        self.onExternalChange = onExternalChange
        super.init()
    }

    func presentedItemDidChange() {
        onExternalChange()
    }

    func presentedSubitemDidChange(at url: URL) {
        // Ignore hidden metadata files (such as .Snapshots) to prevent self-triggered wakeups.
        if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { return }
        onExternalChange()
    }
}

@MainActor
final class WaveStore: ObservableObject {
    @Published private(set) var notes: [WaveNote] = [] {
        didSet { cachedSearch = nil }
    }
    @Published private(set) var trashedNotes: [TrashedNote] = []
    @Published private(set) var folders: [String] = ["Inbox"]
    @Published private(set) var tags: [String] = []
    @Published private(set) var openTaskCount: Int = 0
    @Published private(set) var vault: VaultStore
    @Published private(set) var isShared = false
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published private(set) var favoriteIDs: Set<UUID> = []
    @Published private(set) var recentIDs: [UUID] = []
    @Published private(set) var smartFolders: [SmartFolder] = []

    // Incremental per-note indexes (updated only on single-note upsert or full library load -> 0% idle CPU).
    private var noteTags: [UUID: [String]] = [:]
    private var noteTasks: [UUID: [DocumentTask]] = [:]
    private var noteWikiTargets: [UUID: Set<String>] = [:]
    private var cachedSearch: (query: String, notes: [WaveNote])?
    private var libraryRevision = 0
    private var lastSignature: VaultSnapshotSignature?
    private var refreshTask: Task<Void, Never>?
    private var presenterDebounceTask: Task<Void, Never>?
    private var suppressPresenterUntil: Date = .distantPast
    private var filePresenter: VaultFilePresenter?
    private var scopedURL: URL?
    private static let bookmarkKey = "wave.library.bookmark"

    init(vault: VaultStore? = nil) {
        self.vault = vault ?? VaultStore()
        if vault == nil, ProcessInfo.processInfo.environment["WAVE_VAULT_PATH"] == nil,
           let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            do {
                var stale = false
                #if os(macOS)
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                #else
                let url = try URL(resolvingBookmarkData: data, options: [.withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                #endif
                _ = url.startAccessingSecurityScopedResource()
                scopedURL = url
                self.vault = VaultStore(rootURL: url)
                isShared = true
                if stale { try persistBookmark(url) }
            } catch {
                errorMessage = "Le dossier partagé n’est plus accessible. Sélectionnez-le à nouveau dans IA & appareils. Vos notes locales restent disponibles."
            }
        }
        loadOrSeed()
        loadLibraryPreferences()
        registerFilePresenter()
    }

    deinit {
        presenterDebounceTask?.cancel()
        if let presenter = filePresenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    private func registerFilePresenter() {
        if let existing = filePresenter {
            NSFileCoordinator.removeFilePresenter(existing)
            filePresenter = nil
        }
        let presenter = VaultFilePresenter(url: vault.rootURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleExternalRefresh()
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        filePresenter = presenter
    }

    private func markLocalWrite() {
        suppressPresenterUntil = Date().addingTimeInterval(1.2)
    }

    private func scheduleExternalRefresh() {
        guard Date() >= suppressPresenterUntil else { return }
        presenterDebounceTask?.cancel()
        presenterDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, Date() >= self.suppressPresenterUntil else { return }
            self.refreshInBackground(reportErrors: false)
        }
    }

    var visibleNotes: [WaveNote] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        if let cachedSearch, cachedSearch.query == query { return cachedSearch.notes }
        let search = WritingTools.SearchQuery(query)
        let results = notes.filter { search.matches($0, cachedTags: noteTags[$0.id]) }
        cachedSearch = (query, results)
        return results
    }

    func tags(for noteID: UUID) -> [String] {
        noteTags[noteID] ?? []
    }

    func tasks(for noteID: UUID) -> [DocumentTask] {
        noteTasks[noteID] ?? []
    }

    func allNotesWithTasks() -> [(note: WaveNote, tasks: [DocumentTask])] {
        notes.compactMap { note in
            let items = noteTasks[note.id] ?? []
            return items.isEmpty ? nil : (note, items)
        }
    }

    func backlinks(for note: WaveNote) -> [WaveNote] {
        let needle = note.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return notes.filter { candidate in
            candidate.id != note.id && (noteWikiTargets[candidate.id]?.contains(needle) == true)
        }
    }

    @discardableResult
    func toggleTask(in noteID: UUID, lineIndex: Int) -> Bool {
        guard var target = note(id: noteID) else { return false }
        let updatedContent = WritingTools.togglingTask(atLine: lineIndex, in: target.content)
        guard updatedContent != target.content else { return false }
        let original = target
        target.content = updatedContent
        target.modifiedAt = .now
        return save(target, replacing: original)
    }

    struct SmartFolder: Identifiable, Codable { var id = UUID(); var name: String; var query: String }
    private var preferenceKey: String { "wave.library.preferences." + vault.rootURL.path }
    private struct LibraryPreferences: Codable { var favorites: Set<UUID>; var recents: [UUID]; var smartFolders: [SmartFolder] }
    func toggleFavorite(_ id: UUID) {
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
        persistLibraryPreferences()
    }
    func recordOpened(_ id: UUID) {
        guard recentIDs.first != id else { return }
        recentIDs.removeAll { $0 == id }; recentIDs.insert(id, at: 0)
        recentIDs = Array(recentIDs.prefix(25)); persistLibraryPreferences()
    }
    func addSmartFolder(name: String, query: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !query.isEmpty else { return }
        smartFolders.append(SmartFolder(name: name, query: query)); persistLibraryPreferences()
    }
    func removeSmartFolder(_ id: UUID) {
        smartFolders.removeAll { $0.id == id }; persistLibraryPreferences()
    }
    func filteredNotes(for route: SidebarRoute) -> [WaveNote] {
        switch route {
        case .favorites: return visibleNotes.filter { favoriteIDs.contains($0.id) }
        case .recents:
            let byID = Dictionary(visibleNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return recentIDs.compactMap { byID[$0] }
        case let .tag(tag): return visibleNotes.filter { noteTags[$0.id]?.contains(tag) == true }
        case let .smart(id):
            guard let folder = smartFolders.first(where: { $0.id == id }) else { return [] }
            let search = WritingTools.SearchQuery(folder.query)
            return visibleNotes.filter { search.matches($0, cachedTags: noteTags[$0.id]) }
        case let .folder(folder): return notes(in: folder)
        default: return visibleNotes
        }
    }
    func title(for route: SidebarRoute) -> String {
        switch route {
        case .favorites: return "Favoris"
        case .recents: return "Récemment ouverts"
        case .tasks: return "Tâches"
        case let .tag(tag): return "#" + tag
        case let .smart(id): return smartFolders.first { $0.id == id }?.name ?? "Recherche"
        case let .folder(folder): return folder == "Inbox" ? "Documents" : folder
        default: return searchText.isEmpty ? "Tous les documents" : "Recherche"
        }
    }
    private func loadLibraryPreferences() {
        let preferences = UserDefaults.standard.data(forKey: preferenceKey).flatMap { try? JSONDecoder().decode(LibraryPreferences.self, from: $0) }
        favoriteIDs = preferences?.favorites ?? []; recentIDs = preferences?.recents ?? []; smartFolders = preferences?.smartFolders ?? []
    }
    private func persistLibraryPreferences() {
        if let data = try? JSONEncoder().encode(LibraryPreferences(favorites: favoriteIDs, recents: recentIDs, smartFolders: smartFolders)) {
            UserDefaults.standard.set(data, forKey: preferenceKey)
        }
    }
    private func pruneReferences(removing ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            if favoriteIDs.remove(id) != nil { changed = true }
        }
        let filteredRecents = recentIDs.filter { !ids.contains($0) }
        if filteredRecents.count != recentIDs.count {
            recentIDs = filteredRecents
            changed = true
        }
        if changed { persistLibraryPreferences() }
    }

    func notes(in folder: String) -> [WaveNote] { visibleNotes.filter { $0.folder == folder } }
    func note(id: UUID) -> WaveNote? { notes.first { $0.id == id } }

    @discardableResult func importDocument(from url: URL, into folder: String = "Inbox") -> WaveNote? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parts = WritingTools.document(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
            return createNote(in: folder, title: parts.title, content: parts.body)
        } catch { report(error); return nil }
    }

    @discardableResult
    func createNote(in folder: String = "Inbox", title: String = "Sans titre", content: String = "") -> WaveNote? {
        markLocalWrite()
        do {
            let note = try vault.coordinated(writing: true) { try $0.createNote(title: title, folder: folder, content: content) }
            lastSignature = nil
            upsert(note)
            return note
        } catch { report(error); return nil }
    }

    @discardableResult
    func createNote(from template: WaveTemplate, in folder: String? = nil) -> WaveNote? {
        createNote(in: folder ?? template.folder, title: template.defaultTitle, content: template.content)
    }

    @discardableResult
    func openOrCreateDailyNote(date: Date = .now) -> WaveNote? {
        let title = WaveTemplate.dailyTitle(for: date)
        if let existing = notes.first(where: { $0.folder == "Journal" && $0.title == title })
            ?? notes.first(where: { $0.title == title }) {
            return existing
        }
        return createNote(from: WaveTemplate.daily(for: date))
    }

    @discardableResult
    func createFolder(_ name: String) -> String? {
        let folder = VaultStore.normalizedFolderName(name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        markLocalWrite()
        do {
            try vault.coordinated(writing: true) { try $0.createFolder(folder) }
            libraryRevision += 1
            lastSignature = nil
            ensureFolderListed(folder)
            return folder
        } catch { report(error); return nil }
    }

    @discardableResult
    func renameFolder(_ oldName: String, to newName: String) -> String? {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        markLocalWrite()
        do {
            let renamed = try vault.coordinated(writing: true) { try $0.renameFolder(oldName, to: newName) }
            libraryRevision += 1
            lastSignature = nil
            reload()
            return renamed
        } catch { report(error); return nil }
    }

    @discardableResult
    func deleteFolder(_ name: String) -> Bool {
        markLocalWrite()
        do {
            try vault.coordinated(writing: true) { try $0.deleteFolder(name) }
            libraryRevision += 1
            lastSignature = nil
            reload()
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func save(_ note: WaveNote, replacing original: WaveNote? = nil) -> Bool {
        markLocalWrite()
        do {
            let saved = try vault.coordinated(writing: true) { vault in
                if let original, original.markdown != note.markdown {
                    vault.recordSnapshotIfNeeded(for: original)
                }
                try vault.updateNote(note, replacing: original)
                return try vault.readNote(id: note.id, expectedFolder: note.folder) ?? note
            }
            lastSignature = nil
            upsert(saved)
            return true
        } catch { report(error); return false }
    }

    /// Non-blocking coordinated save for background autosave (avoids blocking @MainActor on iCloud Drive).
    func saveAsync(_ note: WaveNote, replacing original: WaveNote? = nil) async -> WaveNote? {
        markLocalWrite()
        let source = vault
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try source.coordinated(writing: true) { vault in
                    if let original, original.markdown != note.markdown {
                        vault.recordSnapshotIfNeeded(for: original)
                    }
                    try vault.updateNote(note, replacing: original)
                    return try vault.readNote(id: note.id, expectedFolder: note.folder) ?? note
                }
            }
        }.value
        switch result {
        case let .success(saved):
            guard source.rootURL == vault.rootURL else { return nil }
            lastSignature = nil
            upsert(saved)
            return saved
        case let .failure(error):
            report(error)
            return nil
        }
    }

    func snapshots(for noteID: UUID) -> [NoteSnapshot] {
        vault.listSnapshots(for: noteID)
    }

    func recordSnapshot(for note: WaveNote, force: Bool = false) {
        vault.recordSnapshotIfNeeded(for: note, force: force)
    }

    @discardableResult
    func moveNote(_ noteID: UUID, toFolder folder: String) -> Bool {
        guard let existing = note(id: noteID), existing.folder != folder else { return false }
        var moved = existing
        moved.folder = folder
        moved.modifiedAt = .now
        return save(moved, replacing: existing)
    }

    @discardableResult
    func duplicate(_ note: WaveNote) -> WaveNote? {
        markLocalWrite()
        do {
            let copy = try vault.coordinated(writing: true) { vault in
                let copy = try vault.createNote(title: note.title + " — copie", folder: note.folder, content: note.content)
                for filename in note.attachments {
                    try vault.addAttachment(noteID: copy.id, from: vault.attachmentURL(noteID: note.id, filename: filename))
                }
                return try vault.readNote(id: copy.id) ?? copy
            }
            lastSignature = nil
            upsert(copy)
            return copy
        } catch { report(error); return nil }
    }

    @discardableResult
    func delete(_ note: WaveNote) -> Bool {
        markLocalWrite()
        do {
            try vault.coordinated(writing: true) { try $0.deleteNote(id: note.id) }
            libraryRevision += 1
            lastSignature = nil
            removeIndex(for: note.id)
            notes.removeAll { $0.id == note.id }
            pruneReferences(removing: [note.id])
            return true
        } catch { report(error); return false }
    }

    /// Moves a document to the Corbeille. It can be restored for 30 days.
    @discardableResult
    func moveToTrash(_ note: WaveNote) -> Bool {
        markLocalWrite()
        do {
            let items = try vault.coordinated(writing: true) { vault in
                try vault.moveToTrash(note)
                return try vault.listTrashedNotes()
            }
            libraryRevision += 1
            lastSignature = nil
            removeIndex(for: note.id)
            notes.removeAll { $0.id == note.id }
            trashedNotes = items
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func restore(_ trashed: TrashedNote) -> WaveNote? {
        markLocalWrite()
        do {
            let restored = try vault.coordinated(writing: true) { try $0.restoreFromTrash(id: trashed.id) }
            lastSignature = nil
            upsert(restored)
            ensureFolderListed(restored.folder)
            trashedNotes.removeAll { $0.id == trashed.id }
            return restored
        } catch { report(error); return nil }
    }

    @discardableResult
    func deletePermanently(_ trashed: TrashedNote) -> Bool {
        markLocalWrite()
        do {
            try vault.coordinated(writing: true) { try $0.deleteFromTrash(id: trashed.id) }
            libraryRevision += 1
            lastSignature = nil
            trashedNotes.removeAll { $0.id == trashed.id }
            pruneReferences(removing: [trashed.id])
            return true
        } catch { report(error); return false }
    }

    func emptyTrash() {
        markLocalWrite()
        let removedIDs = Set(trashedNotes.map(\.id))
        do {
            try vault.coordinated(writing: true) { try $0.emptyTrash() }
            libraryRevision += 1
            lastSignature = nil
            trashedNotes = []
            pruneReferences(removing: removedIDs)
        } catch { report(error) }
    }

    /// Removes trashed documents older than 30 days. Called at launch and when
    /// the Corbeille is opened.
    func purgeTrashIfNeeded() {
        do {
            let removed = try vault.coordinated(writing: true) { try $0.purgeTrash() }
            if removed > 0 { lastSignature = nil }
            let items = try vault.coordinated { try $0.listTrashedNotes() }
            if items != trashedNotes {
                libraryRevision += 1
                trashedNotes = items
            }
        } catch { report(error) }
    }

    @discardableResult
    func importAttachment(from url: URL, to noteID: UUID) -> String? {
        markLocalWrite()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let filename = try vault.coordinated(writing: true) { try $0.addAttachment(noteID: noteID, from: url) }
            lastSignature = nil
            if var note = note(id: noteID) {
                note.attachments.append(filename)
                note.attachments.sort()
                upsert(note)
            } else { reload() }
            return filename
        } catch { report(error); return nil }
    }

    @discardableResult
    func importAttachmentData(_ data: Data, filename: String, to noteID: UUID) -> String? {
        markLocalWrite()
        do {
            let savedName = try vault.coordinated(writing: true) { try $0.addAttachmentData(data, filename: filename, to: noteID) }
            lastSignature = nil
            if var note = note(id: noteID) {
                note.attachments.append(savedName)
                note.attachments.sort()
                upsert(note)
            } else { reload() }
            return savedName
        } catch { report(error); return nil }
    }

    @discardableResult
    func removeAttachment(filename: String, from noteID: UUID) -> Bool {
        markLocalWrite()
        do {
            try vault.coordinated(writing: true) { try $0.removeAttachment(noteID: noteID, filename: filename) }
            lastSignature = nil
            if var note = note(id: noteID) {
                note.attachments.removeAll { $0 == filename }
                upsert(note)
            } else { reload() }
            return true
        } catch { report(error); return false }
    }

    func attachmentURL(noteID: UUID, filename: String) -> URL {
        vault.attachmentURL(noteID: noteID, filename: filename)
    }

    func reload(reportErrors: Bool = true) {
        do {
            let loaded = try vault.coordinated { store -> ([WaveNote], [String], [TrashedNote], VaultSnapshotSignature) in
                (try store.listNotes(), try store.listFolders(), try store.listTrashedNotes(), try store.snapshotSignature())
            }
            libraryRevision += 1
            lastSignature = loaded.3
            applyLibrary(notes: loaded.0, folders: loaded.1, trashed: loaded.2)
        } catch { if reportErrors { report(error) } }
    }

    func refreshInBackground(reportErrors: Bool = false) {
        guard refreshTask == nil else { return }
        let source = vault
        let revision = libraryRevision
        let previousSignature = lastSignature
        refreshTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                Result { () -> ([WaveNote], [String], [TrashedNote], VaultSnapshotSignature)? in
                    let signature = try source.snapshotSignature()
                    if let previousSignature, signature == previousSignature { return nil }
                    return try source.coordinated { store in
                        let freshSig = try store.snapshotSignature()
                        return (try store.listNotes(), try store.listFolders(), try store.listTrashedNotes(), freshSig)
                    }
                }
            }.value
            refreshTask = nil
            guard revision == libraryRevision, source.rootURL == vault.rootURL else { return }
            switch result {
            case let .success(loaded):
                if let loaded {
                    lastSignature = loaded.3
                    applyLibrary(notes: loaded.0, folders: loaded.1, trashed: loaded.2)
                }
            case let .failure(error): if reportErrors { report(error) }
            }
        }
    }

    private func ensureFolderListed(_ folder: String) {
        if !folders.contains(folder) {
            folders = (folders + [folder]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func indexNote(_ note: WaveNote) {
        noteTags[note.id] = WritingTools.tags(in: note.content)
        noteTasks[note.id] = WritingTools.tasks(in: note.content)
        noteWikiTargets[note.id] = Set(WritingTools.wikiLinks(in: note.content).map { $0.lowercased() })
    }

    private func removeIndex(for noteID: UUID) {
        noteTags.removeValue(forKey: noteID)
        noteTasks.removeValue(forKey: noteID)
        noteWikiTargets.removeValue(forKey: noteID)
        recomputeDerivedMetrics()
    }

    private func recomputeDerivedMetrics() {
        let nextTags = Array(Set(noteTags.values.flatMap { $0 })).sorted()
        if nextTags != tags { tags = nextTags }
        let nextOpenTasks = noteTasks.values.reduce(0) { partial, list in
            partial + list.filter { !$0.completed }.count
        }
        if nextOpenTasks != openTaskCount { openTaskCount = nextOpenTasks }
    }

    private func applyLibrary(notes loadedNotes: [WaveNote], folders loadedFolders: [String], trashed loadedTrashed: [TrashedNote] = []) {
        if notes != loadedNotes {
            let previousByID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var nextTagsMap: [UUID: [String]] = [:]
            var nextTasksMap: [UUID: [DocumentTask]] = [:]
            var nextWikiMap: [UUID: Set<String>] = [:]
            nextTagsMap.reserveCapacity(loadedNotes.count)
            nextTasksMap.reserveCapacity(loadedNotes.count)
            nextWikiMap.reserveCapacity(loadedNotes.count)
            for item in loadedNotes {
                if let prev = previousByID[item.id], prev.content == item.content,
                   let cachedTags = noteTags[item.id],
                   let cachedTasks = noteTasks[item.id],
                   let cachedLinks = noteWikiTargets[item.id] {
                    nextTagsMap[item.id] = cachedTags
                    nextTasksMap[item.id] = cachedTasks
                    nextWikiMap[item.id] = cachedLinks
                } else {
                    nextTagsMap[item.id] = WritingTools.tags(in: item.content)
                    nextTasksMap[item.id] = WritingTools.tasks(in: item.content)
                    nextWikiMap[item.id] = Set(WritingTools.wikiLinks(in: item.content).map { $0.lowercased() })
                }
            }
            noteTags = nextTagsMap
            noteTasks = nextTasksMap
            noteWikiTargets = nextWikiMap
            recomputeDerivedMetrics()
            notes = loadedNotes
        }
        if folders != loadedFolders { folders = loadedFolders }
        if trashedNotes != loadedTrashed { trashedNotes = loadedTrashed }
    }

    private func upsert(_ note: WaveNote) {
        libraryRevision += 1
        indexNote(note)
        recomputeDerivedMetrics()
        ensureFolderListed(note.folder)
        var updated = notes.filter { $0.id != note.id }
        updated.append(note)
        updated.sort { $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt }
        notes = updated
    }

    func useSharedFolder(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        do {
            let target = VaultStore(rootURL: url)
            if target.rootURL.standardizedFileURL != vault.rootURL.standardizedFileURL {
                try vault.coordinated { source in
                    try target.coordinated(writing: true) { try source.copyContents(to: $0) }
                }
            }
            try persistBookmark(url)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = didAccess ? url : nil
            vault = target
            isShared = true
            searchText = ""
            lastSignature = nil
            reload()
            loadLibraryPreferences()
            registerFilePresenter()
        } catch {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            report(error)
        }
    }

    func useLocalLibrary() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        vault = VaultStore()
        isShared = false
        searchText = ""
        lastSignature = nil
        loadOrSeed()
        loadLibraryPreferences()
        registerFilePresenter()
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    private func persistBookmark(_ url: URL) throws {
        #if os(macOS)
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func loadOrSeed() {
        do {
            try vault.coordinated(writing: true) { vault in
                try vault.prepare()
                // Never inject samples into an existing or shared library.
                let marker = vault.rootURL.appendingPathComponent(".did-seed-samples")
                if !isShared, try vault.listNotes().isEmpty, !FileManager.default.fileExists(atPath: marker.path) {
                    _ = try vault.createNote(title: "Bienvenue dans Wave", content: "Un espace calme pour vos idées.\n\n## Prenez le temps d’écrire\n\nRassemblez vos notes, vos projets et vos documents, sans quitter votre espace.\n\n- Créez un dossier pour chaque projet\n- Joignez vos documents avec le trombone\n- Partagez une note en Markdown ou copiez-la pour une IA\n\n## Retrouvez vos idées partout\n\nDans **IA & appareils**, choisissez un dossier iCloud Drive sur votre Mac et votre iPhone. Le serveur MCP sur le Mac permet à votre assistant de chercher et lire ces mêmes notes.")
                }
                if !isShared { try Data().write(to: marker, options: .atomic) }
            }
            reload()
            purgeTrashIfNeeded()
        } catch { report(error) }
    }
}
