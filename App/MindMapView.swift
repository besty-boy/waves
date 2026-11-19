import SwiftUI

struct MindMapView: View {
    @EnvironmentObject private var store: WaveStore
    @Environment(\.scenePhase) private var scenePhase
    var onOpenNote: (UUID) -> Void = { _ in }

    @State private var mindMap = WaveMindMap(nodes: [], edges: [])
    @State private var original: WaveMindMap?
    @State private var selectedNodeID: UUID?
    @State private var liveDragID: UUID?
    @State private var liveDragOffset: CGSize = .zero
    @State private var saveTask: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var zoom: CGFloat = 1.0

    /// Stable logical canvas size so resizing the window never stretches or squashes the map.
    private let baseCanvas = CGSize(width: 1600, height: 1000)

    private var scaledCanvas: CGSize {
        CGSize(width: baseCanvas.width * zoom, height: baseCanvas.height * zoom)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Carte d’idées").font(.title2.weight(.bold)).tracking(-0.4)
                    Text("Faites de la place aux connexions.").font(.caption).foregroundStyle(WaveTheme.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            zoom = max(0.5, (zoom - 0.15).roundedToTwoDecimals)
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Zoom arrière")
                    .accessibilityLabel("Zoom arrière")

                    Button("\(Int(zoom * 100)) %") {
                        withAnimation(.easeOut(duration: 0.16)) { zoom = 1.0 }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .monospacedDigit()
                    .help("Réinitialiser le zoom")

                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            zoom = min(1.75, (zoom + 0.15).roundedToTwoDecimals)
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Zoom avant")
                    .accessibilityLabel("Zoom avant")
                }

                if !mindMap.nodes.isEmpty {
                    Button(action: autoLayout) {
                        Label("Organiser", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Disposer automatiquement les idées en arborescence")

                    Button { exportToNote(rootID: nil) } label: {
                        Label("Exporter en note", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Créer une note Markdown structurée depuis cette carte")
                }

                if let selectedNodeID {
                    Button(role: .destructive) { deleteNode(selectedNodeID) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Supprimer l’idée sélectionnée")
                    .accessibilityLabel("Supprimer l’idée sélectionnée")
                }
                Button(action: addNode) { Label("Une idée", systemImage: "plus") }
                    .buttonStyle(WavePrimaryButtonStyle())
                    #if os(macOS)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Ajouter une idée enfant (⌘↩)")
                    #endif
            }
            .padding(.horizontal, WaveTheme.pagePadding)
            .padding(.vertical, 18)
            .background {
                // Hidden sibling shortcut (⇧⌘↩) when a node is selected.
                Button("") { addSiblingNode() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Canvas { context, _ in
                        let step = max(16, 24 * zoom)
                        let clip = context.clipBoundingRect
                        let startX = max(step / 2, floor(clip.minX / step) * step + step / 2)
                        let startY = max(step / 2, floor(clip.minY / step) * step + step / 2)
                        for x in stride(from: startX, through: clip.maxX, by: step) {
                            for y in stride(from: startY, through: clip.maxY, by: step) {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                                             with: .color(WaveTheme.border))
                            }
                        }
                    }.allowsHitTesting(false)
                    edges(size: scaledCanvas)
                    ForEach($mindMap.nodes) { $node in
                        let linkedNote = node.noteID.flatMap { store.note(id: $0) }
                        let dragDelta = liveDragID == node.id ? liveDragOffset : .zero
                        MapNodeCard(
                            node: $node,
                            selected: selectedNodeID == node.id,
                            zoom: zoom,
                            linkedNoteTitle: linkedNote?.title,
                            onSelect: { selectedNodeID = node.id },
                            onOpenLinkedNote: {
                                if let noteID = node.noteID { onOpenNote(noteID) }
                            },
                            onDragChanged: { translation in
                                if selectedNodeID != node.id { selectedNodeID = node.id }
                                liveDragID = node.id
                                liveDragOffset = translation
                            },
                            onDragEnded: { translation in
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    node.x = min(0.92, max(0.08, node.x + Double(translation.width / scaledCanvas.width)))
                                    node.y = min(0.90, max(0.10, node.y + Double(translation.height / scaledCanvas.height)))
                                    liveDragID = nil
                                    liveDragOffset = .zero
                                }
                            }
                        )
                        .position(
                            x: scaledCanvas.width * CGFloat(node.x) + dragDelta.width,
                            y: scaledCanvas.height * CGFloat(node.y) + dragDelta.height
                        )
                        .contextMenu { nodeContextMenu(for: node) }
                    }
                }
                .frame(width: scaledCanvas.width, height: scaledCanvas.height)
                .coordinateSpace(name: "mindmap-canvas")
                .contentShape(Rectangle())
                .onTapGesture { selectedNodeID = nil }
            }
            .background(WaveTheme.mindMapCanvas)
            .overlay {
                if mindMap.nodes.isEmpty {
                    WaveEmptyState(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Tout commence par une idée.",
                        message: "Ajoutez une idée, puis reliez-la à la suivante ou associez-la à une note."
                    )
                }
            }
            Divider()
            HStack {
                Text(saveFailed ? "Carte non enregistrée" : "\(mindMap.nodes.count) idées · \(mindMap.edges.count) liens")
                    .monospacedDigit()
                if saveFailed {
                    Menu("Brouillon") {
                        Button("Réessayer", action: saveMindMap)
                        Button("Enregistrer une copie", action: saveMapCopy)
                    }.font(.caption).foregroundStyle(WaveTheme.accent)
                }
                Spacer()
                Text("⌘↩ idée enfant · ⇧⌘↩ idée sœur · clic droit pour relier, associer ou exporter.")
                    .lineLimit(1)
            }
            .font(.caption).foregroundStyle(WaveTheme.secondary)
            .padding(.horizontal, 22).padding(.vertical, 11)
        }
        .background(WaveTheme.background)
        .navigationTitle("Carte d’idées")
        .onAppear(perform: loadMap)
        .waveOnChange(of: mindMap) { _ in scheduleSave() }
        .onDisappear(perform: saveMindMap)
        .waveOnChange(of: scenePhase) { phase in if phase != .active { saveMindMap() } }
        .onReceive(NotificationCenter.default.publisher(for: .waveFlushDrafts)) { _ in saveMindMap() }
    }

    @ViewBuilder
    private func nodeContextMenu(for node: WaveMindMapNode) -> some View {
        let connectedIDs = connectedNodeIDs(for: node.id)
        let connectable = mindMap.nodes.filter { $0.id != node.id && !connectedIDs.contains($0.id) }
        let disconnectable = mindMap.nodes.filter { connectedIDs.contains($0.id) }

        Button {
            selectedNodeID = node.id
            addNode()
        } label: {
            Label("Ajouter une idée enfant", systemImage: "plus")
        }
        Button {
            exportToNote(rootID: node.id)
        } label: {
            Label("Exporter cette branche en note", systemImage: "doc.badge.plus")
        }
        Divider()
        if !connectable.isEmpty {
            Menu("Relier à") {
                ForEach(connectable) { other in
                    Button(other.title) { connect(node.id, to: other.id) }
                }
            }
        }
        if !disconnectable.isEmpty {
            Menu("Déconnecter de") {
                ForEach(disconnectable) { other in
                    Button(other.title) { disconnect(node.id, from: other.id) }
                }
            }
        }
        Menu("Couleur") {
            Button("Bleu") { setColor("blue", for: node.id) }
            Button("Violet") { setColor("violet", for: node.id) }
            Button("Menthe") { setColor("mint", for: node.id) }
            Button("Ambre") { setColor("amber", for: node.id) }
        }
        Divider()
        if let linkedID = node.noteID, store.note(id: linkedID) != nil {
            Button { onOpenNote(linkedID) } label: {
                Label("Ouvrir la note liée", systemImage: "doc.text")
            }
            Button("Retirer le lien vers la note") { setLinkedNote(nil, for: node.id) }
        }
        if !store.notes.isEmpty {
            Menu("Associer une note") {
                ForEach(store.notes.prefix(30)) { candidate in
                    Button(candidate.title) { setLinkedNote(candidate.id, for: node.id) }
                }
            }
        }
        Divider()
        Button(role: .destructive) { deleteNode(node.id) } label: {
            Label("Supprimer l’idée", systemImage: "trash")
        }
    }

    private func loadMap() {
        do {
            let loaded = try store.vault.coordinated { try $0.loadMindMap() }
            original = loaded
            mindMap = loaded
            if let data = UserDefaults.standard.data(forKey: draftKey),
               let draft = try? JSONDecoder().decode(MapDraft.self, from: data) {
                original = draft.original
                mindMap = draft.map
            }
        } catch { store.report(error) }
    }

    private func nodeCenter(_ node: WaveMindMapNode, in size: CGSize) -> CGPoint {
        let drag = liveDragID == node.id ? liveDragOffset : .zero
        return CGPoint(
            x: size.width * CGFloat(node.x) + drag.width,
            y: size.height * CGFloat(node.y) + drag.height
        )
    }

    private func edges(size: CGSize) -> some View {
        Canvas { context, _ in
            let lookup = Dictionary(mindMap.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for edge in mindMap.edges {
                guard let from = lookup[edge.from], let to = lookup[edge.to] else { continue }
                let start = nodeCenter(from, in: size)
                let end = nodeCenter(to, in: size)
                let middle = (start.x + end.x) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                context.stroke(path, with: .color(WaveTheme.mindMapEdge), lineWidth: 1.75)
            }
        }.allowsHitTesting(false)
    }

    private func connectedNodeIDs(for id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        for edge in mindMap.edges {
            if edge.from == id { result.insert(edge.to) }
            if edge.to == id { result.insert(edge.from) }
        }
        return result
    }

    private func addNode() {
        let parent = mindMap.nodes.first { $0.id == selectedNodeID } ?? mindMap.nodes.first
        let angle = Double(mindMap.nodes.count) * 1.15
        let node = WaveMindMapNode(title: "Nouvelle idée", subtitle: "Quelques mots pour commencer",
                                   colorToken: ["blue", "violet", "mint", "amber"][mindMap.nodes.count % 4],
                                   x: parent.map { min(0.90, max(0.10, $0.x + cos(angle) * 0.16)) } ?? 0.22,
                                   y: parent.map { min(0.88, max(0.12, $0.y + sin(angle) * 0.18)) } ?? 0.26)
        withAnimation(.snappy(duration: 0.24)) {
            mindMap.nodes.append(node)
            if let parent { mindMap.edges.append(WaveMindMapEdge(from: parent.id, to: node.id)) }
            selectedNodeID = node.id
        }
    }

    private func addSiblingNode() {
        guard let selected = selectedNodeID else { addNode(); return }
        let parentID = mindMap.edges.first(where: { $0.to == selected })?.from
        let reference = mindMap.nodes.first { $0.id == selected }
        let node = WaveMindMapNode(
            title: "Nouvelle idée",
            subtitle: "Quelques mots pour commencer",
            colorToken: reference?.colorToken ?? ["blue", "violet", "mint", "amber"][mindMap.nodes.count % 4],
            x: reference.map { min(0.90, max(0.10, $0.x)) } ?? 0.22,
            y: reference.map { min(0.88, max(0.12, $0.y + 0.15)) } ?? 0.26
        )
        withAnimation(.snappy(duration: 0.24)) {
            mindMap.nodes.append(node)
            if let parentID { mindMap.edges.append(WaveMindMapEdge(from: parentID, to: node.id)) }
            selectedNodeID = node.id
        }
    }

    /// Arranges nodes cleanly in a left-to-right tree hierarchy with zero overlap.
    private func autoLayout() {
        guard !mindMap.nodes.isEmpty else { return }
        let nodeIDs = Set(mindMap.nodes.map(\.id))
        var incomingCount: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for edge in mindMap.edges where nodeIDs.contains(edge.from) && nodeIDs.contains(edge.to) {
            children[edge.from, default: []].append(edge.to)
            incomingCount[edge.to, default: 0] += 1
        }
        var roots = mindMap.nodes.filter { (incomingCount[$0.id] ?? 0) == 0 }.map(\.id)
        if roots.isEmpty, let first = mindMap.nodes.first?.id { roots = [first] }

        var levels: [[UUID]] = []
        var visited: Set<UUID> = []
        var queue: [(UUID, Int)] = roots.map { ($0, 0) }
        for r in roots { visited.insert(r) }

        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            while levels.count <= depth { levels.append([]) }
            levels[depth].append(current)
            for child in children[current] ?? [] where !visited.contains(child) {
                visited.insert(child)
                queue.append((child, depth + 1))
            }
        }
        // Include any disconnected cycle members on the last column.
        let remaining = mindMap.nodes.map(\.id).filter { !visited.contains($0) }
        if !remaining.isEmpty {
            levels.append(remaining)
        }

        let colCount = max(1, levels.count)
        var positions: [UUID: (Double, Double)] = [:]
        for (colIndex, col) in levels.enumerated() {
            let x = colCount == 1 ? 0.50 : 0.12 + (0.76 * Double(colIndex) / Double(colCount - 1))
            let rowCount = max(1, col.count)
            for (rowIndex, id) in col.enumerated() {
                let y = rowCount == 1 ? 0.50 : 0.14 + (0.72 * Double(rowIndex) / Double(rowCount - 1))
                positions[id] = (x, y)
            }
        }

        withAnimation(.snappy(duration: 0.32)) {
            for idx in mindMap.nodes.indices {
                if let pos = positions[mindMap.nodes[idx].id] {
                    mindMap.nodes[idx].x = pos.0
                    mindMap.nodes[idx].y = pos.1
                }
            }
        }
    }

    /// Converts the mind map (or a selected branch) into a structured offline Markdown note.
    private func exportToNote(rootID: UUID?) {
        guard !mindMap.nodes.isEmpty else { return }
        let lookup = Dictionary(mindMap.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [UUID: [UUID]] = [:]
        var incoming: Set<UUID> = []
        for edge in mindMap.edges where lookup[edge.from] != nil && lookup[edge.to] != nil {
            children[edge.from, default: []].append(edge.to)
            incoming.insert(edge.to)
        }
        let startNodes: [UUID]
        let noteTitle: String
        if let rootID, let root = lookup[rootID] {
            startNodes = [rootID]
            noteTitle = root.title.isEmpty ? "Branche de carte" : root.title
        } else {
            let roots = mindMap.nodes.filter { !incoming.contains($0.id) }.map(\.id)
            startNodes = roots.isEmpty ? [mindMap.nodes[0].id] : roots
            noteTitle = "Carte d’idées — \(WaveTemplate.dailyTitle())"
        }

        var lines: [String] = []
        var visited: Set<UUID> = []

        func render(_ id: UUID, depth: Int) {
            guard !visited.contains(id), let node = lookup[id] else { return }
            visited.insert(id)
            let subtitle = node.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let linkedSuffix: String = {
                guard let linkedID = node.noteID, let linked = store.note(id: linkedID) else { return "" }
                return " · [[\(linked.title)]]"
            }()
            if depth == 0 {
                lines.append("## \(node.title)\(linkedSuffix)")
                if !subtitle.isEmpty { lines.append(subtitle) }
                lines.append("")
            } else {
                let indent = String(repeating: "  ", count: max(0, depth - 1))
                let desc = subtitle.isEmpty ? "" : " — \(subtitle)"
                lines.append("\(indent)- **\(node.title)**\(desc)\(linkedSuffix)")
            }
            for child in children[id] ?? [] {
                render(child, depth: depth + 1)
            }
        }

        for root in startNodes { render(root, depth: 0) }
        if rootID == nil {
            for node in mindMap.nodes where !visited.contains(node.id) {
                render(node.id, depth: 0)
            }
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let created = store.createNote(in: "Inbox", title: noteTitle, content: body) {
            onOpenNote(created.id)
        }
    }

    private func connect(_ from: UUID, to: UUID) {
        guard from != to, !mindMap.edges.contains(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            mindMap.edges.append(WaveMindMapEdge(from: from, to: to))
        }
    }

    private func disconnect(_ a: UUID, from b: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            mindMap.edges.removeAll { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
        }
    }

    private func setColor(_ token: String, for id: UUID) {
        guard let index = mindMap.nodes.firstIndex(where: { $0.id == id }) else { return }
        mindMap.nodes[index].colorToken = token
    }

    private func setLinkedNote(_ noteID: UUID?, for id: UUID) {
        guard let index = mindMap.nodes.firstIndex(where: { $0.id == id }) else { return }
        mindMap.nodes[index].noteID = noteID
    }

    private func deleteNode(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            mindMap.edges.removeAll { $0.from == id || $0.to == id }
            mindMap.nodes.removeAll { $0.id == id }
            if selectedNodeID == id { selectedNodeID = nil }
        }
    }

    private struct MapDraft: Codable { var original: WaveMindMap; var map: WaveMindMap }
    private var draftKey: String { "wave.mapDraft." + store.vault.rootURL.path }

    private func scheduleSave() {
        guard let original, mindMap != original else { return }
        if let data = try? JSONEncoder().encode(MapDraft(original: original, map: mindMap)) {
            UserDefaults.standard.set(data, forKey: draftKey)
        }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            if !Task.isCancelled { saveMindMap() }
        }
    }

    private func saveMindMap() {
        saveTask?.cancel()
        guard let original, mindMap != original else { return }
        do {
            try store.vault.coordinated(writing: true) { vault in
                try vault.saveMindMap(mindMap, replacing: original)
            }
            self.original = mindMap
            saveFailed = false
            UserDefaults.standard.removeObject(forKey: draftKey)
        } catch { saveFailed = true; store.report(error) }
    }

    private func saveMapCopy() {
        saveTask?.cancel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WaveMap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshot = directory.appendingPathComponent("Carte d’idées.json")
            try encoder.encode(mindMap).write(to: snapshot)
            let nodes = mindMap.nodes.map { "- **\($0.title)** — \($0.subtitle)" }.joined(separator: "\n")
            let lookup = Dictionary(mindMap.nodes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            let links = mindMap.edges.compactMap { edge -> String? in
                guard let from = lookup[edge.from], let to = lookup[edge.to] else { return nil }
                return "- \(from) → \(to)"
            }.joined(separator: "\n")
            guard let note = store.createNote(title: "Carte d’idées — copie", content: "## Idées\n\n\(nodes)\n\n## Connexions\n\n\(links)"),
                  store.importAttachment(from: snapshot, to: note.id) != nil else { return }
            let current = try store.vault.coordinated { try $0.loadMindMap() }
            original = current
            mindMap = current
            saveFailed = false
            UserDefaults.standard.removeObject(forKey: draftKey)
        } catch { store.report(error) }
    }
}

private extension CGFloat {
    var roundedToTwoDecimals: CGFloat { (self * 100).rounded() / 100 }
}

private struct MapNodeCard: View {
    @Binding var node: WaveMindMapNode
    let selected: Bool
    let zoom: CGFloat
    let linkedNoteTitle: String?
    var onSelect: () -> Void
    var onOpenLinkedNote: () -> Void
    var onDragChanged: (CGSize) -> Void
    var onDragEnded: (CGSize) -> Void

    private var color: Color {
        switch node.colorToken {
        case "violet": WaveTheme.violet
        case "mint": WaveTheme.mint
        case "amber": WaveTheme.amber
        default: WaveTheme.accent
        }
    }

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("mindmap-canvas"))
            .onChanged { value in onDragChanged(value.translation) }
            .onEnded { value in onDragEnded(value.translation) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
                if let linkedNoteTitle {
                    Button(action: onOpenLinkedNote) {
                        Label(linkedNoteTitle, systemImage: "doc.text")
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(WaveTheme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Idée").font(.caption2.weight(.medium)).foregroundStyle(WaveTheme.secondary)
                }
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WaveTheme.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("mindmap-canvas"))
                    .onChanged { value in onDragChanged(value.translation) }
                    .onEnded { value in onDragEnded(value.translation) }
            )

            TextField("Titre", text: $node.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WaveTheme.text)
                .textFieldStyle(.plain)
            TextField("Description", text: $node.subtitle)
                .font(.caption)
                .textFieldStyle(.plain)
                .foregroundStyle(WaveTheme.secondary)
        }
        .padding(16)
        .frame(width: 224, height: 118)
        .background(WaveTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(selected ? color : WaveTheme.border, lineWidth: selected ? 1.8 : 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .scaleEffect(zoom)
        .onTapGesture(perform: onSelect)
        .gesture(canvasDrag)
    }
}
