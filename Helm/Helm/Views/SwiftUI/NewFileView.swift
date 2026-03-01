import SwiftUI

struct NewFileView: View {

    let directoryURL: URL
    let onCreateFile: (String) -> Void
    let onCreateFromTemplate: (URL) -> Void
    let onCancel: () -> Void

    @State private var fileName = "Untitled"
    @State private var templates: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New File")
                .font(.headline)

            HStack {
                Text("Name:")
                TextField("File name", text: $fileName)
            }

            if !templates.isEmpty {
                Divider()
                Text("From Template")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(templates, id: \.self) { template in
                            Button {
                                onCreateFromTemplate(template)
                            } label: {
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: template.path))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    Text(template.lastPathComponent)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreateFile(fileName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { loadTemplates() }
    }

    private func loadTemplates() {
        let templatesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Templates")
        guard FileManager.default.fileExists(atPath: templatesURL.path) else { return }

        templates = (try? FileManager.default.contentsOfDirectory(
            at: templatesURL,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
