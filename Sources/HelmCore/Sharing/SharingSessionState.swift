// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Host presentation intents only; no sending or recipient discovery lives in Core (F-063).
public enum SharingEffect: Equatable, Sendable {
    case presentFilePicker(UUID), presentPicker(SharingRequest), dismiss(UUID)
}
/// A provider's acceptance is not delivery; callbacks are admitted once per request (F-063).
public enum SharingOutcome: Equatable, Sendable {
    case accepted, cancelled, failed(SharingFailure), providerReportedCompletion
}
/// Explicit invocation captures selection; owner close permanently retires the session (F-063).
public struct SharingSessionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, choosingFiles, presentingPicker, accepted, cancelled
        case failed(SharingFailure), providerReportedCompletion, closed
    }
    public private(set) var request: SharingRequest?
    public private(set) var phase: Phase = .idle
    public init() {}

    public mutating func invoke(kind: SharingKind, selection: SharingSelectionSnapshot,
                                capability: SharingCapability) -> [SharingEffect] {
        guard phase != .closed, !isActive else { return [] }
        let request = SharingRequest(kind: kind, selection: selection)
        self.request = request
        guard capability.supports(kind) else { phase = .failed(.unsupported); return [] }
        if selection.urls.isEmpty {
            phase = .choosingFiles
            return [.presentFilePicker(request.id)]
        }
        phase = .presentingPicker
        return [.presentPicker(request)]
    }

    /// The file picker is the only way an empty invocation can acquire its selection.
    public mutating func pickedFiles(requestID: UUID, selection: SharingSelectionSnapshot,
                                     capability: SharingCapability) -> [SharingEffect] {
        guard let current = request, current.id == requestID, phase == .choosingFiles else { return [] }
        guard !selection.urls.isEmpty else { phase = .cancelled; return [] }
        guard capability.supports(current.kind) else { phase = .failed(.unsupported); return [] }
        // Retire the picker identity, so duplicate file-picker callbacks cannot target the provider.
        let next = SharingRequest(kind: current.kind, selection: selection)
        request = next
        phase = .presentingPicker
        return [.presentPicker(next)]
    }

    @discardableResult
    public mutating func receive(requestID: UUID, outcome: SharingOutcome) -> Bool {
        guard request?.id == requestID, isActive else { return false }
        switch outcome {
        case .accepted:
            guard phase == .presentingPicker else { return false }
            phase = .accepted
        case .providerReportedCompletion:
            guard phase == .presentingPicker || phase == .accepted else { return false }
            phase = .providerReportedCompletion
        case .cancelled: phase = .cancelled
        case .failed(let failure): phase = .failed(failure)
        }
        return true
    }

    public mutating func close() -> [SharingEffect] {
        let effects: [SharingEffect] = isActive ? request.map { [.dismiss($0.id)] } ?? [] : []
        phase = .closed
        return effects
    }

    private var isActive: Bool {
        phase == .choosingFiles || phase == .presentingPicker || phase == .accepted
    }
}
