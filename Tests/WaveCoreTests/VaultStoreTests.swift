import XCTest
@testable import WaveCore

final class VaultStoreTests: XCTestCase {
    private var root: URL!
    private var vault: VaultStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WaveTests-\(UUID().uuidString)")
        vault = VaultStore(rootURL: root)
        try vault.prepare()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMarkdownRoundTripAndMovePreserveIdentityAndAttachments() throws {
        var note = try vault.createNote(title: "Pensée du jour", content: "## Une idée\n\nUn texte **utile**.")
        let attachment = root.appendingPathComponent("source.txt")
        try "Une source".write(to: attachment, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: attachment)
        note.folder = "Recherche"
        note.title = "Une nouvelle pensée"
        try vault.updateNote(note)
        let loaded = try XCTUnwrap(vault.readNote(id: note.id))
        XCTAssertEqual(loaded.title, note.title)
        XCTAssertEqual(loaded.content, note.content)
        XCTAssertEqual(loaded.folder, "Recherche")
        XCTAssertEqual(loaded.attachments, ["source.txt"])
        XCTAssertEqual(try vault.listNotes().count, 1)
        XCTAssertEqual(try vault.searchNotes(query: "UTILE").map(\.id), [note.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.notesURL.appendingPathComponent("\(note.id).md").path))
    }

    func testFolderNamesCannotEscapeVault() throws {
        let note = try vault.createNote(title: "Test", folder: "../../Secrets")
        XCTAssertEqual(note.folder, "Secrets")
        XCTAssertEqual(try vault.listNotes().first?.folder, note.folder)
        XCTAssertEqual(VaultStore.normalizedFolderName(".."), "Inbox")
        XCTAssertEqual(VaultStore.normalizedFolderName("  "), "Inbox")
    }

    func testAttachmentImportNeverOverwritesDuplicateFilename() throws {
        let note = try vault.createNote(title: "Fichiers")
        let source = root.appendingPathComponent("document.txt")
        try "Version 1".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(try vault.addAttachment(noteID: note.id, from: source), "document.txt")
        try "Version 2".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(try vault.addAttachment(noteID: note.id, from: source), "document-2.txt")
        XCTAssertEqual(try String(contentsOf: vault.attachmentURL(noteID: note.id, filename: "document.txt")), "Version 1")
    }

    func testAddAttachmentDataCreatesUniqueFilesOffline() throws {
        let note = try vault.createNote(title: "Captures")
        let first = try vault.addAttachmentData(Data([0x89, 0x50, 0x4E, 0x47]), filename: "capture.png", to: note.id)
        let second = try vault.addAttachmentData(Data([0x89, 0x50, 0x4E, 0x48]), filename: "capture.png", to: note.id)
        XCTAssertEqual(first, "capture.png")
        XCTAssertEqual(second, "capture-2.png")
        XCTAssertEqual(try vault.readNote(id: note.id)?.attachments, ["capture-2.png", "capture.png"])
    }

