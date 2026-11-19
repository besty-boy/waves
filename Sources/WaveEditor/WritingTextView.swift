import SwiftUI
import NaturalLanguage
import CoreText
#if SWIFT_PACKAGE
import WaveCore
#endif
#if os(macOS)
import AppKit
typealias WriterNativeFont = NSFont
typealias WriterNativeColor = NSColor
#else
import UIKit
typealias WriterNativeFont = UIFont
typealias WriterNativeColor = UIColor
#endif

struct WriterConfiguration: Equatable {
    var family: String = "Mono"
    var size: Double = 20
    var columns: Double = 64
    var focus: WriterFocus = .off
    var syntax = false
    var styleCheck = false
    var customPatterns = ""
    var contentWidth: CGFloat { CGFloat(columns * size * (family == "Quattro" ? 0.51 : 0.6)) }
}

struct WriterEditRequest: Equatable {
    let id = UUID()
    var command: String
    var insertText: String? = nil
    var jumpLocation: Int? = nil
    var replaceRange: NSRange? = nil
}

struct WriterEditPatch: Equatable {
    let range: NSRange
    let replacement: String
    let newSelection: NSRange
}

enum WriterFonts {
    static func register() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
    static func font(_ family: String, size: CGFloat, style: String = "Regular") -> WriterNativeFont {
        if let font = WriterNativeFont(name: "iAWriter\(family)S-\(style)", size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: style.contains("Bold") ? .bold : .regular)
    }
}

enum WriterStyling {
    struct GrammarHighlight: Sendable {
        let range: NSRange
        let colorIndex: Int
    }

