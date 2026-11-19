import SwiftUI

struct NotesOverviewView: View {
    @EnvironmentObject private var store: WaveStore
    let title: String
    var isRecents: Bool = false
    let notes: [WaveNote]
    @Binding var selection: UUID?
    var onCreate: () -> Void
    @AppStorage("wave.library.sort") private var sort = "modified"

    private var columnNavigationTitle: String {
        #if os(macOS)
        if #available(macOS 26, *) { return "" }
        #endif
        return title
    }

    private var sortedNotes: [WaveNote] {
        if isRecents { return notes }
        return sort == "title"
            ? notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            : notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 8) {
                Text(title).lineLimit(1).font(.subheadline.weight(.semibold)).foregroundStyle(WaveTheme.text)
                Spacer()
                sortMenu
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            #endif
            documentList
            Divider()
            HStack {
                Text("\(notes.count) document\(notes.count == 1 ? "" : "s")")
                    .monospacedDigit()
                Spacer()
                Button(action: onCreate) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nouveau document")
                    .help("Nouveau document (⌘N)")
            }
            .font(.caption)
            .foregroundStyle(WaveTheme.secondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
        .background(WaveTheme.surface)
        .navigationTitle(columnNavigationTitle)
        #if os(iOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 265, max: 360)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { sortMenu } }
        .waveLegacySearch(text: $store.searchText)
        #endif
    }

    private var sortMenu: some View {
        Menu {
            Picker("Trier par", selection: $sort) {
                Text("Dernière modification").tag("modified")
                Text("Nom du document").tag("title")
            }
        } label: { Image(systemName: "arrow.up.arrow.down") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(WaveTheme.secondary)
            .tint(WaveTheme.secondary)
            .accessibilityLabel("Trier les documents")
    }

    @ViewBuilder private var documentList: some View {
        #if os(macOS)
        List(selection: $selection) {
            ForEach(sortedNotes) { note in
                noteRow(note)
                    .tag(note.id)
                    .draggable(note.id.uuidString)
                    .contextMenu { noteMenu(note) }
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { emptyState }
        #else
        List(selection: $selection) {
            ForEach(sortedNotes) { note in
                noteRow(note)
                    .tag(note.id)
                    .listRowSeparator(.visible)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { trash(note) } label: {
                            Label("Corbeille", systemImage: "trash")
                        }
                    }
                    .contextMenu { noteMenu(note) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { emptyState }
        #endif
    }

    private func noteRow(_ note: WaveNote) -> some View {
        let noteTags = store.tags(for: note.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(note.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !note.attachments.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "paperclip")
                        if note.attachments.count > 1 {
                            Text("\(note.attachments.count)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if store.favoriteIDs.contains(note.id) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(WaveTheme.amber)
                }
            }
            Text(note.excerpt)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(note.modifiedAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                if !noteTags.isEmpty {
                    ForEach(noteTags.prefix(2), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                }
                Spacer(minLength: 4)
                if note.folder != "Inbox" {
                    Text(note.folder).font(.caption2).lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func noteMenu(_ note: WaveNote) -> some View {
        Button(store.favoriteIDs.contains(note.id) ? "Retirer des favoris" : "Ajouter aux favoris") { store.toggleFavorite(note.id) }
        Button("Dupliquer") { if let copy = store.duplicate(note) { selection = copy.id } }
        Menu("Déplacer vers") {
            ForEach(store.folders, id: \.self) { folder in
                Button(folder == "Inbox" ? "Documents" : folder) {
                    _ = store.moveNote(note.id, toFolder: folder)
                }
            }
        }
        ShareLink(item: note.markdown) { Label("Partager", systemImage: "square.and.arrow.up") }
        Divider()
        Button("Mettre à la corbeille", role: .destructive) { trash(note) }
    }

    private func trash(_ note: WaveNote) {
        if store.moveToTrash(note), selection == note.id { selection = nil }
    }

    @ViewBuilder private var emptyState: some View {
        if notes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 24, weight: .light))
                Text(store.searchText.isEmpty ? "Aucun document" : "Aucun résultat").font(.subheadline)
            }.foregroundStyle(WaveTheme.secondary)
        }
    }
}

extension WaveNote {
    var excerpt: String {
        let cleaned = String(content.prefix(600)).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- `")) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.isEmpty ? "Document vide" : cleaned
    }
}
