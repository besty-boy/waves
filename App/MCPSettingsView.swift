import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MCPSettingsView: View {
    @EnvironmentObject private var store: WaveStore
    @AppStorage("wave.mcp.packagePath") private var packagePath = ""
    @AppStorage("wave.mcp.writeEnabled") private var writeEnabled = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var showingLibraryPicker = false
    @State private var showingPackagePicker = false
    @State private var showingLocalConfirmation = false

    #if os(macOS)
    private var bundledMCPPath: String? {
        let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WaveMCP").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
    #endif

    private var validPackage: Bool {
        let path = packagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/")
            && FileManager.default.fileExists(atPath: path + "/Package.swift")
            && FileManager.default.fileExists(atPath: path + "/Sources/WaveMCP/main.swift")
    }

    private var hasReadyConfig: Bool {
        #if os(macOS)
        return bundledMCPPath != nil || validPackage
        #else
        return false
        #endif
    }

    private var config: String {
        #if os(macOS)
        let env: [String: String] = [
            "WAVE_VAULT_PATH": store.vault.rootURL.path,
            "WAVE_MCP_WRITE": writeEnabled ? "1" : "0"
        ]
        let server: [String: Any]
        if let binary = bundledMCPPath {
            server = [
                "command": binary,
                "env": env
            ]
        } else {
            server = [
                "command": "/usr/bin/xcrun",
                "args": ["swift", "run", "--package-path", packagePath.trimmingCharacters(in: .whitespacesAndNewlines), "WaveMCP"],
                "env": env
            ]
        }
        let payload: [String: Any] = ["mcpServers": ["wave": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
        #else
        return ""
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    #if os(macOS)
                    Text("IA & appareils")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.8)
                    #endif
                    Text("Vos idées vous accompagnent, même hors ligne.")
                        .font(.subheadline)
                        .foregroundStyle(WaveTheme.secondary)
                }
                .padding(.bottom, 2)

                devicesCard
                aiCard

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text").font(.subheadline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vos notes sont des fichiers Markdown locaux.").font(.caption.weight(.medium))
                        Text("Vous pouvez écrire sans connexion internet, les ouvrir ailleurs et les garder avec vous.")
                            .font(.caption)
                            .foregroundStyle(WaveTheme.secondary)
                    }
                }
                .foregroundStyle(WaveTheme.secondary)
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, WaveTheme.pagePadding)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WaveTheme.background)
        .navigationTitle("IA & appareils")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .waveOnChange(of: config) { _ in
            copied = false
        }
        .fileImporter(isPresented: $showingLibraryPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): store.useSharedFolder(url)
            case let .failure(error): store.report(error)
            }
        }
        .fileImporter(isPresented: $showingPackagePicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): packagePath = url.path
            case let .failure(error): store.report(error)
            }
        }
        .alert("Revenir aux notes locales ?", isPresented: $showingLocalConfirmation) {
            Button("Annuler", role: .cancel) { }
            Button("Ouvrir la bibliothèque locale") { store.useLocalLibrary() }
        } message: {
            Text("Le dossier partagé est conservé. Les nouvelles notes de ce dossier ne sont pas recopiées dans la bibliothèque locale.")
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            WaveCardHeader(
                title: "Bibliothèque",
                subtitle: "Mac, iPhone et iPad · disponible hors ligne",
                icon: "laptopcomputer.and.iphone"
            )
            HStack(spacing: 8) {
                Image(systemName: store.isShared ? "folder.badge.gearshape" : "internaldrive")
                Text(store.isShared ? "Dossier partagé sélectionné" : "Sur cet appareil")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(WaveTheme.secondary)

            Text("Créez un dossier Wave dans iCloud Drive, puis choisissez ce même dossier sur chaque appareil. Vos notes restent éditables sans réseau et se synchronisent dès qu’iCloud Drive retrouve une connexion.")
                .font(.subheadline)
                .foregroundStyle(WaveTheme.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Button { showingLibraryPicker = true } label: {
                Label(store.isShared ? "Changer de dossier" : "Choisir un dossier partagé", systemImage: "folder")
            }
            .buttonStyle(WavePrimaryButtonStyle())

            Text("Vos notes actuelles sont copiées dans le dossier choisi sans supprimer les originaux.")
                .font(.caption)
                .foregroundStyle(WaveTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Bibliothèque actuelle").font(.caption.weight(.medium))
                Label(store.isShared ? store.vault.rootURL.lastPathComponent : "Wave · sur cet appareil", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
                #if os(macOS)
                DisclosureGroup("Afficher l’emplacement") {
                    Text(store.vault.rootURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WaveTheme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(WaveTheme.secondary)
                #endif
                if store.isShared {
                    Button("Ouvrir mes notes locales") { showingLocalConfirmation = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(WaveTheme.accent)
                        .padding(.top, 4)
                }
            }
        }
        .waveCard()
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            WaveCardHeader(
                title: "Accès IA",
                subtitle: writeEnabled ? "MCP en lecture et écriture" : "MCP en lecture seule",
                icon: "sparkles"
            )
            VStack(alignment: .leading, spacing: 10) {
                Text("Connecter un client MCP").font(.headline)
                Text(writeEnabled
                     ? "Le client peut rechercher, lire, créer et modifier vos notes (avec contrôle de révision)."
                     : "Le client peut rechercher et lire vos notes, tâches, tags, rétroliens, pièces jointes et carte d’idées.")
                    .font(.subheadline)
                    .foregroundStyle(WaveTheme.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                #if os(macOS)
                Toggle("Autoriser l’écriture des notes", isOn: $writeEnabled)
                    .font(.subheadline)
                    .waveOnChange(of: writeEnabled) { _ in copied = false }
                    .padding(.top, 2)

                if bundledMCPPath != nil {
                    Label("Serveur WaveMCP intégré · prêt à l’emploi", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(WaveTheme.mint)
                } else {
                    HStack {
                        TextField("Chemin du projet Wave", text: $packagePath)
                            .textFieldStyle(.plain)
                            .font(.system(.caption, design: .monospaced))
                        Button { showingPackagePicker = true } label: { Image(systemName: "folder") }
                            .buttonStyle(.plain)
                            .foregroundStyle(WaveTheme.accent)
                            .help("Choisir le dossier du projet Wave")
                            .accessibilityLabel("Choisir le dossier du projet Wave")
                    }
                    .padding(12)
                    .background(WaveTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Label(
                        validPackage ? "Projet trouvé · configuration à ajouter au client" : "Choisissez le dossier contenant Package.swift",
                        systemImage: validPackage ? "checkmark.circle" : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
                }

                if hasReadyConfig {
                    ScrollView(.horizontal) {
                        Text(config)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(WaveTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button(action: copyConfig) {
                        Label(
                            copied ? "Configuration copiée" : "Copier la configuration MCP",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)

                    Text("Après un changement de bibliothèque ou d’autorisation, recopiez cette configuration et redémarrez le client MCP.")
                        .font(.caption)
                        .foregroundStyle(WaveTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #else
                Label("Le serveur MCP se lance sur votre Mac.", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
                #endif
            }
        }
        .waveCard()
    }

    private func copyConfig() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        #else
        UIPasteboard.general.string = config
        #endif
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