    private static func dynamicColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> WriterNativeColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        #else
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        #endif
    }

    static let canvasBackground = dynamicColor(light: (1.0, 1.0, 1.0), dark: (0.086, 0.086, 0.094))
    static let ink = dynamicColor(light: (0.114, 0.114, 0.122), dark: (0.925, 0.925, 0.937))
    static let muted = dynamicColor(light: (0.50, 0.50, 0.53), dark: (0.55, 0.55, 0.60))
    static let faded = dynamicColor(light: (0.76, 0.76, 0.78), dark: (0.35, 0.35, 0.38))
    static let insertionColor = dynamicColor(light: (0.0, 0.486, 0.765), dark: (0.227, 0.663, 0.961))
    static let selectionBackground = dynamicColor(light: (0.73, 0.85, 0.96), dark: (0.16, 0.35, 0.54))

    static let grammarNativeColors: [WriterNativeColor] = [
        dynamicColor(light: (0.64, 0.36, 0.13), dark: (0.92, 0.63, 0.36)), // Noms
        dynamicColor(light: (0.15, 0.42, 0.72), dark: (0.42, 0.72, 0.98)), // Verbes
        dynamicColor(light: (0.68, 0.22, 0.32), dark: (0.95, 0.48, 0.56)), // Adjectifs
        dynamicColor(light: (0.45, 0.32, 0.70), dark: (0.74, 0.60, 0.98)), // Adverbes
        dynamicColor(light: (0.18, 0.52, 0.31), dark: (0.38, 0.82, 0.54))  // Conjonctions
    ]

    static let grammarLegend: [(label: String, color: Color)] = {
        let labels = ["Noms", "Verbes", "Adjectifs", "Adverbes", "Conjonctions"]
        return zip(labels, grammarNativeColors).map { label, native in
            #if os(macOS)
            (label, Color(nsColor: native))
            #else
            (label, Color(uiColor: native))
            #endif
        }
    }()

    static func attributes(_ configuration: WriterConfiguration) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(configuration.size * 0.42)
        paragraph.paragraphSpacing = 0
        return [.font: WriterFonts.font(configuration.family, size: CGFloat(configuration.size)),
                .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    /// Determines whether `offset` sits inside an unclosed triple-backtick fenced code block.
    private static func isInsideCodeFence(in string: NSString, before location: Int) -> Bool {
        guard location > 0 else { return false }
        let prefix = string.substring(with: NSRange(location: 0, length: min(location, string.length)))
        var inFence = false
        prefix.enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
        }
        return inFence
    }

    /// Applies the editor styling. `range` limits the work to a portion of the
    /// document (incremental styling while typing); `nil` styles everything.
    static func apply(to storage: NSTextStorage, text: String, range requested: NSRange? = nil,
                      selection: NSRange, configuration: WriterConfiguration) {
        let length = storage.length
        guard length > 0 else { return }
        let string = text as NSString
        var target = requested ?? NSRange(location: 0, length: length)
        let location = max(0, min(target.location, length))
        target = NSRange(location: location, length: max(0, min(target.length, length - location)))
        guard target.length > 0 else { return }
        // A viewport boundary may fall inside an emoji or combining sequence.
        target = string.rangeOfComposedCharacterSequences(for: target)
        // Expand to full lines so each paragraph is styled coherently.
        let lines = string.lineRange(for: target)
        // A pasted paragraph without line breaks can be enormous. Keep a
        // bounded styling window instead of blocking the editor on that line.
        if lines.length <= 12_000 {
            target = NSRange(location: lines.location, length: min(lines.length, length - lines.location))
        }
        guard target.length > 0 else { return }

        let segment = string.substring(with: target)
        func offset(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + target.location, length: range.length)
        }
        let base = attributes(configuration)
        let boldFont = WriterFonts.font(configuration.family, size: CGFloat(configuration.size), style: "Bold")
        let italicFont = WriterFonts.font(configuration.family, size: CGFloat(configuration.size), style: "Italic")
        let boldItalicFont = WriterFonts.font(configuration.family, size: CGFloat(configuration.size), style: "BoldItalic")

        storage.beginEditing()
        storage.setAttributes(base, range: target)

        // Track fenced code blocks accurately across incremental windows.
        var inFence = isInsideCodeFence(in: string, before: target.location)
        var fencedRanges: [NSRange] = []
        var cursor = 0
        let nsSegment = segment as NSString
        while cursor < nsSegment.length {
            let lineRange = nsSegment.lineRange(for: NSRange(location: cursor, length: 0))
            let line = nsSegment.substring(with: lineRange)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                fencedRanges.append(lineRange)
                inFence.toggle()
            } else if inFence {
                fencedRanges.append(lineRange)
            }
            cursor = NSMaxRange(lineRange)
        }

        // Keep Markdown punctuation visible, with quiet accents and genuine font traits.
        for match in WritingTools.matches(#"(?m)^(#{1,6}) .*$"#, in: segment) {
            storage.addAttribute(.font, value: boldFont, range: offset(match.range))
            storage.addAttribute(.foregroundColor, value: muted, range: offset(match.range(at: 1)))
        }
        for match in WritingTools.matches(#"\*\*[^*\n]+\*\*|(?<![\p{L}\p{N}_])__[^_\n]+__(?![\p{L}\p{N}_])"#, in: segment) {
            storage.addAttribute(.font, value: boldFont, range: offset(match.range))
        }
        for match in WritingTools.matches(#"(?<!\*)\*[^*\n]+\*(?!\*)|(?<![\p{L}\p{N}_])_[^_\n]+_(?![\p{L}\p{N}_])"#, in: segment) {
            storage.addAttribute(.font, value: italicFont, range: offset(match.range))
        }
        for match in WritingTools.matches(#"\*\*\*[^*\n]+\*\*\*|(?<![\p{L}\p{N}_])___[^_\n]+___(?![\p{L}\p{N}_])|\*\*_[^_\n]+_\*\*|_\*\*[^*\n]+\*\*_"#, in: segment) {
            storage.addAttribute(.font, value: boldItalicFont, range: offset(match.range))
        }
        for match in WritingTools.matches(#"(?m)^\s*(?:[-*+] |\d+\. |> )|!?(?:\[[^\]\n]*\])(?:\([^\)\n]*\))|`[^`\n]*`"#, in: segment) {
            storage.addAttribute(.foregroundColor, value: muted, range: offset(match.range))
        }
        for fenceRange in fencedRanges {
            storage.addAttribute(.font, value: WriterFonts.font("Mono", size: CGFloat(configuration.size * 0.94)), range: offset(fenceRange))
            storage.addAttribute(.foregroundColor, value: muted, range: offset(fenceRange))
        }

        if configuration.styleCheck {
            var issues = WritingTools.styleIssues(in: segment)
            for term in configuration.customPatterns.components(separatedBy: .newlines) where !term.isEmpty {
                issues += WritingTools.matches("(?i)" + NSRegularExpression.escapedPattern(for: term), in: segment).map(\.range)
            }
            for range in issues {
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: WriterNativeColor.systemOrange], range: offset(range))
            }
        }
        if configuration.focus == .sentence || configuration.focus == .paragraph {
            let active = WritingTools.focusRange(in: text, caret: selection.location, mode: configuration.focus)
            let targetEnd = NSMaxRange(target)
            // The caret can be far offscreen while the user scrolls. Both
            // fade boundaries must stay inside the requested styling window.
            let activeStart = min(targetEnd, max(active.location, target.location))
            let activeEnd = max(target.location, min(NSMaxRange(active), targetEnd))
            func fade(_ start: Int, _ end: Int) {
                guard start < end else { return }
                let selectedStart = selection.location
                let selectedEnd = NSMaxRange(selection)
                if selection.length == 0 || selectedEnd <= start || selectedStart >= end {
                    storage.addAttribute(.foregroundColor, value: faded, range: NSRange(location: start, length: end - start))
                } else {
                    if start < selectedStart {
                        storage.addAttribute(.foregroundColor, value: faded,
                                             range: NSRange(location: start, length: selectedStart - start))
                    }
                    if selectedEnd < end {
                        storage.addAttribute(.foregroundColor, value: faded,
                                             range: NSRange(location: selectedEnd, length: end - selectedEnd))
                    }
                }
            }
            fade(target.location, activeStart)
            fade(activeEnd, targetEnd)
        }
        storage.endEditing()
    }

    static func grammarHighlights(in text: String, around visibleRange: NSRange) -> [GrammarHighlight] {
        let source = text as NSString
        let start = max(0, min(source.length, visibleRange.location) - 800)
        let end = min(source.length, max(start, NSMaxRange(visibleRange)) + 800)
        let window = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let segment = source.substring(with: window)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = segment
        var highlights: [GrammarHighlight] = []
        tagger.enumerateTags(in: segment.startIndex..<segment.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let colorIndex: Int?
            switch tag {
            case .noun: colorIndex = 0
            case .verb: colorIndex = 1
            case .adjective: colorIndex = 2
            case .adverb: colorIndex = 3
            case .conjunction: colorIndex = 4
            default: colorIndex = nil
            }
            if let colorIndex {
                let local = NSRange(range, in: segment)
                highlights.append(GrammarHighlight(range: NSRange(location: window.location + local.location, length: local.length), colorIndex: colorIndex))
            }
            return true
        }
        return highlights
    }

    static func applyGrammar(_ highlights: [GrammarHighlight], to storage: NSTextStorage,
                             text: String, selection: NSRange, configuration: WriterConfiguration) {
        let active = WritingTools.focusRange(in: text, caret: selection.location, mode: configuration.focus)
        storage.beginEditing()
        for highlight in highlights where NSMaxRange(highlight.range) <= storage.length {
            if highlight.range.location >= active.location, NSMaxRange(highlight.range) <= NSMaxRange(active) {
                storage.addAttribute(.foregroundColor, value: grammarNativeColors[highlight.colorIndex], range: highlight.range)
            }
        }
        storage.endEditing()
    }

    /// Computes a minimal in-place edit patch so formatting preserves scroll and keeps Undo lightweight.
    static func patch(text: String, selection: NSRange, command: String, insertText: String? = nil, replaceRange: NSRange? = nil) -> WriterEditPatch {
        let string = text as NSString
        let safeLoc = min(max(0, selection.location), string.length)
        let safeLen = min(max(0, selection.length), string.length - safeLoc)
        let safe = NSRange(location: safeLoc, length: safeLen)
        if command == "replaceRange", let rawRange = replaceRange {
            let loc = min(max(0, rawRange.location), string.length)
            let len = min(max(0, rawRange.length), string.length - loc)
            let clamped = NSRange(location: loc, length: len)
            let snippet = insertText ?? ""
            return WriterEditPatch(range: clamped, replacement: snippet,
                                   newSelection: NSRange(location: clamped.location + (snippet as NSString).length, length: 0))
        }
        if command == "insert", let snippet = insertText {
            return WriterEditPatch(range: safe, replacement: snippet,
                                   newSelection: NSRange(location: safe.location + (snippet as NSString).length, length: 0))
        }
        let selected = string.substring(with: safe)
        let before: String
        let after: String
        switch command {
        case "bold": before = "**"; after = "**"
        case "italic": before = "*"; after = "*"
        case "link": before = "["; after = "](https://)"
        case "wikilink": before = "[["; after = "]]"
        case "code": before = "`"; after = "`"
        default:
            let prefix: String
            switch command {
            case "heading": prefix = "## "
            case "quote": prefix = "> "
            case "task": prefix = "- [ ] "
            default: prefix = "- "
            }
            let lines = string.lineRange(for: safe)
            let value = string.substring(with: lines)
            let trailingNewline = value.hasSuffix("\n")
            let content = trailingNewline ? String(value.dropLast()) : value
            let replacement = content.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
            return WriterEditPatch(range: lines, replacement: replacement,
                                   newSelection: NSRange(location: safe.location + (prefix as NSString).length, length: safe.length))
        }
        return WriterEditPatch(range: safe, replacement: before + selected + after,
                               newSelection: NSRange(location: safe.location + (before as NSString).length, length: safe.length))
    }

    static func edit(text: String, selection: NSRange, command: String) -> (range: NSRange, replacement: String, selection: NSRange) {
        let result = patch(text: text, selection: selection, command: command)
        return (result.range, result.replacement, result.newSelection)
    }

    static func replacement(text: String, selection: NSRange, command: String) -> (String, NSRange) {
        let p = patch(text: text, selection: selection, command: command)
        return ((text as NSString).replacingCharacters(in: p.range, with: p.replacement), p.newSelection)
    }
}

