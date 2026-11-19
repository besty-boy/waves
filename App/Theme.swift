import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum WaveAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Automatique"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var cssColorScheme: String {
        switch self {
        case .system: "light dark"
        case .light: "light"
        case .dark: "dark"
        }
    }
}

extension Notification.Name {
    static let waveFlushDrafts = Notification.Name("com.wave.notes.flushDrafts")
}

enum WaveTheme {
    static let background = Color.waveDynamic(light: 0xFFFFFF, dark: 0x161618)
    static let sidebar = Color.waveDynamic(light: 0xF2F2F4, dark: 0x1B1B1E)
    static let surface = Color.waveDynamic(light: 0xFFFFFF, dark: 0x1E1E21)
    static let elevated = Color.waveDynamic(light: 0xF4F4F6, dark: 0x27272B)
    static let border = Color.waveDynamic(light: 0xDCDCE0, dark: 0x34343A)
    static let text = Color.waveDynamic(light: 0x1D1D1F, dark: 0xECECEF)
    /// WCAG AA compliant secondary text (>= 6.3:1 in both Light & Dark).
    static let secondary = Color.waveDynamic(light: 0x5E5E63, dark: 0x9E9EA6)
    static let accent = Color.waveDynamic(light: 0x007CC3, dark: 0x3AA9F5)
    static let mint = Color.waveDynamic(light: 0x1F8049, dark: 0x3CD07A)
    static let violet = Color.waveDynamic(light: 0x7547CC, dark: 0xA984F5)
    static let amber = Color.waveDynamic(light: 0xA86A0C, dark: 0xF2B149)
    static let mindMapCanvas = Color.waveDynamic(light: 0xFAFAFC, dark: 0x121214)
    static let mindMapEdge = Color.waveDynamic(light: 0xC2C7D0, dark: 0x4A4E58)

    static var pagePadding: CGFloat {
        #if os(macOS)
        36
        #else
        22
        #endif
    }
}

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static func waveDynamic(light: UInt, dark: UInt) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #endif
    }
}

enum SidebarRoute: Hashable {
    case allNotes
    case favorites
    case recents
    case tasks
    case tag(String)
    case smart(UUID)
    case folder(String)
    case note(UUID)
    case mindMap
    case mcp
    case settings
    case trash
}

// MARK: - Focused Command Actions (macOS Menu Bar & Shortcuts)

struct WaveWindowActions {
    var createNote: () -> Void
    var openQuickOpen: () -> Void
    var openDailyNote: () -> Void
    var createFromTemplate: (WaveTemplate) -> Void
    var importDocument: () -> Void
    var toggleLibrary: () -> Void
}

struct WaveEditorActions {
    var save: () -> Void
    var format: (String) -> Void
    var toggleFocus: () -> Void
    var togglePreview: () -> Void
    var toggleSplitPreview: () -> Void
    var toggleInspector: () -> Void
    var requestDelete: () -> Void
}

private struct WaveWindowActionsKey: FocusedValueKey {
    typealias Value = WaveWindowActions
}

private struct WaveEditorActionsKey: FocusedValueKey {
    typealias Value = WaveEditorActions
}

extension FocusedValues {
    var waveWindowActions: WaveWindowActions? {
        get { self[WaveWindowActionsKey.self] }
        set { self[WaveWindowActionsKey.self] = newValue }
    }

    var waveEditorActions: WaveEditorActions? {
        get { self[WaveEditorActionsKey.self] }
        set { self[WaveEditorActionsKey.self] = newValue }
    }
}

// MARK: - Shared UI Components

#if os(macOS)
/// Smooth hairline column divider with horizontal resize drag and double-click reset.
struct WaveColumnDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    @State private var dragStartWidth: Double?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            WaveTheme.border
                .frame(width: 1)
            Color.clear
                .frame(width: 7)
                .contentShape(Rectangle())
        }
        .frame(width: 1)
        .zIndex(1)
        .onHover { hovering in
            if hovering && !isHovering {
                isHovering = true
                NSCursor.resizeLeftRight.push()
            } else if !hovering && isHovering {
                isHovering = false
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                isHovering = false
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = dragStartWidth ?? width
                    if dragStartWidth == nil { dragStartWidth = base }
                    width = min(range.upperBound, max(range.lowerBound, base + value.translation.width))
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy(duration: 0.2)) {
                width = defaultWidth
            }
        }
    }
}
#endif

struct WavePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(WaveTheme.accent.opacity(configuration.isPressed ? 0.78 : 1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct WaveCardHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(WaveTheme.accent)
                .frame(width: 44, height: 44)
                .background(WaveTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(WaveTheme.secondary)
            }
        }
    }
}

struct WaveEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(WaveTheme.secondary)
                .frame(width: 64, height: 64)
                .background(WaveTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(WaveTheme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

extension View {
    /// Use the current change observer while retaining macOS 13 support.
    @ViewBuilder func waveOnChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        #if os(iOS)
        onChange(of: value) { _, newValue in action(newValue) }
        #else
        if #available(macOS 14, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
        #endif
    }

    @ViewBuilder func waveSidebarSurface() -> some View {
        if #available(macOS 26, iOS 26, *) {
            background(Color.clear)
        } else {
            background(WaveTheme.sidebar)
        }
    }

    @ViewBuilder func waveGlassControl() -> some View {
        if #available(macOS 26, iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderless)
        }
    }

    @ViewBuilder func waveGlassBanner() -> some View {
        if #available(macOS 26, iOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WaveTheme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        }
    }

    func waveCard() -> some View {
        self.padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WaveTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WaveTheme.border, lineWidth: 1))
    }
}

#if os(iOS)
extension View {
    @ViewBuilder func waveLegacySearch(text: Binding<String>) -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            searchable(text: text, prompt: "Rechercher dans les documents")
        }
    }
}
#endif
