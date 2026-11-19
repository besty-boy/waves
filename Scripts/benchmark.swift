import Foundation

/// Local, disposable workload for comparing library and search performance.
@main
enum WaveBenchmark {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WaveBenchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultStore(rootURL: root)
        let paragraph = "Une idée claire pour le projet. #projet Écrire vite et retrouver ses notes facilement.\n"
        for index in 0..<600 {
            _ = try vault.createNote(title: "Document \(index)", folder: index.isMultiple(of: 3) ? "Travail" : "Inbox",
                                     content: String(repeating: paragraph, count: 12))
        }

        var notes = try vault.listNotes()
        print("Bibliothèque temporaire : \(notes.count) notes")
        try measure("Lecture bibliothèque", iterations: 8) {
            notes = try vault.coordinated { try $0.listNotes() }
            return notes.count
        }
        try measure("Vérification des changements", iterations: 8) {
            try vault.coordinated { try $0.libraryChangeToken() }
        }
        let textQuery = WritingTools.SearchQuery("idée projet")
        measure("Recherche texte", iterations: 12) {
            notes.filter { textQuery.matches($0) }.count
        }
        let cachedTags = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, WritingTools.tags(in: $0.content)) })
        let tagQuery = WritingTools.SearchQuery("#projet")
        measure("Recherche hashtag", iterations: 12) {
            notes.filter { tagQuery.matches($0, cachedTags: cachedTags[$0.id]) }.count
        }
        var edited = notes[0]
        try measure("Sauvegarde coordonnée", iterations: 12) {
            let previous = edited
            edited.content += "x"
            edited = try vault.coordinated(writing: true) { store in
                try store.updateNote(edited, replacing: previous)
                return try store.readNote(id: edited.id, expectedFolder: edited.folder)!
            }
            return edited.content.count
        }
        let longDocument = String(repeating: paragraph, count: 2_000)
        measure("Titre et corps 180 Ko", iterations: 12) {
            WritingTools.document(longDocument, fallbackTitle: "Note").body.count
        }
        measure("Concentration phrase 180 Ko", iterations: 5) {
            WritingTools.focusRange(in: longDocument, caret: (longDocument as NSString).length * 9 / 10, mode: .sentence).location
        }
        measure("Concentration paragraphe 180 Ko", iterations: 5) {
            WritingTools.focusRange(in: longDocument, caret: (longDocument as NSString).length * 9 / 10, mode: .paragraph).location
        }
        measure("Statistiques 180 Ko", iterations: 5) {
            WritingStatistics(longDocument).words
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            print(String(format: "Pic mémoire du processus : %.1f Mo", Double(usage.ru_maxrss) / 1_048_576))
        }
    }

    private static func measure(_ name: String, iterations: Int, _ operation: () throws -> Int) rethrows {
        var samples: [Double] = []
        var result = 0
        for index in 0...iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            result = try operation()
            if index > 0 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        }
        samples.sort()
        print(String(format: "%@: médiane %.2f ms · p95 %.2f ms · résultat %d", name, samples[samples.count / 2], samples[Int(ceil(Double(samples.count) * 0.95)) - 1], result))
    }
}
