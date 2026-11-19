import SwiftUI

@main
struct WaveApp: App {
    @StateObject private var store = WaveStore()
    @StateObject private var updates = UpdateService()
    @AppStorage("wave.appearance") private var appearance = WaveAppearance.system.rawValue

    init() { WriterFonts.register() }

    private var preferredScheme: ColorScheme? {
        (WaveAppearance(rawValue: appearance) ?? .system).colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(updates)
                .preferredColorScheme(preferredScheme)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 580)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            WaveCommands(updates: updates)
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updates)
                .preferredColorScheme(preferredScheme)
        }
        #endif
    }
}

#if os(macOS)
private struct WaveCommands: Commands {
    @ObservedObject var updates: UpdateService
    @FocusedValue(\.waveWindowActions) private var windowActions
    @FocusedValue(\.waveEditorActions) private var editorActions

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Rechercher des mises à jour…") {
                Task { await updates.check(manual: true) }
            }
            .disabled(updates.isBusy)
        }

        CommandGroup(replacing: .newItem) {
            Button("Nouveau document") { windowActions?.createNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(windowActions == nil)
            Button("Note du jour") { windowActions?.openDailyNote() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(windowActions == nil)
            Menu("Nouveau depuis un modèle") {
                ForEach(WaveTemplate.builtIn) { template in
                    Button(template.name) {
                        windowActions?.createFromTemplate(template)
                    }
                }
            }
            .disabled(windowActions == nil)
            Divider()
            Button("Ouverture rapide…") { windowActions?.openQuickOpen() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(windowActions == nil)
            Button("Importer un document…") { windowActions?.importDocument() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(windowActions == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Enregistrer") { editorActions?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editorActions == nil)
        }

        CommandMenu("Format") {
            Button("Gras") { editorActions?.format("bold") }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(editorActions == nil)
            Button("Italique") { editorActions?.format("italic") }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(editorActions == nil)
            Button("Lien") { editorActions?.format("link") }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(editorActions == nil)
            Button("Lien interne [[…]]") { editorActions?.format("wikilink") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(editorActions == nil)
            Divider()
            Button("Titre") { editorActions?.format("heading") }
                .disabled(editorActions == nil)
            Button("Liste") { editorActions?.format("list") }
                .disabled(editorActions == nil)
            Button("Tâche") { editorActions?.format("task") }
                .disabled(editorActions == nil)
            Button("Citation") { editorActions?.format("quote") }
                .disabled(editorActions == nil)
            Button("Code") { editorActions?.format("code") }
                .disabled(editorActions == nil)
        }

        CommandMenu("Présentation") {
            Button("Aperçu du document") { editorActions?.togglePreview() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(editorActions == nil)
            Button("Aperçu côte à côte") { editorActions?.toggleSplitPreview() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(editorActions == nil)
            Button("Plan, rétroliens & historique") { editorActions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(editorActions == nil)
            Button("Mode concentration") { editorActions?.toggleFocus() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(editorActions == nil)
            Button("Afficher ou masquer la bibliothèque") { windowActions?.toggleLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(windowActions == nil)
            Divider()
            Button("Placer dans la Corbeille") { editorActions?.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(editorActions == nil)
        }
    }
}
#endif
