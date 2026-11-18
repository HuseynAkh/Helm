import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmUI

/// A folder's Contents and a package's Size come from the count, while it runs and once it's done, and say what
/// wasn't counted and why.
final class F18PropertiesAdapterTests: XCTestCase {
    private let folder = FileEntry(url: URL(fileURLWithPath: "/home/pat/Projects"), kind: .directory, size: 4096,
                                   localizedKindDescription: "Folder")
    private let package = FileEntry(url: URL(fileURLWithPath: "/Applications/Tool.app"), kind: .package, size: 4096)

    private func count(files: Int = 0, folders: Int = 0, bytes: Int64 = 0, unreadable: Int = 0, cloud: Int = 0) -> FolderContentsCount {
        var count = FolderContentsCount()
        count.files = files; count.folders = folders; count.bytes = bytes; count.unreadable = unreadable; count.notDownloaded = cloud
        return count
    }
    private func row(_ model: PropertiesViewModel, _ label: String) -> PropertiesRow? { model.generalRows.first { $0.label == label } }

    func testAFolderSaysWhatsInsideAsItsCountedAndOnceItsDone() {
        let home = URL(fileURLWithPath: "/home/pat")
        let before = PropertiesViewModel(entries: [folder], counting: true, home: home)
        XCTAssertEqual(row(before, "Contents"), PropertiesRow("Contents", "Counting…", isWorking: true))
        XCTAssertEqual(row(before, "Parent Folder")?.value, "~")
        let partway = PropertiesViewModel(entries: [folder], contents: count(files: 1_200, folders: 4, bytes: 2_100_000_000), counting: true)
        XCTAssertEqual(row(partway, "Contents")?.value, "1,204 items, totalling 2.1 GB so far")
        XCTAssertEqual(row(partway, "Contents")?.isWorking, true)
        let done = PropertiesViewModel(entries: [folder], contents: count(files: 11, folders: 1, bytes: 3_400_000))
        XCTAssertEqual(row(done, "Contents"), PropertiesRow("Contents", "12 items, totalling 3.4 MB"))
        XCTAssertNil(row(done, "Size"))
        let one = PropertiesViewModel(entries: [folder], contents: count(files: 1, bytes: 5))
        XCTAssertEqual(row(one, "Contents")?.value, "1 item, totalling 5 bytes")
    }

    func testEmptyUnreadableAndCloudFoldersSaySo() {
        XCTAssertEqual(row(PropertiesViewModel(entries: [folder], contents: count()), "Contents")?.value, "Empty")
        XCTAssertEqual(row(PropertiesViewModel(entries: [folder], contents: count(unreadable: 1)), "Contents")?.value, "Couldn’t be read")
        let away = row(PropertiesViewModel(entries: [folder], contents: count(cloud: 1)), "Contents")
        XCTAssertEqual(away?.value, "Not on this Mac")
        XCTAssertEqual(away?.note?.contains("nothing that would need downloading"), true)
        let partial = row(PropertiesViewModel(entries: [folder], contents: count(files: 3, folders: 2, bytes: 10, unreadable: 2, cloud: 1)), "Contents")
        XCTAssertEqual(partial?.note, "2 folders inside couldn’t be read, so what’s in them isn’t counted. "
                       + "1 folder kept in the cloud isn’t on this Mac, so what’s in it isn’t counted.")
    }

    func testAPackagesSizeIsWhatsInsideIt() {
        XCTAssertEqual(row(PropertiesViewModel(entries: [package], counting: true), "Size")?.value, "Counting…")
        let done = PropertiesViewModel(entries: [package], contents: count(files: 40, folders: 6, bytes: 200_000_000))
        XCTAssertEqual(row(done, "Size")?.value, "200 MB")
        XCTAssertNil(row(done, "Contents"))
        let file = FileEntry(url: URL(fileURLWithPath: "/file"), size: 3_412_345)
        XCTAssertEqual(row(PropertiesViewModel(entries: [file]), "Size")?.value, "3.4 MB (3,412,345 bytes)")
    }

    func testSeveralItemsSayHowManyOfEachAndWhatsInsideTheFolders() {
        let file = FileEntry(url: URL(fileURLWithPath: "/home/pat/a.txt"), size: 5)
        let model = PropertiesViewModel(entries: [file, folder], contents: count(files: 3, folders: 1, bytes: 35), counting: false)
        XCTAssertEqual(row(model, "Selected")?.value, "1 file, 1 folder")
        XCTAssertEqual(row(model, "Size"), PropertiesRow("Size", "35 bytes", note: "With 3 items inside the folders."))
        XCTAssertEqual(row(model, "Parent Folder")?.value, "/home/pat")
    }
}
