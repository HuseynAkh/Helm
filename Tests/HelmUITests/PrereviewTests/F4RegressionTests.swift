// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

final class F4RegressionTests: XCTestCase {
    func testSearchAdapterTypechecksAgainstCurrentCore() throws {
#if os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-typecheck", "-swift-version", "5", "-I",
            "/tmp/build-F4/debug/Modules", "Sources/HelmUI/SearchBar/SearchBarModel.swift"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
#endif
    }
    func testValidationPresentationIsBoundedWithoutDiscardingIssues() {
        var model = BatchRenameViewModel(items: (0..<100).map { URL(fileURLWithPath: "/a/file\($0)") },
            existingNames: [:], caseSensitive: true, date: Date(), timeZone: .current)
        model.prepend = "/"
        XCTAssertEqual(model.plan?.issues.count, 100)
        XCTAssertLessThanOrEqual(model.validationMessages.count, 21)
        XCTAssertFalse(model.canRename)
    }
    // Source regression is intentional: SwiftUI cannot be hosted on Linux. Functional
    // paging/cache tests supplement this check; macOS rendering measurements remain required.
    func testCollapsedDisclosureDoesNotReadEagerDetails() throws {
        let source = try String(contentsOfFile: "Sources/HelmUI/Operations/OperationsPanel.swift")
        XCTAssertFalse(source.contains("!row.details.isEmpty"))
        XCTAssertFalse(source.contains("Array(row.details.enumerated())"))
    }
}
