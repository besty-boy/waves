#if os(macOS)
import SwiftUI

/// The macOS Settings window uses the same controls as the in-app settings page.
struct SettingsView: View {
    var body: some View {
        SettingsPageView()
            .frame(minWidth: 540, minHeight: 480)
    }
}
#endif
