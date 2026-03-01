import Foundation

struct FileItemSort: Equatable {
    let field: Field
    let ascending: Bool
    let directoriesFirst: Bool

    enum Field: String, CaseIterable {
        case name
        case size
        case dateModified
        case kind
    }

    static let defaultSort = FileItemSort(field: .name, ascending: true, directoriesFirst: true)

    func toggling(field newField: Field) -> FileItemSort {
        if self.field == newField {
            return FileItemSort(field: newField, ascending: !ascending, directoriesFirst: directoriesFirst)
        }
        return FileItemSort(field: newField, ascending: true, directoriesFirst: directoriesFirst)
    }

    func compare(_ a: FileItem, _ b: FileItem) -> Bool {
        if directoriesFirst {
            if a.isDirectory && !b.isDirectory { return true }
            if !a.isDirectory && b.isDirectory { return false }
        }

        let result: Bool
        switch field {
        case .name:
            result = a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .size:
            result = a.size < b.size
        case .dateModified:
            result = a.modificationDate < b.modificationDate
        case .kind:
            let aKind = a.contentType?.localizedDescription ?? ""
            let bKind = b.contentType?.localizedDescription ?? ""
            result = aKind.localizedStandardCompare(bKind) == .orderedAscending
        }

        return ascending ? result : !result
    }

    func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted(by: compare)
    }
}
