import Foundation
import HelmCore

/// The tools a model is offered, in the order it is told about them. There are three: two that look and one that
/// proposes. None takes a path or an address: existing items are named by ids Helm issued, and only new names are
/// written as text. Every schema refuses unknown properties and requires every property; the empty string, the
/// empty array and 0 mean "none".
public enum AgentToolCatalog {
    public static let all: [AgentToolSpec] = [listFolder, findItems, proposeChanges]
    /// The names of the tools. A tool's name from a model is shown, and run, only when it is one of these.
    public static let names: Set<String> = Set(all.map(\.name))

    private static let listFolder = AgentToolSpec(
        name: "list_folder",
        description: "List what is in a folder. Start with a root such as r1. Returns ids to use in the other tools.",
        schema: record(required: ["folder", "depth", "after"], [
            "folder": text("A root or folder id."),
            "depth": integer("1 for this folder, 2 to 8 for levels below, 0 for all levels."),
            "after": text("Empty, or the last id of the previous page.")
        ]))

    private static let findItems = AgentToolSpec(
        name: "find_items",
        description: "Find items under a folder by name, kind, date or size. Names only; nothing is opened.",
        schema: record(required: ["folder", "name_any", "kinds", "modified_from", "modified_to", "min_bytes", "max_bytes"], [
            "folder": text("A root or folder id."),
            "name_any": list(of: text(), "A name matches if it holds any of these. Empty for any name."),
            "kinds": list(of: .object(["type": .string("string"),
                                       "enum": .array(AISearchKind.allCases.map { .string($0.rawValue) })])),
            "modified_from": text("YYYY-MM-DD or empty."),
            "modified_to": text("YYYY-MM-DD or empty."),
            "min_bytes": integer("0 for none."),
            "max_bytes": integer("0 for none.")
        ]))

    private static let proposeChanges = AgentToolSpec(
        name: "propose_changes",
        description: "Show the person one plan of changes. Nothing changes until they press Apply. Use ids from listings. "
            + "Each item may appear once. A renamed file keeps its extension.",
        schema: record(required: ["new_folders", "moves", "copies", "renames", "trash"], [
            "new_folders": list(of: record(required: ["key", "parent", "name"], [
                "key": text("n1, n2, and so on."),
                "parent": text("A folder id, or an earlier key."),
                "name": text("One folder name, no slashes and no extension.")
            ])),
            "moves": list(of: transfer),
            "copies": list(of: transfer),
            "renames": list(of: record(required: ["item", "name"], [
                "item": text(),
                "name": text("The new name, with the same extension.")
            ])),
            "trash": list(of: text())
        ]))

    /// What a move and a copy both take: items by id, or everything directly inside one folder, and where they go.
    private static let transfer = record(required: ["items", "all_in", "to"], [
        "items": list(of: text()),
        "all_in": text("A folder id, to take everything directly inside it; otherwise empty."),
        "to": text("A folder id or a new-folder key.")
    ])

    // MARK: Schema parts

    private static func text(_ description: String? = nil) -> AgentJSON { typed("string", description) }
    private static func integer(_ description: String? = nil) -> AgentJSON { typed("integer", description) }

    private static func typed(_ type: String, _ description: String?) -> AgentJSON {
        var members: [String: AgentJSON] = ["type": .string(type)]
        if let description { members["description"] = .string(description) }
        return .object(members)
    }

    private static func list(of items: AgentJSON, _ description: String? = nil) -> AgentJSON {
        var members: [String: AgentJSON] = ["type": .string("array"), "items": items]
        if let description { members["description"] = .string(description) }
        return .object(members)
    }

    /// An object that takes exactly the properties listed, all of them required.
    private static func record(required: [String], _ properties: [String: AgentJSON]) -> AgentJSON {
        .object(["type": .string("object"), "additionalProperties": .bool(false),
                 "required": .array(required.map(AgentJSON.string)), "properties": .object(properties)])
    }
}

/// The only words a model is ever given for something that went wrong with a tool. Never a message from the
/// system, since those carry whole paths. A code is an error too, so it can be the failure of a `Result`.
public enum AgentToolCode: String, Error, Sendable, Codable, CaseIterable {
    case unknown_tool, bad_arguments, unknown_id, stale_id, outside_scope, not_found, not_allowed, hidden, inside_package
    case link, not_downloaded, not_loaded, not_responding, disconnected, read_only, no_trash, name_not_allowed,
         name_taken, listed_twice, too_many, limit_reached, in_use
}
