import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: WaveStore
    @EnvironmentObject private var updates: UpdateService
    @Environment(\.scenePhase) private var scenePhase
    @State private var route: SidebarRoute? = .allNotes
    @State private var selectedNote: UUID?
    @State private var selectedTrash: UUID?
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var showingDocumentImporter = false
    @State private var showingQuickOpen = false
    #if os(macOS)
    @State private var isLibraryHidden = false
    @AppStorage("wave.library.width") private var libraryWidth = 265.0
    #else
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    #endif

    private var scope: SidebarRoute { route ?? .allNotes }
    private var isUtilityScope: Bool { scope == .mcp || scope == .mindMap || scope == .settings || scope == .tasks }
    private var documents: [WaveNote] { store.filteredNotes(for: scope) }
    private var listSelection: Binding<UUID?> {
        Binding(
            get: { documents.contains(where: { $0.id == selectedNote }) ? selectedNote : nil },
            set: { if let id = $0 { selectedNote = id } }
        )
    }

    var body: some View {
        searchableSplitView
            .navigationSplitViewStyle(.balanced)
            .tint(WaveTheme.accent)
            .focusedSceneValue(\.waveWindowActions, WaveWindowActions(
                createNote: createNote,
                openQuickOpen: { showingQuickOpen = true },
                openDailyNote: openDailyNote,
                createFromTemplate: createFromTemplate,
                importDocument: { showingDocumentImporter = true },
                toggleLibrary: toggleLibrary
            ))
            .sheet(isPresented: $showingQuickOpen) {
                QuickOpenView(
                    onOpenNote: { open($0.id) },
                    onOpenRoute: { target in
                        route = target
                        #if os(iOS)
                        compactColumn = .detail
                        #endif
                    },
                    onCreateNote: { title in createNote(title: title) },
                    onOpenDailyNote: openDailyNote,
                    onCreateFromTemplate: createFromTemplate,
                    onToggleLibrary: toggleLibrary
                )
                .environmentObject(store)
            }
            .alert("Wave", isPresented: Binding(get: { store.errorMessage != nil }, set: {
                if !$0 { store.errorMessage = nil }
            })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            // Event-driven sync (VaultFilePresenter) watches disk/iCloud changes with 0% idle CPU;
            // we only perform a single refresh when returning to foreground.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                store.refreshInBackground(reportErrors: true)
            }
            .waveOnChange(of: store.searchText) { query in
                if #available(macOS 26, iOS 26, *), !query.isEmpty {
                    route = .allNotes
                    #if os(iOS)
                    compactColumn = .content
                    #endif
                }
            }
            .onAppear {
                #if os(macOS)
                Task { @MainActor in
                    if selectedNote == nil {
                        selectedNote = store.recentIDs.first(where: { store.note(id: $0) != nil }) ?? documents.first?.id
                    }
                }
                #endif
            }
            .waveOnChange(of: route) { newRoute in
                if case let .note(id) = newRoute { route = .allNotes; open(id) }
                else if scope == .trash {
                    selectedNote = nil
                    store.purgeTrashIfNeeded()
                    if selectedTrash == nil { selectedTrash = store.trashedNotes.first?.id }
                    #if os(iOS)
                    compactColumn = .content
                    #endif
                }
                else if isUtilityScope {
                    selectedNote = nil
                    #if os(iOS)
                    compactColumn = .detail
                    #endif
                }
                else {
                    #if os(iOS)
                    compactColumn = .content
                    #else
                    Task { @MainActor in
                        let currentDocs = store.filteredNotes(for: scope)
                        if store.searchText.isEmpty,
                           !currentDocs.contains(where: { $0.id == selectedNote }) {
                            selectedNote = currentDocs.first?.id
                        }
                    }
                    #endif
                }
            }
            .waveOnChange(of: store.notes.map(\.id)) { ids in
                #if os(macOS)
                if let selectedNote, !ids.contains(selectedNote) {
                    Task { @MainActor in
                        if let current = self.selectedNote, store.note(id: current) == nil {
                            self.selectedNote = store.filteredNotes(for: scope).first?.id ?? ids.first
                        }
                    }
                }
                #endif
            }
            .waveOnChange(of: selectedNote) { id in
                if id != nil, isUtilityScope || scope == .trash { route = .allNotes }
                if let id {
                    Task { @MainActor in if selectedNote == id { store.recordOpened(id) } }
                }
                #if os(iOS)
                if id != nil { compactColumn = .detail }
                #endif
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                UpdateBannerView(onOpenSettings: { route = .settings })
            }
            .task { await updates.onLaunch() }
            .waveOnChange(of: selectedTrash) { id in
                #if os(iOS)
                if id != nil { compactColumn = .detail }
                #endif
            }
            .waveOnChange(of: store.trashedNotes) { items in
                if let id = selectedTrash, !items.contains(where: { $0.id == id }) { selectedTrash = nil }
            }
    }

    @ViewBuilder private var searchableSplitView: some View {
        if #available(macOS 26, iOS 26, *) {
            splitView.searchable(text: $store.searchText, prompt: "Rechercher dans les documents")
        } else {
            splitView
        }
    }

    @ViewBuilder private var splitView: some View {
        #if os(iOS)
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            organizer
        } content: { fileList } detail: { detail }
        #else
        NavigationSplitView(columnVisibility: $visibility) {
            organizer
        } detail: {
            HStack(spacing: 0) {
                if !isUtilityScope && !isLibraryHidden {
                    fileList
                        .frame(width: min(380, max(210, libraryWidth)))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    WaveColumnDivider(width: $libraryWidth, range: 210...380, defaultWidth: 265)
                        .transition(.opacity)
                }
                detail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
            .animation(.snappy(duration: 0.22), value: isUtilityScope)
            .animation(.snappy(duration: 0.22), value: isLibraryHidden)
        }
        #endif
    }

    private var organizer: some View {
        SidebarView(
            route: $route,
            showingDocumentImporter: $showingDocumentImporter,
            onSearch: {
                route = .allNotes
                #if os(iOS)
                compactColumn = .content
                #endif
            },
            onCreate: createNote,
            onOpenQuickOpen: { showingQuickOpen = true },
            onOpenDailyNote: openDailyNote,
            onCreateFromTemplate: createFromTemplate,
            onOpenNote: open
        )
        .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 260)
    }

    @ViewBuilder private var fileList: some View {
        if scope == .trash {
            TrashOverviewView(selection: $selectedTrash)
        } else if isUtilityScope {
            NotesOverviewView(title: "Documents", isRecents: false, notes: store.visibleNotes, selection: listSelection, onCreate: createNote)
        } else {
            NotesOverviewView(title: store.title(for: scope), isRecents: scope == .recents, notes: documents, selection: listSelection, onCreate: createNote)
        }
    }

    @ViewBuilder private var detail: some View {
        switch scope {
        case .tasks: TasksOverviewView(onOpenNote: { open($0.id) })
        case .mcp: MCPSettingsView()
        case .mindMap: MindMapView(onOpenNote: open)
        case .settings: SettingsPageView()
        case .trash:
            if let id = selectedTrash, let trashed = store.trashedNotes.first(where: { $0.id == id }) {
                TrashedNoteView(trashed: trashed) { selectedTrash = nil }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "trash").font(.system(size: 26, weight: .light))
                        .foregroundStyle(WaveTheme.secondary)
                    Text(store.trashedNotes.isEmpty ? "La corbeille est vide." : "Sélectionnez un document pour le récupérer ou le supprimer définitivement.")
                        .font(.subheadline).foregroundStyle(WaveTheme.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(WaveTheme.background)
            }
        default:
            if let id = selectedNote, store.note(id: id) != nil {
                #if os(macOS)
                let hidden = isLibraryHidden && visibility == .detailOnly
                #else
                let hidden = visibility == .detailOnly
                #endif
                NoteEditorView(noteID: id, isLibraryHidden: hidden, onDelete: { selectedNote = nil }, onOpenNote: open,
                               onToggleLibrary: toggleLibrary).id(id)
            } else {
                VStack(spacing: 16) {
                    Text("Un espace pour écrire.")
                        .font(.custom("iAWriterDuoS-Regular", size: 22))
                        .foregroundStyle(WaveTheme.text)
                    HStack(spacing: 10) {
                        Button("Nouveau document", action: createNote)
                            .buttonStyle(WavePrimaryButtonStyle())
                        Button("Note du jour", action: openDailyNote)
                            .buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(WaveTheme.background)
            }
        }
    }

    private func toggleLibrary() {
        #if os(macOS)
        let enteringFocus = !(isLibraryHidden && visibility == .detailOnly)
        withAnimation(.snappy(duration: 0.22)) {
            isLibraryHidden = enteringFocus
            visibility = enteringFocus ? .detailOnly : .all
        }
        #else
        withAnimation(.snappy(duration: 0.22)) {
            visibility = visibility == .detailOnly ? .all : .detailOnly
        }
        #endif
    }

    private func open(_ id: UUID) {
        selectedNote = id
        route = .allNotes
        #if os(iOS)
        compactColumn = .detail
        #endif
    }

    private func createNote() {
        createNote(title: "Sans titre")
    }

    private func createNote(title: String) {
        let folder: String
        if case let .folder(name) = scope { folder = name } else { folder = "Inbox" }
        if let note = store.createNote(in: folder, title: title) {
            selectedNote = note.id
            if case .folder = scope { } else { route = .allNotes }
        }
        #if os(iOS)
        compactColumn = .detail
        #endif
    }

    private func openDailyNote() {
        if let note = store.openOrCreateDailyNote() {
            selectedNote = note.id
            route = .folder(note.folder)
            #if os(iOS)
            compactColumn = .detail
            #endif
        }
    }

    private func createFromTemplate(_ template: WaveTemplate) {
        let folder: String?
        if case let .folder(name) = scope { folder = name } else { folder = nil }
        if let note = store.createNote(from: template, in: folder) {
            selectedNote = note.id
            route = .folder(note.folder)
            #if os(iOS)
            compactColumn = .detail
            #endif
        }
    }
}
