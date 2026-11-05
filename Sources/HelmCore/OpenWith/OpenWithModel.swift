// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-062 default-association intent only; a platform adapter must validate types and obtain approval.
/// Mixed selections describe every selected item, never an inferred global type mutation.
public struct AlwaysOpenWithRequest: Equatable, Sendable {
    public let items: [ItemID]
    public let application: ApplicationChoice
    public init(items: [ItemID], application: ApplicationChoice) {
        self.items = items; self.application = application
    }
}

/// F-062 menu state preserves the ten-app limit and supports M20's mixed-selection intersection.
public struct OpenWithModel: Equatable, Sendable {
    public let items: [ItemID]
    public let defaultApplication: ApplicationChoice?
    public let applications: [ApplicationChoice]
    public var otherApplications: [ApplicationChoice] {
        applications.filter { $0.id != defaultApplication?.id }
    }
    /// The platform menu appends Other…; resolving this value never opens a picker or launches an app.
    public var offersOther: Bool { !items.isEmpty }
    public var menuApplications: [ApplicationChoice] { Array(applications.prefix(10)) }
    public init(items: [ItemID], defaultApplication: ApplicationChoice?, applications: [ApplicationChoice]) {
        var seenItems: Set<ItemID> = []
        self.items = items.filter { seenItems.insert($0).inserted }
        var seenApps: Set<URL> = []
        let unique = items.isEmpty ? [] : applications.filter { seenApps.insert($0.id).inserted }
        let selectedDefault = defaultApplication.flatMap { candidate in unique.first { $0.id == candidate.id } }
        self.defaultApplication = selectedDefault
        self.applications = selectedDefault.map { app in [app] + unique.filter { $0.id != app.id } } ?? unique
    }

    public static func resolve(items: [ItemID], using resolver: any ApplicationResolving) async throws -> OpenWithModel {
        var seen: Set<ItemID> = []
        let items = items.filter { seen.insert($0).inserted }
        var common: [ApplicationChoice] = []
        var sharedDefault: ApplicationChoice?
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let choices = try await resolver.applications(for: item)
            let defaultApp = try await resolver.defaultApplication(for: item)
            if index == 0 { common = choices; sharedDefault = defaultApp }
            else {
                let ids = Set(choices.map(\.id))
                common = common.filter { ids.contains($0.id) }
                if sharedDefault?.id != defaultApp?.id { sharedDefault = nil }
            }
        }
        try Task.checkCancellation()
        return OpenWithModel(items: items, defaultApplication: sharedDefault, applications: common)
    }
    public func alwaysOpenWith(_ application: ApplicationChoice) -> AlwaysOpenWithRequest? {
        guard !items.isEmpty, let choice = applications.first(where: { $0.id == application.id }) else { return nil }
        return AlwaysOpenWithRequest(items: items, application: choice)
    }
}
