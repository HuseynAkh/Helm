// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import SwiftUI

/// Read-only F-050 Properties; host owns enrichment, reveal and dismissal (B-066/B-117).
public struct PropertiesView: View {
    private let model: PropertiesViewModel
    private let reveal: ([URL]) -> Void
    private let dismiss: () -> Void
    public init(model: PropertiesViewModel, reveal: @escaping ([URL]) -> Void, dismiss: @escaping () -> Void) {
        self.model = model; self.reveal = reveal; self.dismiss = dismiss
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.headline).lineLimit(2)
                Text(model.kind).font(.subheadline).foregroundStyle(.secondary)
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("General") {
                        row("Size", model.size)
                        if model.entries.count > 1 {
                            row("Items", "\(model.aggregate.fileCount) files, \(model.aggregate.directoryCount) folders")
                        }
                        row("Location", model.location)
                        row("Created", model.created)
                        row("Modified", model.modified)
                        row("Type", model.contentType)
                        row("Locked", model.supplement.locked.map { $0 ? "Yes" : "No" } ?? "Unavailable")
                    }
                    if let dimensions = model.supplement.imageDimensions {
                        section("Image") { row("Dimensions", dimensions) }
                    }
                    if let application = model.supplement.defaultApplication {
                        section("Open With") { row("Default", application) }
                    }
                    section("Permissions") {
                        ForEach(Array(model.permissionRows.enumerated()), id: \.offset) { _, value in
                            row(value.0, value.1)
                        }
                        row("ACL", model.supplement.acl ?? "Unavailable")
                        Text("Permissions, ACLs, name, extension and lock state are read-only.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    Button("Show in Enclosing Folder") { reveal(model.entries.map(\.url)) }
                        .disabled(model.entries.isEmpty).padding(.horizontal)
                }.padding(.vertical)
            }
            Divider()
            HStack { Spacer(); Button("Done", action: dismiss).keyboardShortcut(.cancelAction) }.padding()
        }.frame(width: 360, height: 480)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary).padding(.horizontal)
            content()
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            // MAC-VERIFY: selectable text and wrapping in narrow hosted Properties sheet.
            Text(value).textSelection(.enabled)
            Spacer()
        }.font(.system(size: 12)).padding(.horizontal)
    }
}
