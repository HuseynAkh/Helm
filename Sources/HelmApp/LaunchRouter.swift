// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmPersistence

/// Metadata is resolved outside this pure router; files reveal instead of launching apps (F-002).
public struct ExternalOpenRequest: Equatable, Sendable {
    public enum Kind: Sendable { case folder, file, unavailable }
    public let url: URL
    public let kind: Kind
    public init(url: URL, kind: Kind) { self.url = url; self.kind = kind }
}

/// Rejected requests remain visible to the delegate for its open reply (F-002, B-114).
public struct LaunchRoutingResult: Equatable, Sendable {
    public let windows: [WindowCreationRequest]
    public let rejectedRequests: [ExternalOpenRequest]
    public init(windows: [WindowCreationRequest], rejectedRequests: [ExternalOpenRequest] = []) {
        self.windows = windows; self.rejectedRequests = rejectedRequests
    }
}

/// Buffers cold opens until composition completes, avoiding duplicate Home windows (B-103, B-018).
public struct LaunchRouter: Sendable {
    public private(set) var isReady: Bool = false
    public private(set) var bufferedRequests: [ExternalOpenRequest] = []
    private var usedFrameNames: Set<String> = []
    public init() {}

    /// Before readiness, returns nil. Afterwards, returns explicit creation requests in input order.
    public mutating func receive(_ requests: [ExternalOpenRequest]) -> LaunchRoutingResult? {
        guard isReady else { bufferedRequests += requests; return nil }
        return route(requests)
    }

    /// Idempotent readiness prevents applicationDidFinishLaunching from creating windows twice.
    public mutating func finishLaunch(session: [SessionWindow], restoreSession: Bool, home: URL,
                                      isAvailableDirectory: (URL) -> Bool) -> LaunchRoutingResult {
        guard !isReady else { return LaunchRoutingResult(windows: []) }
        isReady = true
        if !bufferedRequests.isEmpty {
            let result = route(bufferedRequests)
            bufferedRequests.removeAll()
            return result
        }
        let saved = restoreSession ? session : []
        let windows = saved.isEmpty ? [SessionWindow(frameAutosaveName: "HelmMainWindow",
            tabs: [SessionTab(location: .directory(home))])] : saved
        let plan = SessionRestorePlan(windows: windows, home: home,
            isAvailableDirectory: isAvailableDirectory)
        usedFrameNames.formUnion(plan.windows.map(\.frameAutosaveName))
        return LaunchRoutingResult(windows: plan.windows)
    }

    private mutating func route(_ requests: [ExternalOpenRequest]) -> LaunchRoutingResult {
        var windows: [WindowCreationRequest] = []
        var rejected: [ExternalOpenRequest] = []
        for request in requests {
            guard request.url.isFileURL, request.kind != .unavailable else { rejected.append(request); continue }
            let url = request.url.standardizedFileURL
            let folder = request.kind == .folder ? url : url.deletingLastPathComponent()
            let tab = TabCreationRequest(tab: SessionTab(location: .directory(folder)),
                selectedURLs: request.kind == .file ? [url] : [])
            var ordinal = 1
            var frameName = SessionRestorePlan.frameName(ordinal: ordinal)
            while usedFrameNames.contains(frameName) {
                ordinal += 1; frameName = SessionRestorePlan.frameName(ordinal: ordinal)
            }
            usedFrameNames.insert(frameName)
            windows.append(WindowCreationRequest(frameAutosaveName: frameName, tabs: [tab]))
        }
        return LaunchRoutingResult(windows: windows, rejectedRequests: rejected)
    }
}
