import SwiftUI

/// Sidebar list of trashed documents: restore them or delete them for good.
/// Documents disappear on their own after 30 days.
struct TrashOverviewView: View {
    @EnvironmentObject private var store: WaveStore
    @Binding var selection: UUID?
    @State private var showingEmptyConfirmation = false

    private var items: [TrashedNote] { store.trashedNotes }
    private var columnNavigationTitle: String {
        #if os(macOS)
        if #available(macOS 26, *) { return "" }
        #endif
        return "Corbeille"
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Text("Corbeille").lineLimit(1).font(.subheadline.weight(.semibold)).foregroundStyle(WaveTheme.text)
                Spacer()
                Text("30 jours max.")
                    .font(.caption2).foregroundStyle(WaveTheme.secondary)
            }.padding(.horizontal, 14).frame(height: 40)
            Divider()
            #endif
            documentList
            Divider()
            HStack {
                Text("\(items.count) document\(items.count == 1 ? "" : "s")").monospacedDigit()
                Spacer()
                if !items.isEmpty {
                    Button("Vider la corbeille") { showingEmptyConfirmation = true }
                        .buttonStyle(.plain).foregroundStyle(WaveTheme.accent)
                }
            }.font(.caption).foregroundStyle(WaveTheme.secondary).padding(.horizontal, 14).frame(height: 36)
        }
        .background(WaveTheme.surface)
        .navigationTitle(columnNavigationTitle)
        #if os(iOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 265, max: 360)
        #endif
        .confirmationDialog("Vider la corbeille ?", isPresented: $showingEmptyConfirmation, titleVisibility: .visible) {
            Button("Tout supprimer", role: .destructive) {
                store.emptyTrash()
                selection = nil
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les documents de la corbeille seront supprimés définitivement, avec leurs pièces jointes.")
        }
    }

    @ViewBuilder private var documentList: some View {
        #if os(macOS)
        List(selection: $selection) {
            ForEach(items) { item in
                row(item)
                    .tag(item.id)
                    .contextMenu { menu(item) }
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { emptyState }
        #else
        List(selection: $selection) {
            ForEach(items) { item in
                row(item)
                    .tag(item.id)
                    .listRowSeparator(.visible)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { restore(item) } label: { Label("Récupérer", systemImage: "arrow.uturn.backward") }
                            .tint(WaveTheme.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { delete(item) } label: { Label("Supprimer", systemImage: "trash.slash") }
                    }
                    .contextMenu { menu(item) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { emptyState }
        #endif
    }

    private func row(_ item: TrashedNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.note.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Text(item.note.excerpt).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            HStack {
                Text("Supprimé le \(item.deletedAt.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.caption2)
                Spacer()
                Text("Disparaît dans \(item.daysRemaining()) j")
                    .font(.caption2)
            }.foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }

    @ViewBuilder private func menu(_ item: TrashedNote) -> some View {
        Button("Récupérer") { restore(item) }
        Button("Supprimer définitivement", role: .destructive) { delete(item) }
    }

    private func restore(_ item: TrashedNote) {
        if store.restore(item) != nil, selection == item.id { selection = nil }
    }

    private func delete(_ item: TrashedNote) {
        if store.deletePermanently(item), selection == item.id { selection = nil }
    }

    @ViewBuilder private var emptyState: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 24, weight: .light))
                Text("Corbeille vide").font(.subheadline)
                Text("Les documents supprimés restent ici 30 jours.")
                    .font(.caption).multilineTextAlignment(.center)
            }.foregroundStyle(WaveTheme.secondary).padding(20)
        }
    }
}

/// Read-only preview of a trashed document, with restore and permanent deletion.
struct TrashedNoteView: View {
    @EnvironmentObject private var store: WaveStore
    let trashed: TrashedNote
    var onClose: () -> Void
    @State private var showingDeleteConfirmation = false

    private var remainingLabel: String {
        let days = trashed.daysRemaining()
        return days == 1 ? "1 jour" : "\(days) jours"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(trashed.note.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WaveTheme.text)
                    .lineLimit(2)
                Text("Supprimé le \(trashed.deletedAt.formatted(date: .abbreviated, time: .shortened)) · suppression définitive dans \(remainingLabel)")
                    .font(.caption).foregroundStyle(WaveTheme.secondary)
                HStack(spacing: 12) {
                    Button {
                        if store.restore(trashed) != nil { onClose() }
                    } label: {
                        Label("Récupérer", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(WavePrimaryButtonStyle())

                    Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                        Label("Supprimer définitivement", systemImage: "trash.slash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, WaveTheme.pagePadding)
            .padding(.top, 28)
            .padding(.bottom, 22)

            Divider()

            ScrollView {
                Text(trashed.note.content.isEmpty ? "Document vide" : trashed.note.content)
                    .font(.custom("iAWriterQuattroS-Regular", size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(trashed.note.content.isEmpty ? WaveTheme.secondary : WaveTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WaveTheme.pagePadding)
                    .padding(.vertical, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WaveTheme.background)
        .confirmationDialog("Supprimer définitivement ?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if store.deletePermanently(trashed) { onClose() }
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("« \(trashed.note.title) » et ses pièces jointes seront perdus pour toujours.")
        }
    }
}
