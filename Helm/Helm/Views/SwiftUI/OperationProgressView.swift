import SwiftUI

struct OperationProgressView: View {

    let operations: [OperationProgress]
    let onCancel: (UUID) -> Void

    var body: some View {
        if !operations.isEmpty {
            VStack(spacing: 8) {
                ForEach(operations.filter { !$0.isComplete }) { op in
                    HStack(spacing: 8) {
                        ProgressView(value: op.fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(op.kind.rawValue)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(op.currentFile)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            onCancel(op.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
