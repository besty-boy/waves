import Foundation

/// Exercises the app's real library model in a disposable vault.
@main
enum LibraryChecks {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WaveLibraryTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "wave.library.preferences." + root.path)
        }
        let vault = VaultStore(rootURL: root)
        for index in 0..<600 {
            _ = try vault.createNote(title: "Document \(index)", content: "Une idée pour le projet. #projet")
        }
        let store = WaveStore(vault: vault)
        store.searchText = "idée #projet"
        try check(store.visibleNotes.count == 600, "Initial search")
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            try check(store.visibleNotes.count == 600, "Repeated search")
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        print(String(format: "Recherche répétée, 600 notes : médiane %.3f ms · p95 %.3f ms",
                     samples[samples.count / 2], samples[Int(ceil(Double(samples.count) * 0.95)) - 1]))

        store.searchText = "title:cible #projet"
        try check(store.visibleNotes.isEmpty, "Query change")
        guard let created = store.createNote(title: "Cible", content: "Une idée. #projet") else {
            throw Failure(message: "Creation: \(store.errorMessage ?? "unknown error")")
        }
        try check(store.visibleNotes.map(\.id) == [created.id], "Creation invalidates search")
        var edited = created
        edited.content = "Une idée. #autre"
        try check(store.save(edited, replacing: created), "Save")
        try check(store.visibleNotes.isEmpty, "Content and tags invalidate search")
        store.searchText = "#autre"
        try check(store.visibleNotes.map(\.id) == [created.id], "New hashtag")
        guard let saved = store.note(id: created.id) else { throw Failure(message: "Saved note missing") }
        try check(store.moveToTrash(saved), "Move to trash")
        try check(store.visibleNotes.isEmpty, "Trash invalidates search")
        guard let trashed = store.trashedNotes.first, let restored = store.restore(trashed) else {
            throw Failure(message: "Restore failed")
        }
        try check(store.visibleNotes.map(\.id) == [created.id], "Restore invalidates search")
        var external = restored
        external.title = "Titre externe"
        external.content = "Contenu externe. #externe"
        try vault.coordinated(writing: true) { try $0.updateNote(external, replacing: restored) }
        store.reload()
        try check(store.visibleNotes.isEmpty, "External reload invalidates search")
        store.searchText = "#externe title:externe"
        try check(store.visibleNotes.map(\.id) == [created.id], "External content and tags")
        try check(store.moveToTrash(external), "Trash external note")
        guard let lastTrash = store.trashedNotes.first else { throw Failure(message: "Trash missing") }
        try check(store.deletePermanently(lastTrash), "Permanent deletion")
        store.reload()
        try check(store.trashedNotes.isEmpty && store.visibleNotes.isEmpty, "Deletion persists after reload")
        try check(store.errorMessage == nil, "Library error: \(store.errorMessage ?? "")")
        print("Bibliothèque : recherche, création, sauvegarde, hashtags, corbeille, restauration et modification externe validées.")
    }

    private struct Failure: Error { let message: String }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