#if os(macOS)
final class WriterTextView: NSTextView {
    var configuration = WriterConfiguration()
    var onAppearanceChange: (() -> Void)?
    var onAttachData: ((Data, String) -> Void)?
    var onAttachFiles: (([URL]) -> Void)?

    override func layout() {
        super.layout()
        let available = enclosingScrollView?.contentSize.width ?? bounds.width
        let horizontal = max(28, (available - configuration.contentWidth) / 2)
        let vertical: CGFloat = configuration.focus == .typewriter ? max(70, (enclosingScrollView?.contentSize.height ?? 400) / 2) : 66
        let inset = NSSize(width: horizontal, height: vertical)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = WriterStyling.canvasBackground
        enclosingScrollView?.backgroundColor = WriterStyling.canvasBackground
        insertionPointColor = WriterStyling.insertionColor
        selectedTextAttributes = [
            .foregroundColor: WriterStyling.ink,
            .backgroundColor: WriterStyling.selectionBackground
        ]
        onAppearanceChange?()
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // If the clipboard contains an image (e.g. screenshot) and no plain text, attach it directly offline.
        let hasString = pb.string(forType: .string)?.isEmpty == false
        if !hasString, let onAttachData {
            if let png = pb.data(forType: .png) {
                onAttachData(png, Self.screenshotFilename())
                return
            }
            if let tiff = pb.data(forType: .tiff),
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                onAttachData(png, Self.screenshotFilename())
                return
            }
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onAttachFiles != nil,
           sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onAttachFiles,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onAttachFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private static func screenshotFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Capture-\(formatter.string(from: .now)).png"
    }
}

