import SwiftUI

/// A small floating banner shown when an update is available, being
/// downloaded, installed, or when something needs attention.
struct UpdateBannerView: View {
    @EnvironmentObject private var updates: UpdateService
    @Environment(\.openURL) private var openURL

    /// Opens the in-app settings page (injected by the hosting view).
    var onOpenSettings: () -> Void = {}

    /// Coarse animation key so continuous download progress ticks don't re-trigger spring transitions.
    private var animationKey: Int {
        switch updates.banner {
        case .none: 0
        case .update: 1
        case .upToDate: 2
        case .failed: 3
        case .tokenHint: 4
        case .progress: 5
        case .installing: 6
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let banner = updates.banner {
                card(for: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.28), value: animationKey)
    }

    @ViewBuilder
    private func card(for banner: UpdateService.Banner) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName(for: banner))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor(for: banner))
                .frame(width: 34, height: 34)
                .background(iconColor(for: banner).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: banner))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WaveTheme.text)
                Text(subtitle(for: banner))
                    .font(.caption)
                    .foregroundStyle(WaveTheme.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            actions(for: banner)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 660)
        .waveGlassBanner()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Texts

    private func iconName(for banner: UpdateService.Banner) -> String {
        switch banner {
        case .update: return "arrow.down.circle.fill"
        case .upToDate: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .tokenHint: return "key.fill"
        case .progress: return "arrow.down.circle"
        case .installing: return "arrow.triangle.2.circlepath"
        }
    }

    private func iconColor(for banner: UpdateService.Banner) -> Color {
        switch banner {
        case .failed: return WaveTheme.amber
        case .upToDate: return WaveTheme.mint
        default: return WaveTheme.accent
        }
    }

    private func title(for banner: UpdateService.Banner) -> String {
        switch banner {
        case let .update(release):
            return "\(release.title) est disponible"
        case .upToDate:
            return "Wave est à jour"
        case .failed:
            return "Mise à jour impossible"
        case .tokenHint:
            return "Activez les mises à jour automatiques"
        case .progress:
            return "Téléchargement de la mise à jour…"
        case .installing:
            return "Installation…"
        }
    }

    private func subtitle(for banner: UpdateService.Banner) -> String {
        switch banner {
        case let .update(release):
            if UpdateService.isDevBuild {
                return "Version de développement : ouvrez la release pour l’installer manuellement."
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(release.assetSize), countStyle: .file)
            return "Version \(release.version) (\(size)) — installation et relance automatiques."
        case .upToDate:
            return "La dernière version (\(updates.appVersion)) est installée."
        case let .failed(message):
            return message
        case .tokenHint:
            return "Ajoutez un token GitHub dans les Réglages pour être prévenu des nouvelles versions."
        case .progress:
            return "Ensuite, Wave se relancera automatiquement."
        case .installing:
            return "Wave va se relancer dans un instant."
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(for banner: UpdateService.Banner) -> some View {
        switch banner {
        case let .update(release):
            if UpdateService.isDevBuild {
                if let page = release.pageURL {
                    primaryButton("Voir la release") { openURL(page) }
                }
            } else {
                primaryButton("Mettre à jour") { Task { await updates.install() } }
            }
            secondaryButton("Plus tard") { updates.later(release) }
            iconButton("xmark") { updates.ignore(release) }
                .help("Ignorer cette version")
                .accessibilityLabel("Ignorer cette version")

        case .tokenHint:
            primaryButton("Ouvrir les Réglages") { onOpenSettings() }
            secondaryButton("Plus tard") { updates.dismissBanner() }

        case let .failed(message):
            if let page = updates.release?.pageURL {
                secondaryButton("Ouvrir la release") { openURL(page) }
            }
            secondaryButton("Fermer") { updates.dismissBanner() }
                .help(message)

        case .upToDate:
            secondaryButton("Fermer") { updates.dismissBanner() }

        case let .progress(value):
            HStack(spacing: 8) {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
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
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(WaveTheme.accent)
            .controlSize(.small)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(WaveTheme.secondary)
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WaveTheme.secondary)
        }
        .buttonStyle(.plain)
    }
}
