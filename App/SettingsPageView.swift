import SwiftUI
#if os(macOS)
import AppKit
#endif

enum WaveLinks {
    static let githubReleases = URL(string: "https://github.com/besty-boy/waves/releases")
}

// MARK: - Shared Settings Subviews

struct WaveUpdateStatusView: View {
    let banner: UpdateService.Banner?
    var progressWidth: CGFloat = 120
    var maxMessageWidth: CGFloat = 260
    var messageAlignment: Alignment = .leading

    var body: some View {
        switch banner {
        case .progress(let value):
            HStack(spacing: 8) {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(width: progressWidth)
                Text("\(Int(value * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WaveTheme.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installation…")
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
            }
        case .upToDate:
            Label("À jour", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(WaveTheme.mint)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(WaveTheme.amber)
                .lineLimit(2)
                .frame(maxWidth: maxMessageWidth, alignment: messageAlignment)
        default:
            EmptyView()
        }
    }
}

/// In-app settings page, available from the sidebar on macOS and iOS.
struct SettingsPageView: View {
    @EnvironmentObject private var store: WaveStore
    @EnvironmentObject private var updates: UpdateService
    @AppStorage("wave.appearance") private var appearanceRaw = WaveAppearance.system.rawValue

    private var appearanceBinding: Binding<WaveAppearance> {
        Binding(
            get: { WaveAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    private var channelLabel: String {
        UpdateService.isDevBuild ? "Version de développement (Wave Dev)" : "Version officielle"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        #if os(macOS)
                        Text("Réglages")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.8)
                        #endif
                        Text("Apparence, mises à jour et informations sur l’app.")
                            .font(.subheadline)
                            .foregroundStyle(WaveTheme.secondary)
                    }
                    Spacer()
                    if !updates.isOnline {
                        Label("Hors ligne · 100 % local", systemImage: "wifi.slash")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WaveTheme.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(WaveTheme.elevated, in: Capsule())
                    }
                }
                .padding(.bottom, 2)

                appearanceCard
                #if os(macOS)
                updatesCard
                #else
                updatesInfoCard
                #endif
                aboutCard
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, WaveTheme.pagePadding)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(WaveTheme.background)
        .navigationTitle("Réglages")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    // MARK: - Apparence

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            WaveCardHeader(
                title: "Apparence",
                subtitle: "Choisissez le thème clair, sombre ou celui du système.",
                icon: "circle.lefthalf.filled"
            )
            Picker("Apparence", selection: appearanceBinding) {
                ForEach(WaveAppearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .waveCard()
    }

    // MARK: - Mises à jour

    #if os(macOS)
    private var updatesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            WaveCardHeader(
                title: "Mises à jour",
                subtitle: "Mac · dépôt public GitHub",
                icon: "arrow.down.circle"
            )
            infoRow("Version installée", updates.appVersion)
            if let release = updates.release {
                infoRow("Version disponible", release.version)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await updates.check(manual: true) }
                } label: {
                    Label("Rechercher une mise à jour", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(updates.isBusy || !updates.isOnline)
                .help(updates.isOnline ? "Vérifier maintenant" : "Indisponible hors ligne")

                WaveUpdateStatusView(banner: updates.banner)
                Spacer()
            }
            Text("Wave vérifie les nouvelles versions publiques uniquement lorsque vous êtes connecté (au lancement puis toutes les 6 heures). Hors ligne, aucune requête réseau n’est émise.")
                .font(.caption)
                .foregroundStyle(WaveTheme.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .waveCard()
    }
    #endif

    private var updatesInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            WaveCardHeader(title: "Mises à jour", subtitle: "iPhone et iPad", icon: "arrow.down.circle")
            Text("Les mises à jour automatiques concernent l’app Mac. Sur iPhone et iPad, installez les nouvelles versions depuis Xcode sur votre Mac.")
                .font(.subheadline)
                .foregroundStyle(WaveTheme.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .waveCard()
    }

    // MARK: - À propos

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            WaveCardHeader(title: "Wave", subtitle: channelLabel, icon: "wave.3.right")
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Version", "\(updates.appVersion) (\(buildNumber))")
                infoRow("Identifiant", Bundle.main.bundleIdentifier ?? "—")
                #if os(macOS)
                infoRow("Bibliothèque", store.isShared ? store.vault.rootURL.lastPathComponent : "Sur ce Mac")
                #endif
            }
            HStack(spacing: 16) {
                if let releasesURL = WaveLinks.githubReleases {
                    Link(destination: releasesURL) {
                        Label("Voir les versions sur GitHub", systemImage: "arrow.up.right.square")
                    }
                    .font(.caption)
                }
                #if os(macOS)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.vault.rootURL])
                } label: {
                    Label("Révéler la bibliothèque", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(WaveTheme.accent)
                #endif
            }
        }
        .waveCard()
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(WaveTheme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WaveTheme.text)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
