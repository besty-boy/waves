import SwiftUI

/// Global offline checklist aggregating Markdown tasks (`- [ ]` / `- [x]`) across every note.
struct TasksOverviewView: View {
    @EnvironmentObject private var store: WaveStore
    let onOpenNote: (WaveNote) -> Void

    private enum TaskFilter: String, CaseIterable, Identifiable {
        case open, completed, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .open: return "À faire"
            case .completed: return "Terminées"
            case .all: return "Toutes"
            }
        }
    }

    @State private var filter: TaskFilter = .open
    @State private var query = ""

    private var groupedTasks: [(note: WaveNote, tasks: [DocumentTask])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.allNotesWithTasks().compactMap { entry in
            let filtered = entry.tasks.filter { task in
                let statusMatches: Bool = switch filter {
                case .open: !task.completed
                case .completed: task.completed
                case .all: true
                }
                guard statusMatches else { return false }
                guard !needle.isEmpty else { return true }
                return task.text.localizedCaseInsensitiveContains(needle)
                    || entry.note.title.localizedCaseInsensitiveContains(needle)
            }
            return filtered.isEmpty ? nil : (entry.note, filtered)
        }
    }

    private var totals: (open: Int, completed: Int) {
        var open = 0
        var completed = 0
        for entry in store.allNotesWithTasks() {
            for task in entry.tasks {
                if task.completed { completed += 1 } else { open += 1 }
            }
        }
        return (open, completed)
    }

    var body: some View {
        let groups = groupedTasks
        let counts = totals

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(open: counts.open, completed: counts.completed)
                controls

                if groups.isEmpty {
                    WaveEmptyState(
                        icon: filter == .open ? "checkmark.circle" : "checklist",
                        title: emptyTitle,
                        message: "Ajoutez des cases « - [ ] Ma tâche » dans n’importe quelle note pour les suivre automatiquement ici, même hors ligne."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.note.id) { group in
                            noteTaskCard(note: group.note, tasks: group.tasks)
                        }
                    }
                }
            }
            .padding(WaveTheme.pagePadding)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WaveTheme.background)
        #if os(iOS)
        .navigationTitle("Tâches")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "Aucune tâche trouvée" }
        switch filter {
        case .open: return "Tout est terminé"
        case .completed: return "Aucune tâche terminée"
        case .all: return "Aucune tâche dans vos notes"
        }
    }

    private func header(open: Int, completed: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tâches")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(WaveTheme.text)
                Text("\(open) à faire · \(completed) terminée\(completed > 1 ? "s" : "")")
                    .font(.subheadline)
                    .foregroundStyle(WaveTheme.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterPicker
                Spacer(minLength: 12)
                searchField.frame(maxWidth: 260)
            }
            VStack(alignment: .leading, spacing: 10) {
                filterPicker
                searchField
            }
        }
    }

    private var filterPicker: some View {
        Picker("Filtre", selection: $filter) {
            ForEach(TaskFilter.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 300)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(WaveTheme.secondary)
            TextField("Filtrer les tâches…", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(WaveTheme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WaveTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func noteTaskCard(note: WaveNote, tasks: [DocumentTask]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onOpenNote(note)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(WaveTheme.accent)
                    Text(note.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WaveTheme.text)
                    Text(note.folder == "Inbox" ? "Documents" : note.folder)
                        .font(.caption2)
                        .foregroundStyle(WaveTheme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(WaveTheme.elevated, in: Capsule())
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(WaveTheme.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(WaveTheme.border)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(tasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button {
                            withAnimation(.snappy(duration: 0.16)) {
                                _ = store.toggleTask(in: note.id, lineIndex: task.lineIndex)
                            }
                        } label: {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(task.completed ? WaveTheme.mint : WaveTheme.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.completed ? "Marquer comme non terminée" : "Marquer comme terminée")

                        Text(task.text)
                            .font(.subheadline)
                            .strikethrough(task.completed, color: WaveTheme.secondary)
                            .foregroundStyle(task.completed ? WaveTheme.secondary : WaveTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .waveCard()
    }
}
