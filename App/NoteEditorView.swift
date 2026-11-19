import SwiftUI
import QuickLook
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NoteEditorView: View {
    enum ViewMode { case editor, split, preview }
    private enum InspectorTab: String, CaseIterable, Identifiable {
        case outline, backlinks, history
        var id: String { rawValue }
        var label: String {
            switch self {
            case .outline: return "Plan"
            case .backlinks: return "Rétroliens"
            case .history: return "Historique"
            }
        }
    }

    @EnvironmentObject private var store: WaveStore
    @Environment(\.scenePhase) private var scenePhase
    let noteID: UUID
    var isLibraryHidden: Bool = false
    var onDelete: () -> Void
    var onOpenNote: (UUID) -> Void
    var onToggleLibrary: () -> Void
    @State private var draftText = ""
    @State private var original: WaveNote?
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editRequest: WriterEditRequest?
    @State private var viewMode: ViewMode = .editor
    @State private var showingTypography = false
    @State private var showingInspector = false
    @State private var inspectorTab: InspectorTab = .outline
    @State private var snapshotRefreshToken = 0
    @State private var showingStatistics = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var showingDelete = false
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    @State private var dirty = false
    @State private var saveFailed = false
    @State private var previewURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var inFlightSave: Task<WaveNote?, Never>?
    @State private var inFlightSnapshotText: String?
    @State private var draftTask: Task<Void, Never>?
    @State private var statisticsTask: Task<Void, Never>?
    @State private var statistics = WritingStatistics("")
    @State private var statisticsRevision = 0
    @State private var exportDocument = WaveExportDocument(data: Data())
    @State private var exportType = UTType.plainText
    @StateObject private var previewController = WriterPreviewController()
    @AppStorage("wave.appearance") private var appearance = WaveAppearance.system.rawValue
    @AppStorage("wave.writer.font") private var fontFamily = "Mono"
    #if os(macOS)
    @AppStorage("wave.writer.size.mac") private var fontSize = 20.0
    #else
    @AppStorage("wave.writer.size.ios") private var fontSize = 17.0
    #endif
    @AppStorage("wave.writer.columns") private var columns = 64.0
    @AppStorage("wave.writer.focus") private var focusMode = WriterFocus.off.rawValue
    @AppStorage("wave.writer.syntax") private var syntax = false
    @AppStorage("wave.writer.style") private var styleCheck = false
    @AppStorage("wave.writer.customPatterns") private var customPatterns = ""

    private static let wordType = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    private var note: WaveNote? { store.note(id: noteID) }
    private var parts: (title: String, body: String) { WritingTools.document(draftText, fallbackTitle: original?.title ?? "Sans titre") }
    private var focus: WriterFocus { WriterFocus(rawValue: focusMode) ?? .off }
    private var cssColorScheme: String { (WaveAppearance(rawValue: appearance) ?? .system).cssColorScheme }
    private var configuration: WriterConfiguration {
        WriterConfiguration(family: fontFamily, size: fontSize, columns: columns, focus: focus,
                            syntax: syntax, styleCheck: styleCheck, customPatterns: customPatterns)
    }
    private var draftKey: String { "wave.noteDraft.\(noteID.uuidString)." + store.vault.rootURL.path }
    // Optional legacy fields recover drafts from the previous editor without losing text.
    private struct NoteDraft: Codable { var original: WaveNote; var text: String?; var title: String?; var body: String? }

    /// Detects an active unclosed `[[query` right before the caret for instant offline wiki-link autocomplete.
    private var activeWikiCompletion: (range: NSRange, query: String, suggestions: [WaveNote])? {
        guard viewMode != .preview, selection.length == 0 else { return nil }
        let ns = draftText as NSString
        guard selection.location >= 2, selection.location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefixLen = selection.location - lineRange.location
        guard prefixLen >= 2 else { return nil }
        let prefix = ns.substring(with: NSRange(location: lineRange.location, length: prefixLen))
        guard let openRange = prefix.range(of: "[[", options: .backwards) else { return nil }
        let afterOpen = String(prefix[openRange.upperBound...])
        guard !afterOpen.contains("]"), !afterOpen.contains("\n") else { return nil }
        let openUTF16 = (String(prefix[..<openRange.lowerBound]) as NSString).length
        let replaceRange = NSRange(location: lineRange.location + openUTF16,
                                   length: selection.location - (lineRange.location + openUTF16))
        let trimmed = afterOpen.trimmingCharacters(in: .whitespaces)
        let matches = store.notes.filter { candidate in
            guard candidate.id != noteID else { return false }
            guard !trimmed.isEmpty else { return true }
            return candidate.title.localizedCaseInsensitiveContains(trimmed)
        }.prefix(6)
        guard !matches.isEmpty else { return nil }
        return (replaceRange, trimmed, Array(matches))
    }

    var body: some View {
        VStack(spacing: 0) {
            if #unavailable(macOS 26, iOS 26) {
                editorToolbar
                Divider()
            }
            editorBody
            if let completion = activeWikiCompletion {
                Divider()
                wikiCompletionBar(completion)
            }
            if !(note?.attachments.isEmpty ?? true) {
                Divider()
                attachmentSection
            }
            Divider()
            statusBar
        }
        .background(WaveTheme.background)
        .toolbar { modernToolbar }
        .focusedSceneValue(\.waveEditorActions, WaveEditorActions(
            save: { _ = saveDraft() },
            format: format,
            toggleFocus: toggleFocus,
            togglePreview: togglePreview,
            toggleSplitPreview: toggleSplitPreview,
            toggleInspector: { showingInspector.toggle() },
            requestDelete: { showingDelete = true }
        ))
        .waveOnChange(of: draftText) { _ in scheduleSave(); scheduleStatistics() }
        .navigationTitle(parts.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: loadDraft)
        .onDisappear {
            saveTask?.cancel()
            statisticsTask?.cancel()
            copiedTask?.cancel()
            _ = saveDraft()
        }
        .waveOnChange(of: scenePhase) { phase in if phase != .active { _ = saveDraft() } }
        .onReceive(NotificationCenter.default.publisher(for: .waveFlushDrafts)) { _ in _ = saveDraft() }
        .waveOnChange(of: note) { _ in syncFreshNote() }
        .onReceive(previewController.$pdf) { data in
            if let data { exportDocument = WaveExportDocument(data: data); exportType = .pdf; showingExporter = true }
        }
        .onReceive(previewController.$error) { error in if let error { store.errorMessage = error } }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: handleImport)
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: exportType, defaultFilename: exportFilename) { result in
            if case let .failure(error) = result { store.report(error) }
        }
        .quickLookPreview($previewURL)
        .alert("Placer ce document dans la Corbeille ?", isPresented: $showingDelete) {
            Button("Annuler", role: .cancel) { }
            Button("Placer dans la Corbeille", role: .destructive) {
                if saveDraft(), let note, store.moveToTrash(note) {
                    dirty = false
                    UserDefaults.standard.removeObject(forKey: draftKey)
                    onDelete()
                }
            }
        } message: { Text("Le document et ses pièces jointes resteront dans la Corbeille pendant 30 jours, puis seront supprimés définitivement.") }
    }

    /// Keeps WritingTextView mounted across .editor <-> .split so undo, caret and scroll are never lost.
    private var editorBody: some View {
        HStack(spacing: 0) {
            if viewMode != .preview {
                WritingTextView(
                    text: $draftText,
                    selection: $selection,
                    configuration: configuration,
                    request: $editRequest,
                    onAttachData: handlePastedAttachment,
                    onAttachFiles: handleDroppedAttachments
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(iOS)
                .dropDestination(for: URL.self) { items, _ in
                    guard !items.isEmpty else { return false }
                    handleDroppedAttachments(items)
                    return true
                }
                #endif
            }
            #if os(macOS)
            if viewMode == .split {
                Divider()
            }
            #endif
            if viewMode != .editor {
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.22), value: viewMode)
    }

    private func wikiCompletionBar(_ completion: (range: NSRange, query: String, suggestions: [WaveNote])) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(WaveTheme.accent)
                ForEach(completion.suggestions) { candidate in
                    Button {
                        editRequest = WriterEditRequest(
                            command: "replaceRange",
                            insertText: "[[\(candidate.title)]]",
                            replaceRange: completion.range
                        )
                    } label: {
                        Text(candidate.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WaveTheme.text)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(WaveTheme.elevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .background(WaveTheme.surface)
    }

    private var previewPane: some View {
        WriterPreview(
            markdown: draftText,
            baseURL: store.vault.rootURL.appendingPathComponent("Attachments/\(noteID.uuidString)", isDirectory: true),
            attachments: note?.attachments ?? [],
            fontFamily: fontFamily,
            colorScheme: cssColorScheme,
            onOpenNote: openWikiLink,
            controller: previewController
        )
    }

    private var editorToolbar: some View {
        HStack(spacing: 16) {
            #if os(macOS)
            Text(parts.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            focusExpandButton
            #endif
            inspectorButton
            focusMenu
            typographyButton
            formatMenu
            #if os(iOS)
            Spacer(minLength: 0)
            #endif
            previewControls
            shareMenu
            noteActionsMenu
        }.buttonStyle(.plain).menuStyle(.borderlessButton).tint(WaveTheme.secondary)
            .font(.system(size: 14)).foregroundStyle(WaveTheme.secondary)
            .padding(.horizontal, 20).frame(height: 44)
    }

    @ToolbarContentBuilder private var modernToolbar: some ToolbarContent {
        if #available(macOS 26, iOS 26, *) {
            #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                focusExpandButton
                inspectorButton
                focusMenu
                typographyButton
                formatMenu
                previewControls
                shareMenu
                noteActionsMenu
            }
            #else
            ToolbarItemGroup(placement: .topBarTrailing) {
                inspectorButton
                previewButton
                typographyButton
                Menu {
                    Menu("Concentration", systemImage: "circle.dashed") { focusCommands }
                    Menu("Format Markdown", systemImage: "textformat") { formatCommands }
                    Menu("Partager et exporter", systemImage: "square.and.arrow.up") { shareCommands }
                    Divider()
                    noteCommands
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Autres actions")
            }
            #endif
        }
    }

    #if os(macOS)
    private var focusExpandButton: some View {
        Button(action: onToggleLibrary) {
            Image(systemName: isLibraryHidden ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .help(isLibraryHidden ? "Afficher la bibliothèque (⇧⌘L)" : "Mode pleine page (⇧⌘L)")
        .accessibilityLabel(isLibraryHidden ? "Afficher la bibliothèque" : "Mode pleine page")
    }
    #endif

    private var inspectorButton: some View {
        Button { showingInspector.toggle() } label: {
            Image(systemName: "list.bullet.indent")
        }
        .help("Plan, rétroliens & historique (⌥⌘I)")
        .accessibilityLabel("Plan, rétroliens et historique")
        .popover(isPresented: $showingInspector) {
            if showingInspector { inspectorPanel }
        }
    }

    private var inspectorPanel: some View {
        let _ = snapshotRefreshToken
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Inspecteur", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            ScrollView {
                switch inspectorTab {
                case .outline:
                    outlineContent
                case .backlinks:
                    backlinksContent
                case .history:
                    historyContent
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder private var outlineContent: some View {
        let headings = WritingTools.headings(in: draftText)
        if headings.isEmpty {
            Text("Aucun titre dans ce document.\nUtilisez « # » ou « ## » pour structurer votre plan.")
                .font(.caption)
                .foregroundStyle(WaveTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(headings) { heading in
                    Button {
                        if viewMode == .preview { viewMode = .editor }
                        editRequest = WriterEditRequest(command: "jump", jumpLocation: heading.utf16Location)
                        showingInspector = false
                    } label: {
                        HStack(spacing: 6) {
                            Text("H\(heading.level)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(WaveTheme.secondary)
                                .frame(width: 22, alignment: .leading)
                            Text(heading.title)
                                .font(heading.level == 1 ? .subheadline.weight(.semibold) : .subheadline)
                                .foregroundStyle(WaveTheme.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var backlinksContent: some View {
        let links = note.map { store.backlinks(for: $0) } ?? []
        if links.isEmpty {
            Text("Aucune autre note ne mentionne « [[\(parts.title)]] » pour le moment.")
                .font(.caption)
                .foregroundStyle(WaveTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(links) { linked in
                    Button {
                        showingInspector = false
                        if saveDraft() { onOpenNote(linked.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(WaveTheme.accent)
                                Text(linked.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(WaveTheme.text)
                                    .lineLimit(1)
                                Spacer()
                            }
                            if !linked.snippet.isEmpty {
                                Text(linked.snippet)
                                    .font(.caption2)
                                    .foregroundStyle(WaveTheme.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(8)
                        .background(WaveTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var historyContent: some View {
        let versions = store.snapshots(for: noteID)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Instantanés locaux (hors ligne)")
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
                Spacer()
                Button("Capturer") {
                    if let current = note {
                        var live = current
                        live.title = parts.title
                        live.content = parts.body
                        store.recordSnapshot(for: live, force: true)
                        snapshotRefreshToken += 1
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if versions.isEmpty {
                Text("Un instantané local est automatiquement enregistré toutes les 5 minutes de modification, sans réseau.")
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(versions) { snapshot in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(WaveTheme.text)
                            Spacer()
                            Button("Restaurer") {
                                restoreSnapshot(snapshot)
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WaveTheme.accent)
                        }
                        Text(snapshot.preview)
                            .font(.caption2)
                            .foregroundStyle(WaveTheme.secondary)
                            .lineLimit(2)
                    }
                    .padding(9)
                    .background(WaveTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func restoreSnapshot(_ snapshot: NoteSnapshot) {
        if let current = note {
            var live = current
            live.title = parts.title
            live.content = parts.body
            store.recordSnapshot(for: live, force: true)
        }
        draftText = snapshot.markdown
        snapshotRefreshToken += 1
        showingInspector = false
    }

    private var focusMenu: some View {
        Menu { focusCommands } label: { Image(systemName: focus == .off ? "circle.dashed" : "circle.inset.filled") }
            .help("Mode concentration (⌘D)").accessibilityLabel("Mode concentration")
    }
    @ViewBuilder private var focusCommands: some View {
        Picker("Concentration", selection: $focusMode) {
            ForEach(WriterFocus.allCases, id: \.rawValue) { mode in Text(mode.label).tag(mode.rawValue) }
        }
        Divider()
        Button(focus == .off ? "Activer la concentration" : "Désactiver la concentration", action: toggleFocus)
    }
    private var typographyButton: some View {
        Button { showingTypography.toggle() } label: { Image(systemName: "textformat.size") }
            .accessibilityLabel("Typographie et révision").help("Typographie et révision")
            .popover(isPresented: $showingTypography) { typographyPanel }
    }
    private var formatMenu: some View {
        Menu { formatCommands } label: { Image(systemName: "textformat") }
            .help("Format Markdown").accessibilityLabel("Format Markdown")
    }
    @ViewBuilder private var formatCommands: some View {
        Button("Gras") { format("bold") }
        Button("Italique") { format("italic") }
        Button("Lien") { format("link") }
        Button("Lien interne [[…]]") { format("wikilink") }
        Divider()
        Button("Titre") { format("heading") }
        Button("Liste") { format("list") }
        Button("Tâche") { format("task") }
        Button("Citation") { format("quote") }
        Button("Code") { format("code") }
    }

    @ViewBuilder private var previewControls: some View {
        #if os(macOS)
        Button(action: toggleSplitPreview) {
            Image(systemName: viewMode == .split ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
        }
        .help("Aperçu côte à côte (⌥⌘R)")
        .accessibilityLabel("Aperçu côte à côte")
        previewButton
        #else
        previewButton
        #endif
    }

    private var previewButton: some View {
        Button(action: togglePreview) {
            Image(systemName: viewMode == .preview ? "pencil" : "doc.richtext")
        }
        .help(viewMode == .preview ? "Revenir à l’écriture (⌘R)" : "Aperçu du document (⌘R)")
        .accessibilityLabel(viewMode == .preview ? "Revenir à l’écriture" : "Aperçu du document")
    }
    private var shareMenu: some View {
        Menu { shareCommands } label: { Image(systemName: "square.and.arrow.up") }
            .help("Partager et exporter").accessibilityLabel("Partager et exporter")
    }
    @ViewBuilder private var shareCommands: some View {
        Button(action: copyMarkdown) { Label(copied ? "Texte copié" : "Copier pour une IA", systemImage: copied ? "checkmark" : "doc.on.doc") }
        ShareLink(item: draftText) { Label("Partager le document", systemImage: "square.and.arrow.up") }
        Divider()
        Button("Exporter en Markdown…") { export(.plainText, text: draftText) }
        Button("Exporter en Word…") { exportType = Self.wordType; exportDocument = WaveExportDocument(data: WriterWord.document(draftText)); showingExporter = true }
        Button("Exporter en HTML…") { export(.html, text: WriterMarkdown.html(draftText, title: parts.title, fontFamily: fontFamily, colorScheme: cssColorScheme)) }
        Button("Exporter en PDF…") {
            if viewMode == .editor { viewMode = .preview }
            previewController.requestPDF()
        }
        Divider()
        Button { if saveDraft() { showingImporter = true } } label: { Label("Joindre un fichier…", systemImage: "paperclip") }
    }
    private var noteActionsMenu: some View {
        Menu { noteCommands } label: { Image(systemName: "ellipsis") }
            .help("Actions du document").accessibilityLabel("Actions du document")
    }
    @ViewBuilder private var noteCommands: some View {
        Button(store.favoriteIDs.contains(noteID) ? "Retirer des favoris" : "Ajouter aux favoris") { store.toggleFavorite(noteID) }
        Button("Enregistrer", action: { _ = saveDraft() })
        Button("Enregistrer une copie", action: saveCopy)
        Menu("Déplacer vers") {
            ForEach(store.folders, id: \.self) { folder in
                Button(folder == "Inbox" ? "Documents" : folder) { moveToFolder(folder) }
            }
        }
        Divider()
        Button(role: .destructive) { showingDelete = true } label: { Label("Placer dans la Corbeille", systemImage: "trash") }
    }

    private var typographyPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Écriture").font(.headline)
            Picker("Apparence", selection: $appearance) {
                ForEach(WaveAppearance.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }.pickerStyle(.segmented)
            Picker("Police", selection: $fontFamily) {
                Text("Mono").tag("Mono"); Text("Duo").tag("Duo"); Text("Quattro").tag("Quattro")
            }.pickerStyle(.segmented)
            HStack { Text("Taille"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(WaveTheme.secondary) }
            Slider(value: $fontSize, in: 14...28, step: 1).accessibilityLabel("Taille du texte")
            HStack { Text("Largeur du texte"); Spacer(); Text("\(Int(columns)) caractères").foregroundStyle(WaveTheme.secondary) }
            Slider(value: $columns, in: 45...85, step: 5).accessibilityLabel("Largeur du texte")
            Divider()
            Toggle("Colorer les catégories grammaticales", isOn: $syntax)
            if syntax {
                HStack(spacing: 10) {
                    ForEach(WriterStyling.grammarLegend, id: \.label) { entry in
                        Text(entry.label).foregroundStyle(entry.color)
                    }
                }.font(.caption2.weight(.medium))
            }
            Toggle("Souligner les tics de style", isOn: $styleCheck)
            if styleCheck {
                Text("Expressions à surveiller, une par ligne").foregroundStyle(WaveTheme.secondary).font(.caption)
                TextEditor(text: $customPatterns).font(.caption).frame(height: 65)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(WaveTheme.border))
                    .accessibilityLabel("Expressions à surveiller")
                Text("Suggestions locales en français et en anglais. Aucune correction automatique.")
                    .font(.caption2).foregroundStyle(WaveTheme.secondary)
            }
            Divider()
            Text("Polices iA Writer · Information Architects\nDistribuées sous licence SIL Open Font License.")
                .font(.caption2).foregroundStyle(WaveTheme.secondary)
        }.font(.subheadline).padding(20).frame(width: 340)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if saveFailed {
                Image(systemName: "exclamationmark.circle").foregroundStyle(WaveTheme.amber)
                Text("Brouillon conservé")
                Button("Réessayer") { _ = saveDraft() }.buttonStyle(.plain).foregroundStyle(WaveTheme.accent)
            } else {
                Text(dirty ? "Enregistrement…" : (note?.folder == "Inbox" ? "Documents" : note?.folder ?? "Enregistré"))
            }
            Spacer()
            if focus != .off { statusPill(focus.label) }
            if syntax { statusPill("Grammaire") }
            if styleCheck { statusPill("Style") }
            Button { showingStatistics.toggle() } label: {
                Text("\(statistics.words) mots · \(statistics.readingMinutes) min")
                    .monospacedDigit()
            }.buttonStyle(.plain).accessibilityLabel("Statistiques du document")
                .popover(isPresented: $showingStatistics) { if showingStatistics { statisticsPanel } }
        }.font(.caption).foregroundStyle(WaveTheme.secondary).padding(.horizontal, 20).frame(height: 36)
    }

    private func statusPill(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(WaveTheme.elevated, in: Capsule())
    }

    private var statisticsPanel: some View {
        let selected = selectedStatistics
        return VStack(alignment: .leading, spacing: 14) {
            Text(selected == nil ? "Document" : "Sélection").font(.headline)
            let stats = selected ?? statistics
            statistic("Mots", value: stats.words)
            statistic("Caractères", value: stats.characters)
            statistic("Phrases", value: stats.sentences)
            statistic("Tâches terminées", value: stats.completedTasks, suffix: " / \(stats.tasks)")
            statistic("Temps de lecture", value: stats.readingMinutes, suffix: " min")
        }.font(.subheadline).padding(20).frame(width: 260)
    }
    private var selectedStatistics: WritingStatistics? {
        guard selection.length > 0, NSMaxRange(selection) <= (draftText as NSString).length else { return nil }
        return WritingStatistics((draftText as NSString).substring(with: selection))
    }
    private func statistic(_ label: String, value: Int, suffix: String = "") -> some View {
        HStack { Text(label).foregroundStyle(WaveTheme.secondary); Spacer(); Text("\(value)\(suffix)").monospacedDigit() }
    }
    private var attachmentSection: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(note?.attachments ?? [], id: \.self) { filename in
                    Button { previewURL = store.attachmentURL(noteID: noteID, filename: filename) } label: {
                        Label(filename, systemImage: isImageAttachment(filename) ? "photo" : "paperclip")
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(WaveTheme.elevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { previewURL = store.attachmentURL(noteID: noteID, filename: filename) } label: {
                            Label("Aperçu Quick Look", systemImage: "eye")
                        }
                        Button { insertAttachmentReference(filename) } label: {
                            Label("Insérer dans la note", systemImage: "text.insert")
                        }
                        Divider()
                        Button(role: .destructive) {
                            _ = store.removeAttachment(filename: filename, from: noteID)
                        } label: {
                            Label("Supprimer la pièce jointe", systemImage: "trash")
                        }
                    }
                }
            }.foregroundStyle(WaveTheme.secondary).padding(.horizontal, 20).padding(.vertical, 8)
        }.scrollIndicators(.hidden)
    }

    private func isImageAttachment(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
    }

    private func insertAttachmentReference(_ filename: String) {
        if viewMode == .preview { viewMode = .editor }
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let snippet = isImageAttachment(filename) ? "![](\(encoded))" : "[\(filename)](\(encoded))"
        editRequest = WriterEditRequest(command: "insert", insertText: snippet)
    }

    private func handlePastedAttachment(_ data: Data, filename: String) {
        if let saved = store.importAttachmentData(data, filename: filename, to: noteID) {
            insertAttachmentReference(saved)
        }
    }

    private func handleDroppedAttachments(_ urls: [URL]) {
        var snippets: [String] = []
        for url in urls {
            if let saved = store.importAttachment(from: url, to: noteID) {
                let encoded = saved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? saved
                snippets.append(isImageAttachment(saved) ? "![](\(encoded))" : "[\(saved)](\(encoded))")
            }
        }
        if !snippets.isEmpty {
            if viewMode == .preview { viewMode = .editor }
            editRequest = WriterEditRequest(command: "insert", insertText: snippets.joined(separator: "\n"))
        }
    }

    private var exportFilename: String {
        let name = parts.title.replacingOccurrences(of: "/", with: "-")
        return name + (exportType == .pdf ? ".pdf" : exportType == .html ? ".html" : exportType == Self.wordType ? ".docx" : ".md")
    }
    private func loadDraft() {
        guard let note else { return }
        original = note
        draftText = "# \(note.title)\n\n\(note.content)"
        dirty = false; saveFailed = false
        if let data = UserDefaults.standard.data(forKey: draftKey), let draft = try? JSONDecoder().decode(NoteDraft.self, from: data) {
            original = draft.original
            draftText = draft.text ?? "# \(draft.title ?? note.title)\n\n\(draft.body ?? note.content)"
            dirty = true
        }
        statistics = WritingStatistics(draftText)
    }
    private func syncFreshNote() {
        guard !dirty, inFlightSave == nil, let fresh = note, let original else { return }
        if fresh.title != original.title || fresh.content != original.content || fresh.folder != original.folder {
            loadDraft()
        } else if fresh != original {
            self.original = fresh
        }
    }
    private func scheduleStatistics() {
        statisticsTask?.cancel()
        statisticsRevision += 1
        let revision = statisticsRevision
        let text = draftText
        statisticsTask = Task { @MainActor in
            defer { if revision == statisticsRevision { statisticsTask = nil } }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            let result = await Task.detached(priority: .utility) { WritingStatistics(text) }.value
            guard !Task.isCancelled, revision == statisticsRevision else { return }
            statistics = result
        }
    }
    private func normalizedBody(_ body: String) -> String {
        body.trimmingCharacters(in: .newlines)
    }
    private func scheduleSave() {
        guard let original else { return }
        let document = parts
        dirty = document.title != original.title || normalizedBody(document.body) != normalizedBody(original.content)
        saveTask?.cancel()
        draftTask?.cancel()
        guard dirty else { UserDefaults.standard.removeObject(forKey: draftKey); return }
        draftTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            persistDraft()
        }
        // If an async save is already writing to disk, wait for it to finish before starting another.
        guard inFlightSave == nil else { return }
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 550_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            await saveDraftAsync()
        }
    }
    private func saveDraftAsync() async {
        saveTask = nil
        draftTask?.cancel()
        draftTask = nil
        guard dirty, inFlightSave == nil, let baseline = original else { return }
        let snapshotParts = parts
        let snapshotText = draftText
        var updated = baseline
        updated.title = snapshotParts.title
        updated.content = snapshotParts.body
        updated.modifiedAt = .now

        inFlightSnapshotText = snapshotText
        let task = Task<WaveNote?, Never> { @MainActor in
            await store.saveAsync(updated, replacing: baseline)
        }
        inFlightSave = task
        let saved = await task.value
        inFlightSave = nil
        inFlightSnapshotText = nil

        if let saved {
            self.original = saved
            let current = parts
            let stillDirty = current.title != saved.title || normalizedBody(current.body) != normalizedBody(saved.content)
            dirty = stillDirty
            saveFailed = false
            if !stillDirty && draftText == snapshotText {
                UserDefaults.standard.removeObject(forKey: draftKey)
            } else if stillDirty {
                scheduleSave()
            }
        } else {
            saveFailed = true
            persistDraft()
        }
    }
    @discardableResult private func saveDraft() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        draftTask?.cancel()
        draftTask = nil
        guard dirty else { return true }
        guard let original else { return false }

        // Avoid conflicting with an already in-flight background autosave for the same note.
        if let running = inFlightSave {
            let latestText = draftText
            if latestText == inFlightSnapshotText {
                return true
            }
            let latestParts = parts
            let key = draftKey
            let store = self.store
            persistDraft()
            Task { @MainActor in
                guard let savedBaseline = await running.value else { return }
                var next = savedBaseline
                next.title = latestParts.title
                next.content = latestParts.body
                next.modifiedAt = .now
                if await store.saveAsync(next, replacing: savedBaseline) != nil {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            return true
        }

        var updated = original
        updated.title = parts.title; updated.content = parts.body; updated.modifiedAt = .now
        if store.save(updated, replacing: original) {
            self.original = store.note(id: noteID) ?? updated
            dirty = false; saveFailed = false
            UserDefaults.standard.removeObject(forKey: draftKey)
            return true
        }
        saveFailed = true
        persistDraft()
        return false
    }
    private func persistDraft() {
        draftTask?.cancel()
        draftTask = nil
        guard dirty, let original,
              let data = try? JSONEncoder().encode(NoteDraft(original: original, text: draftText)) else { return }
        UserDefaults.standard.set(data, forKey: draftKey)
    }
    private func moveToFolder(_ folder: String) {
        guard saveDraft(), let note else { return }
        var moved = note; moved.folder = folder; moved.modifiedAt = .now
        if store.save(moved, replacing: note) { original = store.note(id: noteID) }
    }
    private func saveCopy() {
        if let copy = store.createNote(in: note?.folder ?? "Inbox", title: parts.title + " — copie", content: parts.body) {
            saveTask?.cancel(); draftTask?.cancel(); dirty = false
            UserDefaults.standard.removeObject(forKey: draftKey)
            onOpenNote(copy.id)
        }
    }
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls): for url in urls { store.importAttachment(from: url, to: noteID) }
        case let .failure(error): store.report(error)
        }
    }
    private func format(_ command: String) {
        if viewMode == .preview { viewMode = .editor }
        editRequest = WriterEditRequest(command: command)
    }
    private func toggleFocus() {
        focusMode = focus == .off ? WriterFocus.sentence.rawValue : WriterFocus.off.rawValue
    }
    private func togglePreview() {
        viewMode = viewMode == .preview ? .editor : .preview
    }
    private func toggleSplitPreview() {
        #if os(macOS)
        viewMode = viewMode == .split ? .editor : .split
        #else
        togglePreview()
        #endif
    }
    private func openWikiLink(_ title: String) {
        let decoded = title.removingPercentEncoding ?? title
        if let target = store.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(decoded) == .orderedSame }) {
            if saveDraft() { onOpenNote(target.id) }
        } else if saveDraft(), let created = store.createNote(in: note?.folder ?? "Inbox", title: decoded) { onOpenNote(created.id) }
    }
    private func export(_ type: UTType, text: String) { exportType = type; exportDocument = WaveExportDocument(data: Data(text.utf8)); showingExporter = true }
    private func copyMarkdown() {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draftText, forType: .string)
        #else
        UIPasteboard.general.string = draftText
        #endif
        copied = true
        copiedTask?.cancel()
        copiedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}

private struct WaveExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .html, .pdf, UTType("org.openxmlformats.wordprocessingml.document") ?? .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
