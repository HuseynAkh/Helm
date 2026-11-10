// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private struct FixedOptionsCodec: ViewOptionsSerialization {
    func encode(_ value: ViewOptions) throws -> Data { Data([42]) }
    func decode(_ data: Data) throws -> ViewOptions { ViewOptions(viewMode: .list) }
}

final class PresentationViewOptionsTests: XCTestCase {
    func testDefaultsAndSchema() throws {
        let codec = JSONViewOptionsSerialization()
        let defaults = ViewOptions()
        XCTAssertEqual(defaults.viewMode, .grid)
        XCTAssertEqual(defaults.showColumns, [.name, .size, .dateModified, .kind])
        XCTAssertEqual(try codec.decode(Data("{}".utf8)), defaults)
        let custom = ViewOptions(viewMode: .list, sort: .init(field: .size, ascending: false), groupBy: .tag,
                                 iconSize: 150, showColumns: [.tags], textSize: 16)
        XCTAssertEqual(try codec.decode(codec.encode(custom)), custom)
        XCTAssertTrue(custom.showColumns.contains(.name))
        for value in ["{\"version\":2}", "{\"version\":0}", "{\"viewMode\":\"future\"}", "bad"] {
            XCTAssertThrowsError(try codec.decode(Data(value.utf8)))
        }
        let partial = try codec.decode(Data("{\"iconSize\":1,\"textSize\":100,\"showColumns\":[]}".utf8))
        XCTAssertEqual(partial.iconSize, 16); XCTAssertEqual(partial.textSize, 32)
        XCTAssertEqual(partial.showColumns, [.name])
        XCTAssertEqual(ViewOptions(iconSize: .infinity, textSize: .nan).iconSize, 96)
        XCTAssertEqual(ViewOptions(textSize: .nan).textSize, 12)
        XCTAssertEqual(ViewOptions(iconSize: 999).iconSize, 512)
    }
    func testLRUAndCanonicalIdentity() throws {
        let a = Location.directory(URL(fileURLWithPath: "/tmp/a"))
        let alias = Location.directory(URL(fileURLWithPath: "/tmp/x/../a"))
        var store = ViewOptionsStore(capacity: 2)
        let custom = ViewOptions(viewMode: .list)
        store.set(custom, for: a); store.set(custom, for: .recent)
        XCTAssertEqual(store.options(for: alias), custom)
        store.set(custom, for: .trash)
        XCTAssertEqual(store.locationsLeastRecentlyUsedFirst, [a, .trash])
        XCTAssertEqual(store.options(for: .recent), ViewOptions())
        XCTAssertEqual(store.count, 2)
        XCTAssertNotNil(try store.serialized(for: alias))
        XCTAssertNil(try store.serialized(for: .recent))
        let before = store.locationsLeastRecentlyUsedFirst
        XCTAssertThrowsError(try store.restore(Data("bad".utf8), for: a))
        XCTAssertEqual(store.locationsLeastRecentlyUsedFirst, before)
        XCTAssertEqual(store.options(for: a), custom)
        try store.restore(nil, for: a)
        XCTAssertEqual(store.options(for: a), ViewOptions())
        store.defaults = custom
        XCTAssertEqual(store.options(for: a), custom)
        var zero = ViewOptionsStore(capacity: -1)
        zero.set(custom, for: a); XCTAssertEqual(zero.count, 0)
    }
    func testInjectedSerialization() throws {
        var store = ViewOptionsStore()
        try store.restore(Data(), for: .recent, using: FixedOptionsCodec())
        XCTAssertEqual(store.options(for: .recent).viewMode, .list)
        XCTAssertEqual(try store.serialized(for: .recent, using: FixedOptionsCodec()), Data([42]))
    }
}
