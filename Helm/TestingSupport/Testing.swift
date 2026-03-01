import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TestFailure: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public enum Check {
    public static func isTrue(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure(message)
        }
    }

    public static func equal<T: Equatable>(
        _ lhs: @autoclosure () -> T,
        _ rhs: @autoclosure () -> T,
        _ message: String
    ) throws {
        let left = lhs()
        let right = rhs()
        if left != right {
            throw TestFailure("\(message) | left=\(left) right=\(right)")
        }
    }

    public static func notNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
        if value() == nil {
            throw TestFailure(message)
        }
    }
}

public enum TestRuntime {
    public typealias AsyncTest = @Sendable () async throws -> Void

    struct Entry {
        let name: String
        let run: AsyncTest
    }

    private static let lock = NSLock()
    private static var entries: [Entry] = []

    public static func register(_ name: String, run: @escaping AsyncTest) {
        lock.withLock {
            entries.append(Entry(name: name, run: run))
        }
    }

    static func snapshot() -> [Entry] {
        lock.withLock {
            entries
        }
    }
}

@_silgen_name("helm_register_tests")
private func helm_register_tests()

public func __swiftPMEntryPoint() async -> Never {
    helm_register_tests()

    let tests = TestRuntime.snapshot()
    print("Running \(tests.count) tests")

    var failures = 0
    for test in tests {
        do {
            try await test.run()
            print("PASS: \(test.name)")
        } catch {
            failures += 1
            print("FAIL: \(test.name)")
            print("  \(error)")
        }
    }

    print("Finished. Passed: \(tests.count - failures), Failed: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