    func testRemoveAttachmentDeletesFileAndUpdatesNote() throws {
        let note = try vault.createNote(title: "Pièces")
        let source = root.appendingPathComponent("rapport.txt")
        try "Contenu".write(to: source, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: source)
        XCTAssertEqual(try vault.readNote(id: note.id)?.attachments, ["rapport.txt"])

        try vault.removeAttachment(noteID: note.id, filename: "rapport.txt")
        XCTAssertEqual(try vault.readNote(id: note.id)?.attachments, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.attachmentURL(noteID: note.id, filename: "rapport.txt").path))
    }

    func testRenameAndDeleteFolderPreserveNotes() throws {
        let note = try vault.createNote(title: "Idée", folder: "Brouillons", content: "Texte")
        try vault.renameFolder("Brouillons", to: "Projets")
        XCTAssertTrue(try vault.listFolders().contains("Projets"))
        XCTAssertFalse(try vault.listFolders().contains("Brouillons"))
        XCTAssertEqual(try vault.readNote(id: note.id)?.folder, "Projets")

        try vault.deleteFolder("Projets")
        XCTAssertFalse(try vault.listFolders().contains("Projets"))
        XCTAssertEqual(try vault.readNote(id: note.id)?.folder, "Inbox")
    }

    func testSnapshotSignatureTracksChanges() throws {
        let initial = try vault.snapshotSignature()
        XCTAssertEqual(initial, try vault.snapshotSignature())

        let note = try vault.createNote(title: "Signature", content: "A")
        let afterCreate = try vault.snapshotSignature()
        XCTAssertNotEqual(initial, afterCreate)
        XCTAssertEqual(afterCreate, try vault.snapshotSignature())

        var edited = note
        edited.content = "Contenu beaucoup plus long pour garantir un changement de taille"
        try vault.updateNote(edited)
        XCTAssertNotEqual(afterCreate, try vault.snapshotSignature())
    }

    func testLocalOfflineSnapshotsRecordDeduplicatePruneAndCleanup() throws {
        var note = try vault.createNote(title: "Historique", content: "Version 1")
        vault.recordSnapshotIfNeeded(for: note, minInterval: 0, maxPerNote: 3, force: true)
        // Duplicate markdown is ignored even with force: true.
        vault.recordSnapshotIfNeeded(for: note, minInterval: 0, maxPerNote: 3, force: true)
        XCTAssertEqual(vault.listSnapshots(for: note.id).count, 1)

        for idx in 2...5 {
            Thread.sleep(forTimeInterval: 0.01)
            note.content = "Version \(idx)"
            vault.recordSnapshotIfNeeded(for: note, minInterval: 0, maxPerNote: 3, force: true)
        }
        let snapshots = vault.listSnapshots(for: note.id)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertTrue(snapshots[0].markdown.contains("Version 5"))

        try vault.deleteNote(id: note.id)
        XCTAssertTrue(vault.listSnapshots(for: note.id).isEmpty)
    }

    func testHeadingsTasksWikiLinksAndTemplates() {
        let markdown = """
        # Titre principal

        Intro avec [[Projet Alpha]] et `[[Ignoré]]`.

        ```markdown
        # Faux titre dans code
        - [ ] Fausse tâche dans code
        ```

        ## Actions
        - [ ] Écrire les tests
        - [x] Compiler le projet
        Voir aussi [[Projet Alpha]] et [[Idée B]].
        """
        let headings = WritingTools.headings(in: markdown)
        XCTAssertEqual(headings.map(\.title), ["Titre principal", "Actions"])
        XCTAssertEqual(headings.map(\.level), [1, 2])
        let ns = markdown as NSString
        XCTAssertTrue(ns.substring(from: headings[1].utf16Location).hasPrefix("## Actions"))

        let tasks = WritingTools.tasks(in: markdown)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].text, "Écrire les tests")
        XCTAssertFalse(tasks[0].completed)
        XCTAssertTrue(tasks[1].completed)

        let toggled = WritingTools.togglingTask(atLine: tasks[0].lineIndex, in: markdown)
        XCTAssertTrue(WritingTools.tasks(in: toggled)[0].completed)

        let links = WritingTools.wikiLinks(in: markdown)
        XCTAssertEqual(links, ["Projet Alpha", "Idée B"])

        XCTAssertGreaterThanOrEqual(WaveTemplate.builtIn.count, 4)
        let daily = WaveTemplate.daily(for: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(daily.folder, "Journal")
        XCTAssertFalse(daily.content.isEmpty)
    }

    func testSharedLibraryMigrationPreservesBothConflictingVersions() throws {
        let destination = VaultStore(rootURL: root.appendingPathComponent("Shared"))
        let note = try vault.createNote(title: "Projet", folder: "Travail", content: "Version locale")
        let source = root.appendingPathComponent("source.txt")
        try "Pièce jointe".write(to: source, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: source)
        var remote = note
        remote.content = "Version distante"
        try destination.updateNote(remote)
        try vault.coordinated { source in try destination.coordinated(writing: true) { try source.copyContents(to: $0) } }
        let merged = try destination.listNotes()
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(try destination.readNote(id: note.id)?.content, "Version distante")
        let copy = try XCTUnwrap(merged.first { $0.id != note.id })
        XCTAssertEqual(copy.content, "Version locale")
        XCTAssertEqual(copy.attachments, ["source.txt"])
        XCTAssertEqual(try vault.readNote(id: note.id)?.content, "Version locale")
    }

    func testRepeatMigrationDoesNotDuplicateUnchangedNotes() throws {
        let destination = VaultStore(rootURL: root.appendingPathComponent("Shared"))
        _ = try vault.createNote(title: "Sans conflit", content: "Identique")
        try vault.copyContents(to: destination)
        try vault.copyContents(to: destination)
        XCTAssertEqual(try destination.listNotes().count, 1)
    }

    func testExternalMarkdownKeepsStableIdentityWhenVaultChanges() throws {
        let external = vault.notesURL.appendingPathComponent("mon-carnet.md")
        try "# Carnet\n\nÉcrit ailleurs.\n".write(to: external, atomically: true, encoding: .utf8)
        let note = try XCTUnwrap(vault.listNotes().first)
        let other = VaultStore(rootURL: root.appendingPathComponent("Other"))
        try vault.copyContents(to: other)
        XCTAssertEqual(try other.readNote(id: note.id)?.content, "Écrit ailleurs.")
    }

    func testUnreadableMarkdownIsReportedInsteadOfDisappearing() throws {
        try Data([0xFF, 0xFE, 0xAB]).write(to: vault.notesURL.appendingPathComponent("broken.md"))
        XCTAssertThrowsError(try vault.listNotes())
    }

    func testLibraryChangeTokenTracksNotesFoldersTrashAndAttachments() throws {
        let initial = try vault.libraryChangeToken()
        let note = try vault.createNote(title: "Suivi")
        let withNote = try vault.libraryChangeToken()
        XCTAssertNotEqual(initial, withNote)
        XCTAssertEqual(withNote, try vault.libraryChangeToken())

        try vault.createFolder("Projet")
        let withFolder = try vault.libraryChangeToken()
        XCTAssertNotEqual(withNote, withFolder)

        let attachment = root.appendingPathComponent("source.txt")
        try "Texte".write(to: attachment, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: attachment)
        let withAttachment = try vault.libraryChangeToken()
        XCTAssertNotEqual(withFolder, withAttachment)

        try vault.moveToTrash(note)
        XCTAssertNotEqual(withAttachment, try vault.libraryChangeToken())
    }

    func testMapRoundTripAndMigrationNeverReplaceExistingMap() throws {
        var map = WaveMindMap.starter()
        let linkedID = UUID()
        map.nodes[0].noteID = linkedID
        try vault.saveMindMap(map)
        let loaded = try vault.loadMindMap()
        XCTAssertEqual(loaded, map)
        XCTAssertEqual(loaded.nodes[0].noteID, linkedID)

        let destination = VaultStore(rootURL: root.appendingPathComponent("Shared"))
        let remote = WaveMindMap(nodes: [], edges: [])
        try destination.saveMindMap(remote)
        try vault.copyContents(to: destination)
        XCTAssertEqual(try destination.loadMindMap(), remote)
    }

    func testSearchQuerySupportsOperatorsAndDocumentsAlias() throws {
        let inboxNote = try vault.createNote(title: "Note rapide", folder: "Inbox", content: "Idée #design\n- [ ] Finaliser maquette")
        let projectNote = try vault.createNote(title: "Spec", folder: "Projets", content: "Plan #dev")
        let source = root.appendingPathComponent("spec.pdf")
        try Data("PDF".utf8).write(to: source)
        try vault.addAttachment(noteID: projectNote.id, from: source)

        XCTAssertEqual(try vault.searchNotes(query: "folder:Documents").map(\.id), [inboxNote.id])
        XCTAssertEqual(try vault.searchNotes(query: "#design").map(\.id), [inboxNote.id])
        XCTAssertEqual(try vault.searchNotes(query: "has:task").map(\.id), [inboxNote.id])
        XCTAssertEqual(try vault.searchNotes(query: "has:attachment").map(\.id), [projectNote.id])
        XCTAssertEqual(try vault.searchNotes(query: "folder:Projets #dev").map(\.id), [projectNote.id])
    }

    func testWriterMarkdownSnakeCaseNestedListsAndDarkCSS() {
        let md = """
        Variable `my_var` and plain snake_case_identifier and _italic_ and ***bold italic***.

        > Ligne 1
        > Ligne 2

        - Parent
          - Enfant
        """
        let html = WriterMarkdown.html(md, title: "Test", fontFamily: "Mono", colorScheme: "dark")
        XCTAssertTrue(html.contains("snake_case_identifier"))
        XCTAssertFalse(html.contains("snake<em>case</em>identifier"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<strong><em>bold italic</em></strong>"))
        XCTAssertTrue(html.contains("<blockquote>Ligne 1<br>Ligne 2</blockquote>"))
        XCTAssertTrue(html.contains("<ul>\n<li>Parent</li>\n<ul>\n<li>Enfant</li>\n</ul>\n</ul>"))
        XCTAssertTrue(html.contains("color-scheme:dark"))
    }

    func testDeletionRemovesNoteAndItsAttachments() throws {
        let note = try vault.createNote(title: "À supprimer")
        let source = root.appendingPathComponent("source.txt")
        try "Texte".write(to: source, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: source)
        try vault.deleteNote(id: note.id)
        XCTAssertNil(try vault.readNote(id: note.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.attachmentURL(noteID: note.id, filename: "source.txt").path))
    }

    func testConcurrentNoteEditCannotOverwriteRemoteChanges() throws {
        let original = try vault.createNote(title: "Partagée", content: "Initiale")
        var remote = original
        remote.content = "Modifiée ailleurs"
        try vault.updateNote(remote)
        var draft = original
        draft.content = "Mon brouillon"
        XCTAssertThrowsError(try vault.coordinated(writing: true) { try $0.updateNote(draft, replacing: original) })
        XCTAssertEqual(try vault.readNote(id: original.id)?.content, "Modifiée ailleurs")
    }

    func testDeletedNoteCannotBeResurrectedByPendingAutosave() throws {
        let original = try vault.createNote(title: "Partagée")
        try vault.deleteNote(id: original.id)
        var draft = original
        draft.content = "Brouillon en attente"
        XCTAssertThrowsError(try vault.updateNote(draft, replacing: original))
        XCTAssertNil(try vault.readNote(id: original.id))
    }

    func testNewMapCanBeSavedAndConcurrentMapChangesArePreserved() throws {
        let original = try vault.loadMindMap()
        XCTAssertEqual(original.nodes.count, 0)
        let first = WaveMindMap.starter()
        try vault.saveMindMap(first, replacing: original)
        XCTAssertEqual(try vault.loadMindMap(), first)
        let remote = WaveMindMap(nodes: [first.nodes[0]], edges: [])
        try vault.saveMindMap(remote)
        XCTAssertThrowsError(try vault.saveMindMap(first, replacing: first))
        XCTAssertEqual(try vault.loadMindMap(), remote)
    }

    func testTrashKeepsIdentityFolderAndAttachments() throws {
        let note = try vault.createNote(title: "À ranger", folder: "Projets", content: "Un texte")
        let source = root.appendingPathComponent("piece.txt")
        try "Pièce".write(to: source, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: source)

        try vault.moveToTrash(note)
        XCTAssertTrue(try vault.listNotes().isEmpty)
        let trashed = try XCTUnwrap(vault.listTrashedNotes().first)
        XCTAssertEqual(trashed.note.id, note.id)
        XCTAssertEqual(trashed.note.title, "À ranger")
        XCTAssertEqual(trashed.note.folder, "Projets")
        XCTAssertEqual(trashed.note.attachments, ["piece.txt"])
        XCTAssertEqual(trashed.daysRemaining(), 30)

        let restored = try vault.restoreFromTrash(id: note.id)
        XCTAssertEqual(restored.id, note.id)
        XCTAssertEqual(restored.folder, "Projets")
        XCTAssertEqual(restored.content, "Un texte")
        XCTAssertEqual(restored.attachments, ["piece.txt"])
        XCTAssertTrue(try vault.listTrashedNotes().isEmpty)
        XCTAssertEqual(try vault.listNotes().count, 1)
    }

    func testTrashPermanentDeletionRemovesAttachments() throws {
        let note = try vault.createNote(title: "Éphémère")
        let source = root.appendingPathComponent("source.txt")
        try "Texte".write(to: source, atomically: true, encoding: .utf8)
        try vault.addAttachment(noteID: note.id, from: source)

        try vault.moveToTrash(note)
        try vault.deleteFromTrash(id: note.id)
        XCTAssertTrue(try vault.listTrashedNotes().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.attachmentURL(noteID: note.id, filename: "source.txt").path))
    }

    func testTrashPurgesOnlyExpiredNotes() throws {
        let old = try vault.createNote(title: "Ancienne")
        let recent = try vault.createNote(title: "Récente")
        try vault.moveToTrash(old)
        try vault.moveToTrash(recent)

        let sidecar = vault.trashURL.appendingPathComponent("\(old.id.uuidString).json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        metadata["deletedAt"] = Date().addingTimeInterval(-31 * 86_400).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: metadata).write(to: sidecar)

        XCTAssertEqual(try vault.purgeTrash(), 1)
        XCTAssertEqual(try vault.listTrashedNotes().map(\.note.id), [recent.id])

        try vault.emptyTrash()
        XCTAssertTrue(try vault.listTrashedNotes().isEmpty)
    }

    func testTrashedNoteIsNotListedAsRegularNote() throws {
        let note = try vault.createNote(title: "Cachée")
        try vault.moveToTrash(note)
        XCTAssertTrue(try vault.listNotes().isEmpty)
        XCTAssertTrue(try vault.searchNotes(query: "Cachée").isEmpty)
        XCTAssertEqual(try vault.listFolders(), ["Inbox"])
    }
}
