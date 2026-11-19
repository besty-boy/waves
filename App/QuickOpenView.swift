import SwiftUI

/// Fast offline Quick Open & Command Palette (⌘O) for instant navigation across notes and actions.
struct QuickOpenView: View {
    @EnvironmentObject private var store: WaveStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wave.appearance") private var appearance = WaveAppearance.system.rawValue

    let onOpenNote: (WaveNote) -> Void
    let onOpenRoute: (SidebarRoute) -> Void
    let onCreateNote: (String) -> Void
    let onOpenDailyNote: () -> Void
    let onCreateFromTemplate: (WaveTemplate) -> Void
    let onToggleLibrary: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private enum EntryKind {
        case note(WaveNote)
        case command(title: String, subtitle: String, icon: String, shortcut: String?, action: () -> Void)
        case create(String)
    }

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let shortcut: String?
        let score: Int
        let kind: EntryKind
    }

    private var entries: [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandOnly = trimmed.hasPrefix(">")
        let needle = (commandOnly ? String(trimmed.dropFirst()) : trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var results: [Entry] = []

        if !commandOnly {
            if needle.isEmpty {
                let byID = Dictionary(store.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let recents = store.recentIDs.compactMap { byID[$0] }
                let ordered = recents.isEmpty ? Array(store.notes.prefix(8)) : Array(recents.prefix(6))
                for (offset, note) in ordered.enumerated() {
                    let folderLabel = note.folder == "Inbox" ? "Documents" : note.folder
                    results.append(Entry(
                        id: "note-\(note.id.uuidString)",
                        title: note.title,
                        subtitle: folderLabel,
                        icon: store.favoriteIDs.contains(note.id) ? "star.fill" : "doc.text",
                        shortcut: nil,
                        score: 1000 - offset,
                        kind: .note(note)
                    ))
                }
            } else {
                for note in store.notes {
                    if let score = Self.fuzzyScore(query: needle, title: note.title, folder: note.folder, body: note.snippet) {
                        let folderLabel = note.folder == "Inbox" ? "Documents" : note.folder
                        results.append(Entry(
                            id: "note-\(note.id.uuidString)",
                            title: note.title,
                            subtitle: folderLabel,
                            icon: store.favoriteIDs.contains(note.id) ? "star.fill" : "doc.text",
                            shortcut: nil,
                            score: score,
                            kind: .note(note)
                        ))
                    }
                }
            }
        }

        for cmd in builtInCommands() {
            if needle.isEmpty {
                results.append(cmd)
            } else if let score = Self.fuzzyScore(query: needle, title: cmd.title, folder: cmd.subtitle, body: "") {
                results.append(Entry(
                    id: cmd.id,
                    title: cmd.title,
                    subtitle: cmd.subtitle,
                    icon: cmd.icon,
                    shortcut: cmd.shortcut,
                    score: commandOnly ? score + 500 : score - 20,
                    kind: cmd.kind
                ))
            }
        }

        if !needle.isEmpty {
            results.sort { $0.score > $1.score }
        }

        var limited = Array(results.prefix(14))

        if !commandOnly, !needle.isEmpty,
           !store.notes.contains(where: { $0.title.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            limited.append(Entry(
                id: "create-new",
                title: "Créer « \(needle) »",
                subtitle: "Nouveau document",
                icon: "plus.circle",
                shortcut: "↩",
                score: -1000,
                kind: .create(needle)
            ))
        }

        return limited
    }

    private func builtInCommands() -> [Entry] {
        var commands: [Entry] = [
            Entry(id: "cmd-daily", title: "Ouvrir la note du jour", subtitle: "Journal · \(WaveTemplate.dailyTitle())", icon: "calendar", shortcut: "⇧⌘D", score: 500,
                  kind: .command(title: "Ouvrir la note du jour", subtitle: "Journal", icon: "calendar", shortcut: "⇧⌘D", action: onOpenDailyNote)),
            Entry(id: "cmd-new", title: "Nouveau document", subtitle: "Créer une note vide", icon: "square.and.pencil", shortcut: "⌘N", score: 490,
                  kind: .command(title: "Nouveau document", subtitle: "Créer une note vide", icon: "square.and.pencil", shortcut: "⌘N", action: { onCreateNote("Sans titre") })),
            Entry(id: "cmd-tasks", title: "Afficher toutes les tâches", subtitle: "\(store.openTaskCount) tâche\(store.openTaskCount > 1 ? "s" : "") ouverte\(store.openTaskCount > 1 ? "s" : "")", icon: "checklist", shortcut: nil, score: 480,
                  kind: .command(title: "Afficher toutes les tâches", subtitle: "Tâches", icon: "checklist", shortcut: nil, action: { onOpenRoute(.tasks) })),
            Entry(id: "cmd-mindmap", title: "Ouvrir la carte mentale", subtitle: "Espace visuel", icon: "point.3.connected.trianglepath.dotted", shortcut: nil, score: 470,
                  kind: .command(title: "Ouvrir la carte mentale", subtitle: "Espace visuel", icon: "point.3.connected.trianglepath.dotted", shortcut: nil, action: { onOpenRoute(.mindMap) })),
            Entry(id: "cmd-library", title: "Afficher ou masquer la bibliothèque", subtitle: "Présentation", icon: "sidebar.left", shortcut: "⇧⌘L", score: 460,
                  kind: .command(title: "Afficher ou masquer la bibliothèque", subtitle: "Présentation", icon: "sidebar.left", shortcut: "⇧⌘L", action: onToggleLibrary)),
            Entry(id: "cmd-appearance", title: "Changer d’apparence", subtitle: "Actuel : \((WaveAppearance(rawValue: appearance) ?? .system).label)", icon: "circle.lefthalf.filled", shortcut: nil, score: 450,
                  kind: .command(title: "Changer d’apparence", subtitle: "Thème", icon: "circle.lefthalf.filled", shortcut: nil, action: {
                      let all = WaveAppearance.allCases
                      let current = WaveAppearance(rawValue: appearance) ?? .system
                      if let idx = all.firstIndex(of: current) {
                          appearance = all[(idx + 1) % all.count].rawValue
                      }
                  }))
        ]

        for template in WaveTemplate.builtIn where template.id != "daily" {
            commands.append(Entry(
                id: "cmd-tpl-\(template.id)",
                title: "Modèle : \(template.name)",
                subtitle: "Créer depuis un modèle",
                icon: template.icon,
                shortcut: nil,
                score: 430,
                kind: .command(title: "Modèle : \(template.name)", subtitle: "Modèle", icon: template.icon, shortcut: nil, action: { onCreateFromTemplate(template) })
            ))
        }
        return commands
    }

    var body: some View {
        let items = entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(WaveTheme.secondary)
                TextField("Aller à un document ou taper > pour une commande…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .onSubmit {
                        activateSelected(from: items)
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(WaveTheme.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().overlay(WaveTheme.border)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Text("Aucun résultat")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(WaveTheme.text)
                    Text("Essayez un autre mot-clé ou préfixez par « > » pour les commandes.")
                        .font(.caption)
                        .foregroundStyle(WaveTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == clampedSelection(for: items))
                                    .id(item.id)
                                    .onTapGesture {
                                        activate(item)
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 340)
                    .waveOnChange(of: selectedIndex) { idx in
                        if idx >= 0 && idx < items.count {
                            proxy.scrollTo(items[idx].id, anchor: .center)
                        }
                    }
                }
            }

            Divider().overlay(WaveTheme.border)

            HStack(spacing: 14) {
                Text("↩ Ouvrir")
                #if os(macOS)
                Text("↑↓ Naviguer")
                Text("⎋ Fermer")
                #endif
                Spacer()
                Text("100 % local")
            }
            .font(.caption2)
            .foregroundStyle(WaveTheme.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(WaveTheme.elevated.opacity(0.6))
        }
        .background(WaveTheme.surface)
        #if os(macOS)
        .frame(width: 560)
        #endif
        .onAppear {
            selectedIndex = 0
            searchFocused = true
        }
        .waveOnChange(of: query) { _ in
            selectedIndex = 0
        }
        .modifier(QuickOpenKeyNavigation(itemCount: items.count, selectedIndex: $selectedIndex))
    }

    private func clampedSelection(for items: [Entry]) -> Int {
        guard !items.isEmpty else { return 0 }
        return min(max(0, selectedIndex), items.count - 1)
    }

    private func row(_ item: Entry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white : WaveTheme.accent)
                .frame(width: 24, height: 24)
                .background(selected ? Color.white.opacity(0.18) : WaveTheme.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? .white : WaveTheme.text)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : WaveTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.caption2.monospaced())
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : WaveTheme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.16) : WaveTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? WaveTheme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private func activateSelected(from items: [Entry]) {
        guard !items.isEmpty else { return }
        activate(items[clampedSelection(for: items)])
    }

    private func activate(_ item: Entry) {
        dismiss()
        switch item.kind {
        case let .note(note):
            onOpenNote(note)
        case let .command(_, _, _, _, action):
            action()
        case let .create(title):
            onCreateNote(title)
        }
    }

    private static func fuzzyScore(query: String, title: String, folder: String, body: String) -> Int? {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let t = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let f = folder.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 850 - t.count }
        if t.contains(q) { return 700 - t.count }
        if isSubsequence(q, of: t) { return 550 - t.count }
        if f.contains(q) { return 400 }
        if !body.isEmpty {
            let b = body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if b.contains(q) { return 250 }
        }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var idx = haystack.startIndex
        for ch in needle {
            guard let found = haystack[idx...].firstIndex(of: ch) else { return false }
            idx = haystack.index(after: found)
        }
        return true
    }
}

private struct QuickOpenKeyNavigation: ViewModifier {
    let itemCount: Int
    @Binding var selectedIndex: Int

    func body(content: Content) -> some View {
        if #available(macOS 14, iOS 17, *) {
            content
                .onKeyPress(.downArrow) {
                    guard itemCount > 0 else { return .ignored }
                    selectedIndex = (selectedIndex + 1) % itemCount
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard itemCount > 0 else { return .ignored }
                    selectedIndex = (selectedIndex - 1 + itemCount) % itemCount
                    return .handled
                }
        } else {
            content
        }
    }
}
