#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Help › Set Up Helm… and Help › Full Disk Access…, and what scripted runs check about access.
extension AppController {
    @objc func showSetup(_ sender: Any?) { access.showWelcome() }
    @objc func showFullDiskAccessGuide(_ sender: Any?) { access.showGuide(.fullDiskAccess) }

    var permissionsForTesting: PermissionCenter { access.permissions }
    /// The stand-in a fixture run uses for the real permission. Nil outside one.
    var privacyForTesting: MemoryPrivacyAccess? { access.privacy as? MemoryPrivacyAccess }
    /// The stand-in a fixture run uses for moving Helm into Applications. Nil outside one.
    var moverForTesting: MemoryAppMover? { access.mover as? MemoryAppMover }
    var onboardingForTesting: OnboardingWindowController? { access.onboarding }
}
#endif
