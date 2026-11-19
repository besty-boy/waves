import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var store: WaveStore
    @Binding var route: SidebarRoute?
    @Binding var showingDocumentImporter: Bool
    var onSearch: () -> Void
    var onCreate: () -> Void
    var onOpenQuickOpen: () -> Void
    var onOpenDailyNote: () -> Void
    var onCreateFromTemplate: (WaveTemplate) -> Void
    var onOpenNote: (UUID) -> Void

    @State private var showingNewFolder = false
    @State private var showingSmartFolder = false
    @State private var newFolderName = ""
    @State private var smartName = ""
    @State private var smartQuery = ""
    @State private var folderToRename: String?
    @State private var renameFolderText = ""
    @State private var folderToDelete: String?
    @State private var dropTargetedFolder: String?

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if #unavailable(macOS 26) {
                HStack {
                    Text("Bibliothèque").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(action: onOpenQuickOpen) { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Ouverture rapide (⌘O)").accessibilityLabel("Ouverture rapide")
                    Button(action: onCreate) { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .help("Nouveau document (⌘N)").accessibilityLabel("Nouveau document")
                }.padding(.horizontal, 16).frame(height: 44)
                Divider()
            }
            #endif
            if #unavailable(macOS 26, iOS 26) { legacySearchField }
            List(selection: $route) {
                Section {
                    row("Tous les documents", icon: "doc.text", count: store.notes.count, value: .allNotes)
                    row("Favoris", icon: "star", count: store.favoriteIDs.count, value: .favorites)
                    row("Récemment ouverts", icon: "clock", value: .recents)
                    row("Tâches", icon: "checklist", count: store.openTaskCount, value: .tasks)
                }
                Section {
                    ForEach(store.folders, id: \.self) { folder in
                        let isInbox = folder == "Inbox"
                        let title = isInbox ? (store.isShared ? "iCloud / dossier partagé" : "Documents") : folder
                        let icon = isInbox ? (store.isShared ? "icloud" : "folder") : "folder"
                        let count = store.notes.filter { $0.folder == folder }.count
                        row(title, icon: icon, count: count, value: .folder(folder))
                            .listRowBackground(dropTargetedFolder == folder ? WaveTheme.accent.opacity(0.16) : nil)
                            .dropDestination(for: String.self) { items, _ in
                                var moved = false
                                for item in items {
                                    if let id = UUID(uuidString: item), store.moveNote(id, toFolder: folder) {
                                        moved = true
                                    }
                                }
                                return moved
                            } isTargeted: { targeted in
                                dropTargetedFolder = targeted ? folder : (dropTargetedFolder == folder ? nil : dropTargetedFolder)
                            }
                            .contextMenu {
                                if !isInbox {
                                    Button("Renommer…") {
                                        renameFolderText = folder
                                        folderToRename = folder
                                    }
                                    Button("Supprimer le dossier", role: .destructive) {
                                        folderToDelete = folder
                                    }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Emplacements"); Spacer()
                        Button { newFolderName = ""; showingNewFolder = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("Créer un dossier")
                    }
                }
                if !store.smartFolders.isEmpty {
                    Section("Dossiers intelligents") {
                        ForEach(store.smartFolders) { folder in
                            row(folder.name, icon: "folder.badge.gearshape", value: .smart(folder.id))
                                .contextMenu {
                                    Button("Supprimer le dossier intelligent", role: .destructive) {
                                        store.removeSmartFolder(folder.id)
                                    }
                                }
                        }
                    }
                }
                if !store.tags.isEmpty {
                    Section("Hashtags") {
                        ForEach(store.tags, id: \.self) { tag in
                            row(tag, icon: "number", value: .tag(tag))
                        }
                    }
                }
                Section("Outils") {
                    row("Carte d’idées", icon: "point.3.connected.trianglepath.dotted", value: .mindMap)
                    row("IA & appareils", icon: "sparkles", value: .mcp)
                    row("Réglages", icon: "gearshape", value: .settings)
                }
                Section {
                    row("Corbeille", icon: "trash", count: store.trashedNotes.count, value: .trash)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 12) {
                Menu {
                    Button(action: onOpenDailyNote) {
                        Label("Note du jour", systemImage: "calendar")
                    }
                    Menu {
                        ForEach(WaveTemplate.builtIn) { template in
                            Button { onCreateFromTemplate(template) } label: {
                                Label(template.name, systemImage: template.icon)
                            }
                        }
                    } label: {
                        Label("Nouveau depuis un modèle", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button { showingDocumentImporter = true } label: {
                        Label("Importer un document…", systemImage: "square.and.arrow.down")
                    }
                    Button { newFolderName = ""; showingNewFolder = true } label: {
                        Label("Nouveau dossier", systemImage: "folder.badge.plus")
                    }
                    Button { smartName = ""; smartQuery = store.searchText; showingSmartFolder = true } label: {
                        Label("Nouveau dossier intelligent", systemImage: "folder.badge.gearshape")
                    }
                } label: {
                    Label("Ajouter", systemImage: "plus.circle")
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Options de la bibliothèque")
                Spacer()
                Button(action: onOpenQuickOpen) {
                    Image(systemName: "command")
                }
                .buttonStyle(.borderless)
                .help("Ouverture rapide (⌘O)")
                .accessibilityLabel("Ouverture rapide")
                Button(action: onCreate) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Nouveau document (⌘N)")
                .accessibilityLabel("Nouveau document")
            }
            .foregroundStyle(WaveTheme.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        .waveSidebarSurface()
        .navigationTitle("Bibliothèque")
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onOpenQuickOpen) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Ouverture rapide")
                Button(action: onCreate) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Nouveau document")
            }
        }
        #endif
        .alert("Nouveau dossier", isPresented: $showingNewFolder) {
            TextField("Nom du dossier", text: $newFolderName)
            Button("Annuler", role: .cancel) { }
            Button("Créer") { if let folder = store.createFolder(newFolderName) { route = .folder(folder) } }
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { folderToRename != nil }, set: { if !$0 { folderToRename = nil } })) {
            TextField("Nouveau nom", text: $renameFolderText)
            Button("Annuler", role: .cancel) { folderToRename = nil }
            Button("Renommer") {
                if let old = folderToRename, let renamed = store.renameFolder(old, to: renameFolderText) {
                    if route == .folder(old) { route = .folder(renamed) }
                }
                folderToRename = nil
            }
        }
        .alert("Supprimer le dossier ?", isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })) {
            Button("Annuler", role: .cancel) { folderToDelete = nil }
            Button("Supprimer", role: .destructive) {
                if let folder = folderToDelete, store.deleteFolder(folder) {
                    if route == .folder(folder) { route = .allNotes }
                }
                folderToDelete = nil
            }
        } message: {
            Text("Les documents contenus dans ce dossier seront déplacés dans « Documents ». Aucune note ne sera perdue.")
        }
        .alert("Dossier intelligent", isPresented: $showingSmartFolder) {
            TextField("Nom", text: $smartName)
            TextField("Recherche", text: $smartQuery)
            Button("Annuler", role: .cancel) { }
            Button("Créer") { store.addSmartFolder(name: smartName, query: smartQuery) }
        } message: { Text("Combinez des mots, #hashtags, title:, folder: ou has:task. Excluez un terme avec -mot.") }
        .fileImporter(isPresented: $showingDocumentImporter, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                let folder: String
                if case let .folder(name) = route { folder = name } else { folder = "Inbox" }
                var lastID: UUID?
                for url in urls { if let note = store.importDocument(from: url, into: folder) { lastID = note.id } }
                if let lastID { onOpenNote(lastID) }
            case let .failure(error): store.report(error)
            }
        }
    }

    private var legacySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(WaveTheme.secondary)
            TextField("Rechercher", text: $store.searchText)
                .textFieldStyle(.plain).accessibilityLabel("Rechercher dans les documents")
                .onSubmit(onSearch)
                .waveOnChange(of: store.searchText) { query in
                    #if os(macOS)
                    if !query.isEmpty { onSearch() }
                    #endif
                }
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(WaveTheme.secondary).accessibilityLabel("Effacer la recherche")
            }
        }.font(.caption).padding(8)
            .background(WaveTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(WaveTheme.border, lineWidth: 0.5))
            .padding(12)
    }

    private func row(_ title: String, icon: String, count: Int = 0, value: SidebarRoute) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(WaveTheme.secondary).frame(width: 16)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(WaveTheme.secondary)
            }
        }.padding(.vertical, 2).tag(value).listRowSeparator(.hidden)
    }
}