struct WritingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var configuration: WriterConfiguration
    @Binding var request: WriterEditRequest?
    var onAttachData: ((Data, String) -> Void)? = nil
    var onAttachFiles: (([URL]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = WriterStyling.canvasBackground
        let view = WriterTextView(frame: .zero)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.allowsUndo = true
        view.isEditable = true
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.backgroundColor = WriterStyling.canvasBackground
        view.insertionPointColor = WriterStyling.insertionColor
        view.font = WriterFonts.font(configuration.family, size: CGFloat(configuration.size))
        view.textColor = WriterStyling.ink
        view.typingAttributes = WriterStyling.attributes(configuration)
        view.selectedTextAttributes = [
            .foregroundColor: WriterStyling.ink,
            .backgroundColor: WriterStyling.selectionBackground
        ]
        view.delegate = context.coordinator
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityLabel("Document Markdown")
        view.onAppearanceChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.scheduleStyle(view, force: true)
        }
        view.onAttachData = onAttachData
        view.onAttachFiles = onAttachFiles
        scroll.documentView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.viewportDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? WriterTextView else { return }
        let coordinator = context.coordinator
        let focusChanged = coordinator.parent.configuration.focus != configuration.focus
        coordinator.parent = self
        view.onAttachData = onAttachData
        view.onAttachFiles = onAttachFiles
        coordinator.updating = true
        defer { coordinator.updating = false }
        if !coordinator.pendingNativeEdit && view.string != text {
            view.string = text
            let len = (text as NSString).length
            let loc = min(selection.location, len)
            view.setSelectedRange(NSRange(location: loc, length: min(selection.length, max(0, len - loc))))
            coordinator.needsStyle = true
        }
        if view.configuration != configuration {
            view.configuration = configuration
            view.needsLayout = true
        }
        if let request, coordinator.appliedRequest != request.id {
            coordinator.appliedRequest = request.id
            if request.command == "jump", let loc = request.jumpLocation {
                let len = (view.string as NSString).length
                let safe = NSRange(location: min(max(0, loc), len), length: 0)
                view.setSelectedRange(safe)
                view.scrollRangeToVisible(safe)
                view.window?.makeFirstResponder(view)
                DispatchQueue.main.async { [weak coordinator] in
                    guard let coordinator else { return }
                    coordinator.parent.selection = safe
                    if coordinator.parent.request?.id == request.id { coordinator.parent.request = nil }
                }
            } else {
                let patch = WriterStyling.patch(text: view.string, selection: view.selectedRange(),
                                                command: request.command, insertText: request.insertText,
                                                replaceRange: request.replaceRange)
                if let storage = view.textStorage,
                   view.shouldChangeText(in: patch.range, replacementString: patch.replacement) {
                    coordinator.pendingNativeEdit = true
                    storage.replaceCharacters(in: patch.range, with: patch.replacement)
                    view.didChangeText()
                    view.setSelectedRange(patch.newSelection)
                    view.window?.makeFirstResponder(view)
                    DispatchQueue.main.async { [weak view, weak coordinator] in
                        guard let view, let coordinator else { return }
                        coordinator.parent.text = view.string
                        coordinator.parent.selection = view.selectedRange()
                        coordinator.pendingNativeEdit = false
                        if coordinator.parent.request?.id == request.id { coordinator.parent.request = nil }
                    }
                }
            }
        }
        coordinator.scheduleStyle(view)
        if focusChanged, configuration.focus == .typewriter {
            DispatchQueue.main.async { view.layoutSubtreeIfNeeded(); coordinator.centerCaret(view) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingTextView
        var updating = false
        var appliedRequest: UUID?
        var pendingNativeEdit = false
        private var lastText = ""
        private var lastConfiguration: WriterConfiguration?
        private var lastFocus = NSRange(location: NSNotFound, length: 0)
        private var lastSelection = NSRange(location: NSNotFound, length: 0)
        private var lastStyledRange = NSRange(location: 0, length: 0)
        private var grammarTask: Task<Void, Never>?
        private var grammarGeneration = 0
        private var lastGrammarText: String?
        private var lastGrammarHighlights: [WriterStyling.GrammarHighlight] = []
        private var styleTask: Task<Void, Never>?
        private var styleGeneration = 0
        var needsStyle = false
        init(_ parent: WritingTextView) { self.parent = parent }
        deinit { grammarTask?.cancel(); styleTask?.cancel(); NotificationCenter.default.removeObserver(self) }
        @objc func viewportDidChange(_ notification: Notification) {
            guard !updating, let view = (notification.object as? NSClipView)?.documentView as? WriterTextView else { return }
            let visible = visibleCharacterRange(in: view)
            if visible.location < lastStyledRange.location || NSMaxRange(visible) > NSMaxRange(lastStyledRange) {
                scheduleStyle(view, force: true)
            } else if parent.configuration.syntax {
                scheduleGrammar(view)
            }
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? WriterTextView else { return }
            parent.text = view.string
            let range = view.selectedRange()
            if parent.selection != range { parent.selection = range }
            scheduleStyle(view)
            centerCaret(view)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? WriterTextView else { return }
            let range = view.selectedRange()
            if parent.selection != range { parent.selection = range }
            scheduleStyle(view)
            centerCaret(view)
        }
        func scheduleStyle(_ view: WriterTextView, force: Bool = false) {
            if force { needsStyle = true }
            styleTask?.cancel()
            styleGeneration &+= 1
            let generation = styleGeneration
            styleTask = Task { @MainActor [weak view] in
                defer { if generation == styleGeneration { styleTask = nil } }
                do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
                guard generation == styleGeneration, let view else { return }
                style(view)
            }
        }
        private func style(_ view: WriterTextView) {
            guard !view.hasMarkedText(), view.textStorage != nil else { return }
            let selected = view.selectedRange()
            let focus = WritingTools.focusRange(in: view.string, caret: selected.location, mode: parent.configuration.focus)
            let configurationChanged = parent.configuration != lastConfiguration
            guard configurationChanged || needsStyle || view.string != lastText || focus != lastFocus || selected != lastSelection else { return }
            needsStyle = false
            lastText = view.string; lastConfiguration = parent.configuration; lastFocus = focus; lastSelection = selected
            applyStyle(view)
            scheduleGrammar(view)
        }
        private func applyStyle(_ view: WriterTextView) {
            guard let storage = view.textStorage else { return }
            let range = styledRange(in: view)
            lastStyledRange = range
            // Styling must never move the scroll position; only typing does.
            let saved = view.enclosingScrollView?.contentView.bounds.origin
            let wasUpdating = updating; updating = true
            WriterStyling.apply(to: storage, text: view.string,
                                range: range,
                                selection: view.selectedRange(), configuration: parent.configuration)
            if parent.configuration.syntax, lastGrammarText == view.string, !lastGrammarHighlights.isEmpty {
                WriterStyling.applyGrammar(lastGrammarHighlights, to: storage, text: view.string,
                                           selection: view.selectedRange(), configuration: parent.configuration)
            }
            view.typingAttributes = WriterStyling.attributes(parent.configuration)
            updating = wasUpdating
            if let scroll = view.enclosingScrollView, let saved, scroll.contentView.bounds.origin != saved {
                scroll.contentView.scroll(to: saved)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        /// Restyle the visible page and a margin; scrolling styles the next page.
        private func styledRange(in view: WriterTextView) -> NSRange {
            let visible = visibleCharacterRange(in: view)
            let margin = 1500
            return NSRange(location: max(0, visible.location - margin), length: visible.length + margin * 2)
        }
        private func scheduleGrammar(_ view: WriterTextView) {
            grammarTask?.cancel()
            grammarGeneration += 1
            guard parent.configuration.syntax else {
                lastGrammarText = nil
                lastGrammarHighlights = []
                return
            }
            let generation = grammarGeneration
            let text = view.string
            let visibleRange = visibleCharacterRange(in: view)
            grammarTask = Task { @MainActor [weak view] in
                defer { if generation == grammarGeneration { grammarTask = nil } }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                let highlights = await Task.detached(priority: .utility) {
                    WriterStyling.grammarHighlights(in: text, around: visibleRange)
                }.value
                guard !Task.isCancelled, generation == grammarGeneration,
                      let view, !view.hasMarkedText(), view.string == text, let storage = view.textStorage else { return }
                lastGrammarText = text
                lastGrammarHighlights = highlights
                let saved = view.enclosingScrollView?.contentView.bounds.origin
                let wasUpdating = updating; updating = true
                WriterStyling.applyGrammar(highlights, to: storage, text: text,
                                           selection: view.selectedRange(), configuration: parent.configuration)
                updating = wasUpdating
                if let scroll = view.enclosingScrollView, let saved, scroll.contentView.bounds.origin != saved {
                    scroll.contentView.scroll(to: saved)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        private func visibleCharacterRange(in view: WriterTextView) -> NSRange {
            guard let layout = view.layoutManager, let container = view.textContainer else {
                return NSRange(location: 0, length: (view.string as NSString).length)
            }
            let origin = view.textContainerOrigin
            let rect = view.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
            return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        fileprivate func centerCaret(_ view: WriterTextView) {
            guard parent.configuration.focus == .typewriter, let scroll = view.enclosingScrollView,
                  let layout = view.layoutManager, let container = view.textContainer else { return }
            let location = min(view.selectedRange().location, max(0, (view.string as NSString).length - 1))
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: location, length: view.string.isEmpty ? 0 : 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
            let y = rect.midY + view.textContainerInset.height - scroll.contentSize.height / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
#else
private final class WriterIOSView: UITextView {
    var configuration = WriterConfiguration() {
        didSet { updateInsets() }
    }
    var onAppearanceChange: (() -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: WriterIOSView, _) in
            self.backgroundColor = WriterStyling.canvasBackground
            self.tintColor = WriterStyling.insertionColor
            self.onAppearanceChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateInsets()
    }

    func updateInsets() {
        guard bounds.width > 0 else { return }
        let horizontal = max(22, (bounds.width - configuration.contentWidth) / 2)
        let vertical: CGFloat = configuration.focus == .typewriter ? max(44, bounds.height / 2) : 32
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if textContainerInset != inset { textContainerInset = inset }
    }
}

struct WritingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var configuration: WriterConfiguration
    @Binding var request: WriterEditRequest?
    var onAttachData: ((Data, String) -> Void)? = nil
    var onAttachFiles: (([URL]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = WriterIOSView()
        view.backgroundColor = WriterStyling.canvasBackground
        view.tintColor = WriterStyling.insertionColor
        view.font = WriterFonts.font(configuration.family, size: CGFloat(configuration.size))
        view.textColor = WriterStyling.ink
        view.typingAttributes = WriterStyling.attributes(configuration)
        view.textContainer.lineFragmentPadding = 0
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocorrectionType = .yes
        view.spellCheckingType = .yes
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        view.accessibilityLabel = "Document Markdown"
        view.inputAccessoryView = context.coordinator.makeKeyboardToolbar(for: view)
        view.onAppearanceChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.scheduleStyle(view, force: true)
        }
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        guard let view = uiView as? WriterIOSView else { return }
        let coordinator = context.coordinator
        let focusChanged = coordinator.parent.configuration.focus != configuration.focus
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        if !coordinator.pendingNativeEdit && view.text != text {
            view.text = text
            let len = (text as NSString).length
            let loc = min(selection.location, len)
            view.selectedRange = NSRange(location: loc, length: min(selection.length, max(0, len - loc)))
            coordinator.needsStyle = true
        }
        if view.configuration != configuration {
            view.configuration = configuration
        }
        if let request, coordinator.appliedRequest != request.id {
            coordinator.appliedRequest = request.id
            if request.command == "jump", let loc = request.jumpLocation {
                let len = ((view.text ?? "") as NSString).length
                let safe = NSRange(location: min(max(0, loc), len), length: 0)
                view.selectedRange = safe
                view.scrollRangeToVisible(safe)
                DispatchQueue.main.async { [weak coordinator] in
                    guard let coordinator else { return }
                    coordinator.parent.selection = safe
                    if coordinator.parent.request?.id == request.id { coordinator.parent.request = nil }
                }
            } else {
                coordinator.applyPatch(command: request.command, insertText: request.insertText,
                                       replaceRange: request.replaceRange, requestID: request.id, to: view)
            }
        }
        coordinator.scheduleStyle(view)
        if focusChanged, configuration.focus == .typewriter {
            DispatchQueue.main.async { view.layoutIfNeeded(); coordinator.centerCaret(view) }
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WritingTextView
        var updating = false
        var appliedRequest: UUID?
        var pendingNativeEdit = false
        private weak var textView: UITextView?
        private var lastText = ""
        private var lastConfiguration: WriterConfiguration?
        private var lastFocus = NSRange(location: NSNotFound, length: 0)
        private var lastSelection = NSRange(location: NSNotFound, length: 0)
        private var lastStyledRange = NSRange(location: 0, length: 0)
        private var grammarTask: Task<Void, Never>?
        private var grammarGeneration = 0
        private var lastGrammarText: String?
        private var lastGrammarHighlights: [WriterStyling.GrammarHighlight] = []
        private var styleTask: Task<Void, Never>?
        private var styleGeneration = 0
        var needsStyle = false
        init(_ parent: WritingTextView) { self.parent = parent }
        deinit { grammarTask?.cancel(); styleTask?.cancel() }

        func makeKeyboardToolbar(for view: UITextView) -> UIToolbar {
            self.textView = view
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.autoresizingMask = [.flexibleWidth]
            func item(_ image: String, label: String, command: String) -> UIBarButtonItem {
                let action = UIAction { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    self.applyPatch(command: command, insertText: nil, replaceRange: nil, requestID: nil, to: tv)
                }
                let btn = UIBarButtonItem(image: UIImage(systemName: image), primaryAction: action)
                btn.accessibilityLabel = label
                return btn
            }
            let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
            let dismiss = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak view] _ in
                view?.resignFirstResponder()
            })
            dismiss.accessibilityLabel = "Fermer le clavier"
            bar.items = [
                item("number", label: "Titre", command: "heading"),
                item("bold", label: "Gras", command: "bold"),
                item("italic", label: "Italique", command: "italic"),
                item("list.bullet", label: "Liste", command: "list"),
                item("checklist", label: "Tâche", command: "task"),
                item("text.quote", label: "Citation", command: "quote"),
                item("chevron.left.forwardslash.chevron.right", label: "Code", command: "code"),
                item("link", label: "Lien", command: "link"),
                flex(),
                dismiss
            ]
            return bar
        }

        func applyPatch(command: String, insertText: String?, replaceRange: NSRange? = nil, requestID: UUID? = nil, to view: UITextView) {
            let patch = WriterStyling.patch(text: view.text ?? "", selection: view.selectedRange,
                                            command: command, insertText: insertText, replaceRange: replaceRange)
            if let start = view.position(from: view.beginningOfDocument, offset: patch.range.location),
               let end = view.position(from: start, offset: patch.range.length),
               let range = view.textRange(from: start, to: end) {
                pendingNativeEdit = true
                view.replace(range, withText: patch.replacement)
                view.selectedRange = patch.newSelection
                _ = view.becomeFirstResponder()
                DispatchQueue.main.async { [weak view, weak self] in
                    guard let view, let self else { return }
                    self.parent.text = view.text
                    self.parent.selection = view.selectedRange
                    self.pendingNativeEdit = false
                    if let requestID, self.parent.request?.id == requestID { self.parent.request = nil }
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !updating, let view = scrollView as? UITextView else { return }
            let visible = visibleCharacterRange(in: view)
            if visible.location < lastStyledRange.location || NSMaxRange(visible) > NSMaxRange(lastStyledRange) {
                scheduleStyle(view, force: true)
            } else if parent.configuration.syntax {
                scheduleGrammar(view)
            }
        }
        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            parent.text = view.text
            let range = view.selectedRange
            if parent.selection != range { parent.selection = range }
            scheduleStyle(view)
            centerCaret(view)
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            let range = view.selectedRange
            if parent.selection != range { parent.selection = range }
            scheduleStyle(view)
            centerCaret(view)
        }
        fileprivate func scheduleStyle(_ view: UITextView, force: Bool = false) {
            if force { needsStyle = true }
            styleTask?.cancel()
            styleGeneration &+= 1
            let generation = styleGeneration
            styleTask = Task { @MainActor [weak view] in
                defer { if generation == styleGeneration { styleTask = nil } }
                do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
                guard generation == styleGeneration, let view else { return }
                style(view)
            }
        }
        private func style(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            let selected = view.selectedRange
            let focus = WritingTools.focusRange(in: view.text, caret: selected.location, mode: parent.configuration.focus)
            let configurationChanged = parent.configuration != lastConfiguration
            guard configurationChanged || needsStyle || view.text != lastText || focus != lastFocus || selected != lastSelection else { return }
            needsStyle = false
            lastText = view.text; lastConfiguration = parent.configuration; lastFocus = focus; lastSelection = selected
            applyStyle(view)
            scheduleGrammar(view)
        }
        private func applyStyle(_ view: UITextView) {
            // Styling must never move the scroll position; only typing does.
            let saved = view.contentOffset
            let oldSelection = view.selectedRange
            let range = styledRange(in: view)
            lastStyledRange = range
            let wasUpdating = updating; updating = true
            WriterStyling.apply(to: view.textStorage, text: view.text, range: range,
                                selection: oldSelection, configuration: parent.configuration)
            if parent.configuration.syntax, lastGrammarText == view.text, !lastGrammarHighlights.isEmpty {
                WriterStyling.applyGrammar(lastGrammarHighlights, to: view.textStorage, text: view.text,
                                           selection: oldSelection, configuration: parent.configuration)
            }
            view.selectedRange = oldSelection
            view.typingAttributes = WriterStyling.attributes(parent.configuration)
            updating = wasUpdating
            if view.contentOffset != saved { view.setContentOffset(saved, animated: false) }
        }
        /// Restyle the visible page and a margin; scrolling styles the next page.
        private func styledRange(in view: UITextView) -> NSRange {
            let visible = visibleCharacterRange(in: view)
            let margin = 1500
            return NSRange(location: max(0, visible.location - margin), length: visible.length + margin * 2)
        }
        private func scheduleGrammar(_ view: UITextView) {
            grammarTask?.cancel()
            grammarGeneration += 1
            guard parent.configuration.syntax else {
                lastGrammarText = nil
                lastGrammarHighlights = []
                return
            }
            let generation = grammarGeneration
            let text = view.text ?? ""
            let visibleRange = visibleCharacterRange(in: view)
            grammarTask = Task { @MainActor [weak view] in
                defer { if generation == grammarGeneration { grammarTask = nil } }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                let highlights = await Task.detached(priority: .utility) {
                    WriterStyling.grammarHighlights(in: text, around: visibleRange)
                }.value
                guard !Task.isCancelled, generation == grammarGeneration,
                      let view, view.markedTextRange == nil, view.text == text else { return }
                lastGrammarText = text
                lastGrammarHighlights = highlights
                let saved = view.contentOffset
                let wasUpdating = updating; updating = true
                WriterStyling.applyGrammar(highlights, to: view.textStorage, text: text,
                                           selection: view.selectedRange, configuration: parent.configuration)
                updating = wasUpdating
                if view.contentOffset != saved { view.setContentOffset(saved, animated: false) }
            }
        }
        private func visibleCharacterRange(in view: UITextView) -> NSRange {
            let rect = CGRect(origin: view.contentOffset, size: view.bounds.size)
                .offsetBy(dx: -view.textContainerInset.left, dy: -view.textContainerInset.top)
            let glyphs = view.layoutManager.glyphRange(forBoundingRect: rect, in: view.textContainer)
            return view.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        fileprivate func centerCaret(_ view: UITextView) {
            guard parent.configuration.focus == .typewriter, let range = view.selectedTextRange else { return }
            let caret = view.caretRect(for: range.start)
            view.setContentOffset(CGPoint(x: 0, y: max(-view.adjustedContentInset.top, caret.midY - view.bounds.height / 2)), animated: false)
        }
    }
}
#endif
