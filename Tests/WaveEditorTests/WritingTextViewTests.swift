import XCTest
import AppKit
import SwiftUI
import WaveCore
@testable import WaveEditor

final class WritingTextViewTests: XCTestCase {
    func testFocusStylingStaysInsideViewportWhenCaretIsOffscreen() {
        let text = String(repeating: "Une phrase.\n\n", count: 2_000)
        let length = (text as NSString).length
        for mode in [WriterFocus.sentence, .paragraph] {
            for caret in [0, length] {
                let storage = NSTextStorage(string: text, attributes: [.foregroundColor: NSColor.systemRed])
                let visible = NSRange(location: caret == 0 ? length - 1_000 : 0, length: 500)
                WriterStyling.apply(to: storage, text: text, range: visible,
                                    selection: NSRange(location: caret, length: 0),
                                    configuration: WriterConfiguration(focus: mode))

                XCTAssertEqual(storage.attribute(.foregroundColor, at: length / 2, effectiveRange: nil) as? NSColor,
                               .systemRed, "Offscreen focus must not recolor the rest of the document")
                XCTAssertEqual(storage.attribute(.foregroundColor, at: visible.location + 100, effectiveRange: nil) as? NSColor,
                               WriterStyling.faded)
            }
        }
    }

    func testPartialStylingKeepsWholeEmojiTogetherOnLongLines() {
        let emoji = "🧑🏽‍💻"
        let text = String(repeating: emoji, count: 2_000)
        let storage = NSTextStorage(string: text, attributes: [.foregroundColor: NSColor.systemRed])
        let cluster = NSRange(location: 100 * (emoji as NSString).length, length: (emoji as NSString).length)
        WriterStyling.apply(to: storage, text: text,
                            range: NSRange(location: cluster.location + 1, length: 1),
                            selection: NSRange(location: 0, length: 0), configuration: WriterConfiguration())

        for offset in cluster.location..<NSMaxRange(cluster) {
            XCTAssertEqual(storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor,
                           WriterStyling.ink)
        }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
    }

    @MainActor
    func testForcedViewportStylingSurvivesAnotherScheduledUpdate() async throws {
        let text = "Une phrase."
        let parent = WritingTextView(text: .constant(text), selection: .constant(NSRange(location: 0, length: 0)),
                                     configuration: WriterConfiguration(), request: .constant(nil))
        let coordinator = parent.makeCoordinator()
        let view = WriterTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.string = text
        coordinator.scheduleStyle(view)
        try await Task.sleep(nanoseconds: 180_000_000)
        view.textStorage!.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                       range: NSRange(location: 0, length: (text as NSString).length))

        coordinator.scheduleStyle(view, force: true)
        coordinator.scheduleStyle(view)
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       WriterStyling.ink)
        XCTAssertEqual(view.string, text)
    }

    func testSelectAllKeepsTextDarkInFocusMode() {
        let text = "Première phrase. Deuxième phrase.\n\nDernier paragraphe."
        let storage = NSTextStorage(string: text)
        let selection = NSRange(location: 0, length: storage.length)

        WriterStyling.apply(to: storage, text: text, selection: selection,
                            configuration: WriterConfiguration(focus: .sentence))

        let outsideFirstSentence = (text as NSString).range(of: "Dernier").location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: outsideFirstSentence, effectiveRange: nil) as? NSColor,
                       WriterStyling.ink)
    }

    func testFocusFadesUnselectedTextAndRestoresItAfterModeChanges() {
        let text = "Première phrase. Deuxième phrase."
        let storage = NSTextStorage(string: text)
        let second = (text as NSString).range(of: "Deuxième").location
        let caret = NSRange(location: 3, length: 0)

        WriterStyling.apply(to: storage, text: text, selection: caret,
                            configuration: WriterConfiguration(focus: .sentence))
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: second, effectiveRange: nil) as? NSColor,
                          WriterStyling.ink)

        WriterStyling.apply(to: storage, text: text, selection: caret,
                            configuration: WriterConfiguration(focus: .off))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: second, effectiveRange: nil) as? NSColor,
                       WriterStyling.ink)
    }

    func testLongUnbrokenLineStylesOnlyRequestedWindow() {
        let text = String(repeating: "a", count: 100_000)
        let storage = NSTextStorage(string: text,
                                    attributes: [.foregroundColor: NSColor.systemRed])
        let range = NSRange(location: 80_000, length: 2_000)

        WriterStyling.apply(to: storage, text: text, range: range,
                            selection: NSRange(location: 81_000, length: 0),
                            configuration: WriterConfiguration())

        XCTAssertEqual(storage.length, 100_000)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .systemRed)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 81_000, effectiveRange: nil) as? NSColor,
                       WriterStyling.ink)
    }

    func testFormattingEditsOnlySelectedRangeWithUnicode() {
        let text = "Avant 🧑🏽‍💻 idée après"
        let selection = (text as NSString).range(of: "idée")
        let edit = WriterStyling.edit(text: text, selection: selection, command: "bold")

        XCTAssertEqual(edit.range, selection)
        XCTAssertEqual(edit.replacement, "**idée**")
        XCTAssertEqual((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement),
                       "Avant 🧑🏽‍💻 **idée** après")
        XCTAssertEqual(edit.selection, NSRange(location: selection.location + 2, length: selection.length))
    }

    func testRepeatedNativeEditingKeepsInputAndSelectionAfterStyling() {
        let view = NSTextView()
        view.string = String(repeating: "Une phrase de test.\n", count: 2_000)
        let original = view.string
        view.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        let inserted = String(repeating: "🧑🏽‍💻 idée ", count: 100)

        for character in inserted {
            let value = String(character)
            view.insertText(value, replacementRange: view.selectedRange())
            let caret = view.selectedRange()
            let start = max(0, caret.location - 1_500)
            WriterStyling.apply(to: view.textStorage!, text: view.string,
                                range: NSRange(location: start, length: 3_000),
                                selection: caret, configuration: WriterConfiguration())
        }

        XCTAssertEqual(view.string, original + inserted)
        XCTAssertEqual(view.selectedRange(), NSRange(location: (view.string as NSString).length, length: 0))
    }
}
