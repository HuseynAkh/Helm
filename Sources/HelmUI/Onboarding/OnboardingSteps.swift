#if os(macOS)
import Foundation
import HelmAgent

/// One step of the onboarding, in the order they come: welcome, Full Disk Access, the default file viewer and the
/// Dock, AI mode, then done. Only the steps that apply to this copy of Helm show.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, access, viewer, ai, done

    public var title: String {
        switch self {
        case .welcome: return "Welcome to Helm"
        case .access: return "Full Disk Access"
        case .viewer: return "Default File Viewer"
        case .ai: return AgentText.aiTitle
        case .done: return "You’re All Set"
        }
    }
    /// The one line under the title.
    public var subtitle: String {
        switch self {
        case .welcome: return AgentText.setupHeader
        case .access: return SetupRow.fullDiskAccess.detail
        case .viewer: return SetupRow.fileViewer.detail
        case .ai: return AgentText.aiSentence
        case .done: return "Help › Set Up Helm… brings this back."
        }
    }
    /// The SF Symbol beside the step's name in the welcome step's list, and above the title of steps without an icon
    /// of their own.
    var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .access: return "hand.raised.fill"
        case .viewer: return "menubar.dock.rectangle"
        case .ai: return "sparkles"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// How far the onboarding got, kept in Settings as it goes, so a launch after a quit carries on where it stopped. A quit
/// is often macOS's own Quit & Reopen once Full Disk Access is switched on. Nothing here says whether a step is done:
/// Full Disk Access, the file viewer and AI mode are read from the Mac and Settings each time.
public struct OnboardingProgress: Equatable, Sendable {
    /// The step to show next.
    public var step: OnboardingStep
    /// The steps this onboarding shows, so the step indicator stays as it was.
    public var steps: [OnboardingStep]
    /// System Settings was opened at Full Disk Access from the onboarding.
    public var askedForAccess: Bool
    /// Helm was copied into Applications, and that copy was asked to carry on.
    public var moved: Bool

    public init(step: OnboardingStep, steps: [OnboardingStep], askedForAccess: Bool = false, moved: Bool = false) {
        self.step = step; self.steps = steps; self.askedForAccess = askedForAccess; self.moved = moved
    }

    /// "access:welcome,access,viewer,ai,done:asked,moved": names in lower case, commas and colons only.
    public var text: String {
        let flags = [askedForAccess ? "asked" : nil, moved ? "moved" : nil].compactMap { $0 }
        return [step.rawValue, steps.map(\.rawValue).joined(separator: ","), flags.joined(separator: ",")].joined(separator: ":")
    }

    /// Nil for empty or unreadable text, or a step that isn't among the steps.
    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let step = OnboardingStep(rawValue: parts[0]) else { return nil }
        let steps = parts[1].split(separator: ",").compactMap { OnboardingStep(rawValue: String($0)) }
        guard steps.contains(step), steps.first == .welcome, steps.last == .done, Set(steps).count == steps.count else { return nil }
        let flags = Set(parts[2].split(separator: ",").map(String.init))
        self.init(step: step, steps: steps, askedForAccess: flags.contains("asked"), moved: flags.contains("moved"))
    }
}
#endif
