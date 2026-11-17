import XCTest
import HelmCore
@testable import HelmAgent

/// The three tools a model is offered, and the only words it is given when one goes wrong.
final class AgentToolCatalogTests: XCTestCase {
    /// The tools as the design fixes them: the name, the description and the schema of each, in order.
    private static let fixed = #"""
    [
     {"name": "list_folder",
      "description": "List what is in a folder. Start with a root such as r1. Returns ids to use in the other tools.",
      "schema": {"type": "object", "additionalProperties": false, "required": ["folder", "depth", "after"],
       "properties": {
        "folder": {"type": "string", "description": "A root or folder id."},
        "depth": {"type": "integer", "description": "1 for this folder, 2 to 8 for levels below, 0 for all levels."},
        "after": {"type": "string", "description": "Empty, or the last id of the previous page."}}}},
     {"name": "find_items",
      "description": "Find items under a folder by name, kind, date or size. Names only; nothing is opened.",
      "schema": {"type": "object", "additionalProperties": false,
       "required": ["folder", "name_any", "kinds", "modified_from", "modified_to", "min_bytes", "max_bytes"],
       "properties": {
        "folder": {"type": "string", "description": "A root or folder id."},
        "name_any": {"type": "array", "items": {"type": "string"}, "description": "A name matches if it holds any of these. Empty for any name."},
        "kinds": {"type": "array", "items": {"type": "string", "enum": ["folder", "document", "pdf", "image", "video", "audio",
                  "text", "code", "spreadsheet", "presentation", "archive", "app", "font"]}},
        "modified_from": {"type": "string", "description": "YYYY-MM-DD or empty."},
        "modified_to": {"type": "string", "description": "YYYY-MM-DD or empty."},
        "min_bytes": {"type": "integer", "description": "0 for none."},
        "max_bytes": {"type": "integer", "description": "0 for none."}}}},
     {"name": "propose_changes",
      "description": "Show the person one plan of changes. Nothing changes until they press Apply. Use ids from listings. Each item may appear once. A renamed file keeps its extension.",
      "schema": {"type": "object", "additionalProperties": false,
       "required": ["new_folders", "moves", "copies", "renames", "trash"],
       "properties": {
        "new_folders": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["key", "parent", "name"],
          "properties": {"key": {"type": "string", "description": "n1, n2, and so on."},
                         "parent": {"type": "string", "description": "A folder id, or an earlier key."},
                         "name": {"type": "string", "description": "One folder name, no slashes and no extension."}}}},
        "moves": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["items", "all_in", "to"],
          "properties": {"items": {"type": "array", "items": {"type": "string"}},
                         "all_in": {"type": "string", "description": "A folder id, to take everything directly inside it; otherwise empty."},
                         "to": {"type": "string", "description": "A folder id or a new-folder key."}}}},
        "copies": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["items", "all_in", "to"],
          "properties": {"items": {"type": "array", "items": {"type": "string"}},
                         "all_in": {"type": "string", "description": "A folder id, to take everything directly inside it; otherwise empty."},
                         "to": {"type": "string", "description": "A folder id or a new-folder key."}}}},
        "renames": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["item", "name"],
          "properties": {"item": {"type": "string"}, "name": {"type": "string", "description": "The new name, with the same extension."}}}},
        "trash": {"type": "array", "items": {"type": "string"}}}}}
    ]
    """#

    private func fixedTools() throws -> [AgentJSON] {
        try XCTUnwrap(AgentJSON(data: Data(Self.fixed.utf8)).arrayValue)
    }

    func testThereAreThreeToolsInOrder() {
        XCTAssertEqual(AgentToolCatalog.all.map(\.name), ["list_folder", "find_items", "propose_changes"])
        // read_contents is a fourth, offered only while Read contents is on.
        XCTAssertEqual(AgentToolCatalog.names, ["list_folder", "find_items", "propose_changes", "read_contents"])
    }

    func testTheSchemasAreTheFixedOnes() throws {
        let fixed = try fixedTools()
        XCTAssertEqual(fixed.count, AgentToolCatalog.all.count)
        for (tool, expected) in zip(AgentToolCatalog.all, fixed) {
            XCTAssertEqual(tool.name, expected["name"]?.stringValue)
            XCTAssertEqual(tool.description, expected["description"]?.stringValue, tool.name)
            XCTAssertEqual(tool.schema, expected["schema"], tool.name)
            // The same bytes, too, so a request body built from the catalog never changes by itself.
            XCTAssertEqual(tool.schema.data(), try XCTUnwrap(expected["schema"]).data(), tool.name)
        }
    }

    func testEveryObjectRefusesUnknownPropertiesAndRequiresAllOfItsOwn() {
        func check(_ schema: AgentJSON, _ place: String) {
            guard let members = schema.objectValue else { return }
            if members["type"] == .string("object") {
                XCTAssertEqual(members["additionalProperties"], .bool(false), place)
                let properties = members["properties"]?.objectValue ?? [:]
                let required = (members["required"]?.arrayValue ?? []).compactMap(\.stringValue)
                XCTAssertEqual(Set(required), Set(properties.keys), place)
                XCTAssertEqual(required.count, Set(required).count, place)
                for (name, property) in properties { check(property, place + "." + name) }
            }
            if let items = members["items"] { check(items, place + "[]") }
        }
        for tool in AgentToolCatalog.all {
            XCTAssertEqual(tool.schema["type"], .string("object"), tool.name)
            check(tool.schema, tool.name)
        }
    }

    func testNoToolTakesAPathOrAnAddress() {
        // Items are named by ids Helm issued. The only free text is a new name, a name to look for and a date.
        let words = AgentToolCatalog.all.map { String(decoding: $0.schema.data(), as: UTF8.self).lowercased() }.joined()
        for banned in ["path", "url", "address", "command", "shell", "content"] {
            XCTAssertFalse(words.contains(banned), banned)
        }
        XCTAssertFalse(AgentToolCatalog.names.contains { $0.contains("delete") || $0.contains("run") || $0.contains("open") })
    }

    func testTheKindsAModelMayAskForAreTheOneKindTable() throws {
        let find = try XCTUnwrap(AgentToolCatalog.all.first { $0.name == "find_items" })
        let kinds = find.schema["properties"]?["kinds"]?["items"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(kinds, AISearchKind.allCases.map(\.rawValue))
        XCTAssertEqual(kinds?.count, 13)
    }

    func testTheCodesAModelIsGiven() {
        XCTAssertEqual(AgentToolCode.allCases.map(\.rawValue), [
            "unknown_tool", "bad_arguments", "unknown_id", "stale_id", "outside_scope", "not_found", "not_allowed", "hidden",
            "inside_package", "link", "not_downloaded", "not_loaded", "not_responding", "disconnected", "read_only", "no_trash",
            "name_not_allowed", "name_taken", "listed_twice", "too_many", "limit_reached", "in_use"
        ])
        // A code can be the failure of a Result, and travels as its own word.
        let refused: Result<Int, AgentToolCode> = .failure(.outside_scope)
        XCTAssertThrowsError(try refused.get()) { XCTAssertEqual($0 as? AgentToolCode, .outside_scope) }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([AgentToolCode.no_trash]), as: UTF8.self), #"["no_trash"]"#)
        XCTAssertEqual(try JSONDecoder().decode([AgentToolCode].self, from: Data(#"["stale_id"]"#.utf8)), [.stale_id])
    }

    func testAToolSpecIsAValue() {
        let spec = AgentToolSpec(name: "list_folder", description: "List.", schema: .object(["type": .string("object")]))
        XCTAssertEqual(spec, AgentToolSpec(name: "list_folder", description: "List.", schema: .object(["type": .string("object")])))
        XCTAssertEqual(Set(AgentToolCatalog.all).count, 3)
    }
}
