// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmOperations

/// F-052 conflict choice is explicit; keep-both remains the default and replacement never merges.
public struct ConflictSheet: View {
    private let conflict: Conflict
    @Binding private var applyToAll: Bool
    private let choose: (ConflictResolution, Bool) -> Void
    public init(conflict: Conflict, applyToAll: Binding<Bool>,
                choose: @escaping (ConflictResolution, Bool) -> Void) {
        self.conflict = conflict; _applyToAll = applyToAll; self.choose = choose
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("An item named “\(conflict.destination.lastPathComponent)” already exists.").font(.headline)
            if let source = conflict.source { Text("Source: \(source.path)").textSelection(.enabled) }
            Text("Destination: \(conflict.destination.path)").textSelection(.enabled)
            Text("Replace replaces the existing item. Folders are not merged.").font(.caption)
            Toggle("Apply to All", isOn: $applyToAll)
            HStack {
                Button("Stop") { choose(.stop, applyToAll) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { choose(.skip, applyToAll) }
                Button("Replace") { choose(.replace, applyToAll) }
                Button("Keep Both") { choose(.keepBoth, applyToAll) }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500)
    }
}
