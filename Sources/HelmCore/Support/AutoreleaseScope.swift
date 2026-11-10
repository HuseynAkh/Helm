import Foundation

/// Bounds temporary Foundation objects during directory batches (F-035); Linux executes directly.
public enum AutoreleaseScope {
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }
}
