import XCTest
@testable import WaveCore

final class WritingToolsTests: XCTestCase {
    func testDocumentEditingPreservesTitlelessContentAndEmptyTitles() {
        let document = WritingTools.document("# Carnet\n\nUne idée.\n\nUne autre.", fallbackTitle: "Ancien")
        XCTAssertEqual(document.title, "Carnet")
        XCTAssertEqual(document.body, "Une idée.\n\nUne autre.")
        let noHeading = WritingTools.document("Le titre a été retiré.\n\nLe corps reste.", fallbackTitle: "Carnet")
        XCTAssertEqual(noHeading.title, "Carnet")
        XCTAssertEqual(noHeading.body, "Le titre a été retiré.\n\nLe corps reste.")
        XCTAssertEqual(WritingTools.document("# \n\nTexte", fallbackTitle: "Ancien").title, "Sans titre")
    }
    func testFocusRangesAreSafeForEmojiAndAccentedCharacters() {
        let text = "Une idée 🧑🏽‍💻. Une autre phrase.\n\nTroisième paragraphe."
        let string = text as NSString
        let caret = string.range(of: "autre").location
        let sentence = WritingTools.focusRange(in: text, caret: caret, mode: .sentence)
        XCTAssertEqual(string.substring(with: sentence).trimmingCharacters(in: .whitespacesAndNewlines), "Une autre phrase.")
        let paragraph = WritingTools.focusRange(in: text, caret: caret, mode: .paragraph)
        XCTAssertEqual(string.substring(with: paragraph), "Une idée 🧑🏽‍💻. Une autre phrase.")
        let end = WritingTools.focusRange(in: text, caret: string.length, mode: .sentence)
        XCTAssertEqual(string.substring(with: end), "Troisième paragraphe.")
        XCTAssertEqual(WritingTools.focusRange(in: "", caret: 5, mode: .sentence), NSRange(location: 0, length: 0))
        XCTAssertLessThanOrEqual(NSMaxRange(WritingTools.focusRange(in: text, caret: 999, mode: .paragraph)), string.length)
    }
    func testTagsIgnoreMarkdownHeadingsCodeAndURLFragments() {
        let tags = WritingTools.tags(in: "# Titre\n#projet #écriture #Projet #work-in-progress\n`#code`\n```\n#masqué\n```\nhttps://example.com/#fragment")
        XCTAssertEqual(Set(tags), Set(["projet", "écriture", "work-in-progress"]))
    }
    func testSearchCombinesPhrasesTagsFieldsAndExclusions() {
        let note = WaveNote(title: "Un beau projet", folder: "Travail", content: "Une idée précise. #écriture")
        XCTAssertTrue(WritingTools.search("\"idée précise\" #écriture folder:travail", in: note))
        XCTAssertTrue(WritingTools.search("title:projet -terminé", in: note))
        XCTAssertFalse(WritingTools.search("#écrit", in: note))
        XCTAssertFalse(WritingTools.search("projet -précise", in: note))
        XCTAssertTrue(WritingTools.search("", in: note))
        let prepared = WritingTools.SearchQuery("#écriture -title:autre")
        XCTAssertTrue(prepared.matches(note, cachedTags: ["écriture"]))
        XCTAssertFalse(prepared.matches(note, cachedTags: []))
    }
    func testStatisticsCountUnicodeCharactersAndTasks() {
        let stats = WritingStatistics("Bonjour 🧑🏽‍💻.\n- [ ] Écrire\n- [x] Relire\n- [X] Publier")
        XCTAssertEqual(stats.tasks, 3)
        XCTAssertEqual(stats.completedTasks, 2)
        XCTAssertEqual(WritingStatistics("🧑🏽‍💻é").characters, 2)
        XCTAssertEqual(WritingStatistics("").readingMinutes, 0)
        XCTAssertEqual(WritingStatistics("Bonjour").readingMinutes, 1)
        XCTAssertGreaterThan(stats.words, 3)
    }
    func testPreviewEscapesHTMLAndDisallowsExecutableLinks() {
        let html = WriterMarkdown.body("# Titre\n\n<script>alert('x')</script>\n\n[Dangereux](javascript:alert)\n\n![secret](../../private.png)")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("src=\"../../"))
        XCTAssertFalse(WriterMarkdown.inline("`**code**`").contains("<strong>"))
    }
    func testWordExportCreatesValidZipAndStyledUnicodeDocument() throws {
        #if os(macOS)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("WaveWord-" + UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: file) }
        try WriterWord.document("# Carnet 🧑🏽‍💻\n\nUn texte **fort** & utile.\n\n- [x] Écrire").write(to: file)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        check.arguments = ["-t", file.path]
        check.standardOutput = Pipe(); check.standardError = Pipe()
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        let read = Process(), output = Pipe()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        read.arguments = ["-p", file.path, "word/document.xml"]
        read.standardOutput = output
        try read.run()
        let xml = output.fileHandleForReading.readDataToEndOfFile()
        read.waitUntilExit()
        XCTAssertTrue(XMLParser(data: xml).parse())
        let text = String(decoding: xml, as: UTF8.self)
        XCTAssertTrue(text.contains("Carnet 🧑🏽‍💻"))
        XCTAssertTrue(text.contains("<w:b/>"))
        XCTAssertTrue(text.contains("&amp;"))
        XCTAssertTrue(text.contains("Heading1"))
        #endif
    }
    func testPreviewRendersTablesTasksLinksAndUnclosedFences() {
        let html = WriterMarkdown.body("| A | B |\n| --- | --- |\n| un | deux |\n\n- [x] Fait\n- [ ] À faire\n\n[[Carnet]]\n\n```swift\nlet value = 1 < 2")
        XCTAssertTrue(html.contains("<th>A</th>"))
        XCTAssertTrue(html.contains("<td>deux</td>"))
        XCTAssertTrue(html.contains("☑"))
        XCTAssertTrue(html.contains("wave-note:///Carnet"))
        XCTAssertTrue(html.contains("1 &lt; 2"))
    }
}
