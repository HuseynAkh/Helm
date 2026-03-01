import SwiftUI

struct PropertiesView: View {

    @ObservedObject var viewModel: PropertiesViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                if let icon = viewModel.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.fileName)
                        .font(.headline)
                        .lineLimit(2)
                    Text(viewModel.kind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Details
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // General
                    propertySection("General") {
                        propertyRow("Size", viewModel.size)
                        propertyRow("Location", viewModel.location)
                        propertyRow("Created", viewModel.createdDate)
                        propertyRow("Modified", viewModel.modifiedDate)
                        if !viewModel.contentType.isEmpty {
                            propertyRow("Type", viewModel.contentType)
                        }
                    }

                    // Image info
                    if let dimensions = viewModel.imageDimensions {
                        propertySection("Image") {
                            propertyRow("Dimensions", dimensions)
                        }
                    }

                    // Open with
                    if !viewModel.defaultApplication.isEmpty {
                        propertySection("Open With") {
                            propertyRow("Default", viewModel.defaultApplication)
                        }
                    }

                    // Permissions
                    if !viewModel.posixPermissions.isEmpty {
                        propertySection("Permissions") {
                            propertyRow("Owner", viewModel.ownerPermissions)
                            propertyRow("Group", viewModel.groupPermissions)
                            propertyRow("Others", viewModel.otherPermissions)
                            propertyRow("POSIX", viewModel.posixPermissions)
                        }
                    }

                    // Open parent folder
                    if let url = viewModel.fileURL {
                        Button("Show in Enclosing Folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 360, height: 480)
    }

    @ViewBuilder
    private func propertySection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }

    @ViewBuilder
    private func propertyRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal)
    }
}
