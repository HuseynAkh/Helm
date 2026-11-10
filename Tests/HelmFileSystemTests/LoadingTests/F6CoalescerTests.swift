// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit

final class F6CoalescerTests: XCTestCase {
    func testUnavailableRecoveryAndRootPriority() async {
        for rootFirst in [false, true] {
            let clock = FakeClock()
            let generation = Generation()
            let coalescer = DirectoryReloadCoalescer(generation: generation, clock: clock)
            if rootFirst { await coalescer.receive(.rootChanged) }
            await coalescer.receive(.unavailable(.timedOut))
            var iterator = coalescer.actions.makeAsyncIterator()
            guard let action = await iterator.next() else { return XCTFail("Missing event") }
            let root = URL(fileURLWithPath: "/a")
            let state = TabState(location: .directory(root), homeDirectory: root)
            let effects = TabReducer.reduce(state, action, context: ReducerContext(now: clock.now(), homeDirectory: root)).1
            XCTAssertTrue(effects.contains(.validateNavigation(state.location, generation)))
            if rootFirst {
                guard case .monitorEvent(_, .rootChanged) = action else { return XCTFail("Error demoted root validation") }
            }
            if rootFirst { await coalescer.acknowledgeRootValidation() }
            await coalescer.receive(.changed(paths: ["/a/new"]))
            clock.advance(by: 1)
            await coalescer.flush()
            await coalescer.finish()
            guard let recovered = await iterator.next() else { return XCTFail("Missing recovery") }
            do {
                let recoveredEffects = TabReducer.reduce(state, recovered, context: ReducerContext(now: clock.now(), homeDirectory: root)).1
                XCTAssertTrue(recoveredEffects.contains(.refreshPaths([], generation)))
            }
        }
    }
}
