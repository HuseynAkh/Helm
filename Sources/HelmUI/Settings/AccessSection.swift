#if os(macOS)
import HelmCore
import SwiftUI

/// What Settings › General needs for its Access section: the permission, and ways into the guide and the welcome.
public struct AccessSettings {
    public let permissions: PermissionCenter
    public let setUp: () -> Void
    public let showWelcome: () -> Void
    public init(permissions: PermissionCenter, setUp: @escaping () -> Void, showWelcome: @escaping () -> Void) {
        self.permissions = permissions; self.setUp = setUp; self.showWelcome = showWelcome
    }
}

/// Settings › General › Access: whether Helm has Full Disk Access, and the way to give it. macOS decides who gets it;
/// Helm never changes it.
struct AccessSection: View {
    @ObservedObject var permissions: PermissionCenter
    let settings: AccessSettings

    init(settings: AccessSettings) {
        self.settings = settings
        self.permissions = settings.permissions
    }

    var body: some View {
        let on = permissions.fullDiskAccess == .granted
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: on ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .font(.system(size: 22)).foregroundStyle(on ? Color.green : Color.orange)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(on ? "Full Disk Access is on" : "Full Disk Access is off").font(.headline)
                    Text(on ? "Change it in System Settings." : "Lets Helm see the Trash and other apps’ folders.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(on ? "Show Guide…" : "Turn On…") { settings.setUp() }
                    // VoiceOver can read it on its own, as from its list of buttons, so it says what it's for.
                    .accessibilityLabel(on ? "Show Full Disk Access guide" : "Turn on Full Disk Access")
            }
            HStack {
                Text("Welcome window")
                Spacer()
                Button("Show…") { settings.showWelcome() }
                    .accessibilityLabel("Show welcome window")
            }
        } header: {
            Text("Access")
        }
        .onAppear { Task { await permissions.refresh() } }
    }
}
#endif
