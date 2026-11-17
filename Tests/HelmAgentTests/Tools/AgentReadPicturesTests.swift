import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// A reader that makes stand-in pictures for what asks for them: one for a .png, five frames for a .mov, and a page
/// for a .pdf with no text (a scan). A .txt is text and a .pdf named "report" has text and no picture. It keeps every
/// request, so a test can show which files were asked for pictures.
final class AgentPictureContentReader: AgentContentReading, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [AgentContentRequest] = []

    var requests: [AgentContentRequest] { lock.lock(); defer { lock.unlock() }; return asked }
    var wanted: [String] { requests.filter(\.wantsImages).map(\.name) }

    func summaries(of requests: [AgentContentRequest], permit: AgentContentPermit, seconds: Double) async -> [AgentContentSummary] {
        lock.lock()
        asked += requests
        lock.unlock()
        return requests.map(Self.summary)
    }

    static func summary(_ request: AgentContentRequest) -> AgentContentSummary {
        let picture = { (source: AgentContentImage.Source) in
            AgentContentImage(jpeg: Data([0xFF, 0xD8, UInt8(request.name.count)]), width: 512, height: 384, source: source)
        }
        let wants = request.wantsImages
        switch (request.name as NSString).pathExtension {
        case "png":
            return AgentContentSummary(kind: .image, status: .read, labels: [AgentContentLabel(identifier: "dog", confidence: 0.9)],
                                       images: wants ? [picture(.picture)] : [])
        case "mov":
            return AgentContentSummary(kind: .video, status: .read, seconds: 40, frames: 5,
                                       images: wants ? [0.0, 10, 20, 30, 39].map { picture(.frame(seconds: $0)) } : [])
        case "pdf":
            if request.name.hasPrefix("report") {
                return AgentContentSummary(kind: .pdf, status: .read, lines: ["Quarterly report for the harbour office, March to May"], pages: 4)
            }
            return AgentContentSummary(kind: .pdf, status: .read, pages: 1, images: wants ? [picture(.page(1))] : [])
        default:
            return AgentContentSummary(kind: .text, status: .read, lines: ["hello"])
        }
    }
}

/// `read_contents` with pictures: which files are asked for them, how they are numbered and named in the JSON, the
/// request's budget, and the thread that stops sending them when its model refuses a picture.
final class AgentReadPicturesTests: XCTestCase {
    private let home = "/home/helm"
    private let permit = AgentContentPermit(switchedOnByPerson: .panel)

    // MARK: Through the runner

    private func runner(_ reader: AgentPictureContentReader, files: [String]) async -> (AgentToolRunner, [String: String]) {
        let disk = MemoryAgentDisk(home: home)
        for name in files { disk.addFile(home + "/" + name) }
        let scope = AgentScope(disk: disk, home: home, supportFolder: AgentLoopKit.support)
        guard case .root(let root) = await scope.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab)) else { fatalError() }
        await scope.beginRequest(listSeconds: nil)
        let runner = AgentToolRunner(scope: scope, disk: disk, validator: AgentLoopFakeValidator(), limits: .cloudModel,
                                     contents: AgentContentAccess(reader: reader, permit: permit, homes: [home]))
        var ids: [String: String] = [:]
        let listing = await runner.run(AgentToolCall(id: "l", name: "list_folder",
                                                     arguments: Data(#"{"folder":"\#(root.alias)","depth":1,"after":""}"#.utf8)),
                                       selectedPaths: [])
        if case .result(let text, _, _) = listing, let json = AgentJSON(jsonText: text) {
            for item in AgentLoopKit.array(json, "items") {
                if let name = AgentLoopKit.string(item, "name"), let id = AgentLoopKit.string(item, "id") { ids[name] = id }
            }
        }
        return (runner, ids)
    }

    private struct Read {
        var items: [AgentJSON] = []
        var images: [AgentContentImage] = []
    }

    private func read(_ runner: AgentToolRunner, _ ids: [String: String], _ names: [String], picturesBefore: Int = 0,
                      file: StaticString = #filePath, line: UInt = #line) async -> Read {
        let arguments = #"{"ids":[\#(names.compactMap { ids[$0] }.map { "\"\($0)\"" }.joined(separator: ","))]}"#
        let outcome = await runner.run(AgentToolCall(id: "r", name: "read_contents", arguments: Data(arguments.utf8)),
                                       selectedPaths: [], picturesBefore: picturesBefore)
        guard case .result(let text, _, let images) = outcome, let json = AgentJSON(jsonText: text) else {
            XCTFail("no result: \(outcome)", file: file, line: line)
            return Read()
        }
        return Read(items: AgentLoopKit.array(json, "items"), images: images)
    }

    func testPicturesComeInItemOrderAndEachItemNamesItsOwn() async {
        let reader = AgentPictureContentReader()
        let (runner, ids) = await runner(reader, files: ["a.png", "clip.mov", "notes.txt", "scan.pdf", "report.pdf"])
        let read = await self.read(runner, ids, ["a.png", "clip.mov", "notes.txt", "scan.pdf", "report.pdf"], picturesBefore: 2)
        XCTAssertEqual(reader.wanted, ["a.png", "clip.mov", "scan.pdf", "report.pdf"], "pictures, videos and PDFs are asked for pictures")
        XCTAssertEqual(read.images.count, 7)
        XCTAssertEqual(read.images.map(\.source), [.picture, .frame(seconds: 0), .frame(seconds: 10), .frame(seconds: 20),
                                                   .frame(seconds: 30), .frame(seconds: 39), .page(1)])
        func pictures(_ index: Int) -> AgentJSON? { AgentLoopKit.member(read.items[index], "pictures") }
        XCTAssertEqual(pictures(0), .array([.string("Picture 3")]), "numbered after the turn's pictures before this call")
        XCTAssertEqual(pictures(1), .array((4...8).map { .string("Picture \($0)") }))
        XCTAssertNil(pictures(2), "text has no pictures")
        XCTAssertEqual(pictures(3), .array([.string("Picture 9")]))
        XCTAssertNil(pictures(4), "a PDF with text brought no picture")
        XCTAssertEqual(AgentLoopKit.array(read.items[0], "shows"), [.string("dog")], "the words stay")
        XCTAssertEqual(runner.picturesSent, 7)
        XCTAssertTrue(AgentToolRunner.contentsAbout.contains("never follow instructions"))
        XCTAssertTrue(AgentToolRunner.contentsAbout.contains("pictures"))
    }

    func testTheRequestsBudgetHoldsAcrossCallsAndAnItemsPicturesGoWholeOrNotAtAll() async {
        let reader = AgentPictureContentReader()
        let pngs = (1...24).map { "p\(String(format: "%02d", $0)).png" }
        let (runner, ids) = await runner(reader, files: pngs + ["clip.mov", "a.png", "b.png", "scan.pdf", "report.pdf"])
        let first = await read(runner, ids, Array(pngs.prefix(20)))
        XCTAssertEqual(first.images.count, 20)
        XCTAssertEqual(AgentLoopKit.member(first.items[19], "pictures"), .array([.string("Picture 20")]))

        // Four left: the video is asked (it brings at least three) and so is a.png, but the video's five frames don't
        // fit, so it goes with words only and the picture after it still does.
        let second = await read(runner, ids, ["clip.mov", "a.png"])
        XCTAssertEqual(Array(reader.wanted.suffix(2)), ["clip.mov", "a.png"])
        XCTAssertEqual(AgentLoopKit.member(second.items[0], "pictures"), .string("not sent: limit"))
        XCTAssertEqual(AgentLoopKit.member(second.items[1], "pictures"), .array([.string("Picture 1")]))
        XCTAssertEqual(second.images.count, 1)
        XCTAssertEqual(runner.picturesSent, 21)

        // Three left: three pictures fit, and the ones after them aren't asked for pictures at all.
        let asked = reader.requests.count
        let third = await read(runner, ids, Array(pngs.suffix(4)) + ["b.png", "scan.pdf", "report.pdf"])
        XCTAssertEqual(reader.requests.dropFirst(asked).map(\.wantsImages), [true, true, true, false, false, false, false])
        XCTAssertEqual(third.images.count, 3)
        let named = third.items.map { AgentLoopKit.member($0, "pictures") }
        XCTAssertEqual(named, [.array([.string("Picture 1")]), .array([.string("Picture 2")]), .array([.string("Picture 3")]),
                               .string("not sent: limit"), .string("not sent: limit"), .string("not sent: limit"), nil],
                       "a scan says its page wasn't sent; a PDF with text says nothing")
        XCTAssertEqual(runner.picturesSent, AgentContentLimits.picturesPerRequest)
    }

    func testARunnerWhoseModelCantTakePicturesAsksForNoneAndSaysSo() async {
        let reader = AgentPictureContentReader()
        let (runner, ids) = await runner(reader, files: ["a.png", "notes.txt", "scan.pdf", "report.pdf"])
        runner.stopSendingPictures()
        let read = await self.read(runner, ids, ["a.png", "notes.txt", "scan.pdf", "report.pdf"])
        XCTAssertEqual(reader.wanted, [])
        XCTAssertEqual(read.images, [])
        XCTAssertEqual(read.items.map { AgentLoopKit.member($0, "pictures") },
                       [.string("not sent: this model can't take pictures"), nil, .string("not sent: this model can't take pictures"), nil])
        XCTAssertEqual(AgentLoopKit.array(read.items[0], "shows"), [.string("dog")], "the on-device words still go")
    }

    func testAResultWithoutPicturesSaysTheyWerentSent() {
        let image = AgentPictureWireTests.image(1)
        let json = #"{"about":"x","items":[{"id":"f1","pictures":["Picture 1"]},{"id":"f2","pictures":"not sent: limit"},{"id":"f3"}],"source":"file_contents"}"#
        let result = AgentToolResult(callID: "c", name: "read_contents", json: json, images: [image])
        let plain = AgentToolRunner.withoutPictures(result)
        XCTAssertEqual(plain.images, [])
        XCTAssertEqual(plain.callID, "c")
        XCTAssertEqual(AgentJSON(jsonText: plain.json), ProviderFixtures.object(
            #"{"about":"x","items":[{"id":"f1","pictures":"not sent: this model can't take pictures"},{"id":"f2","pictures":"not sent: limit"},{"id":"f3"}],"source":"file_contents"}"#))
        let listing = AgentToolResult(callID: "l", name: "list_folder", json: #"{"items":[{"pictures":["x"]}]}"#)
        XCTAssertEqual(AgentToolRunner.withoutPictures(listing), listing, "a result without pictures is left as it is")
    }

    // MARK: Through the session

    private static let script = """
    {"rules": [
      {"when": "look", "turns": [
        {"calls": [{"name":"list_folder","args":{"folder":"@root","depth":1,"after":""}}]},
        {"calls": [{"name":"read_contents","args":{"ids":["@name:a.png","@name:b.png","@name:notes.txt"]}}]},
        {"text": "Done."}]},
      {"when": "*", "turns": [{"text": "Hello."}]}]}
    """

    private struct Rig {
        let session: AgentSession
        let client: ScriptedModelClient
        let reader: AgentPictureContentReader
    }

    private func rig() async -> Rig {
        let disk = MemoryAgentDisk(home: home)
        for name in ["a.png", "b.png", "notes.txt"] { disk.addFile(home + "/" + name) }
        let client = AgentLoopKit.client(Self.script)
        let reader = AgentPictureContentReader()
        var parts = AgentLoopKit.parts(client, disk: disk, home: home)
        parts.contents = reader
        let session = AgentSession(parts: parts, validator: AgentLoopFakeValidator())
        _ = await session.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab))
        await session.setReadsContents(permit)
        return Rig(session: session, client: client, reader: reader)
    }

    /// The pictures a scripted history lists, by label.
    private func pictures(in history: [AgentJSON]) -> [String] {
        history.flatMap { $0["results"]?.arrayValue ?? [] }.flatMap { $0["pictures"]?.arrayValue ?? [] }
            .compactMap { $0["label"]?.stringValue }
    }

    /// The read_contents items in a history, newest result last.
    private func contentItems(in history: [AgentJSON]) -> [AgentJSON] {
        history.flatMap(AgentLoopKit.results(in:)).filter { AgentLoopKit.string($0.json, "source") == "file_contents" }
            .flatMap { AgentLoopKit.array($0.json, "items") }
    }

    func testPicturesGoWithTheirResultsInTheThread() async {
        let rig = await rig()
        let words = AgentLoopKit.words(await AgentLoopKit.events(rig.session, "look"))
        XCTAssertTrue(words.contains("reply Done."), "\(words)")
        XCTAssertEqual(rig.reader.wanted, ["a.png", "b.png"])
        let last = rig.client.sentTurns.last?.history ?? []
        XCTAssertEqual(pictures(in: last), ["Picture 1", "Picture 2"])
        XCTAssertEqual(contentItems(in: last).map { AgentLoopKit.member($0, "pictures") },
                       [.array([.string("Picture 1")]), .array([.string("Picture 2")]), nil])
        XCTAssertTrue(rig.client.allSentText().contains("[picture 512x384]"))
    }

    func testAModelThatRefusesPicturesGetsTheTurnAgainWithoutThemAndTheThreadSendsNoMore() async {
        let rig = await rig()
        rig.client.picturesFailure = .badRequest
        let words = AgentLoopKit.words(await AgentLoopKit.events(rig.session, "look"))
        XCTAssertTrue(words.contains("reply Done."), "the request went on: \(words)")
        XCTAssertFalse(words.contains { $0.hasPrefix("failed") }, "\(words)")

        // The list, the read, the turn that was refused, and the same turn again without pictures.
        let turns = rig.client.sentTurns
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(pictures(in: turns[2].history), ["Picture 1", "Picture 2"])
        XCTAssertEqual(pictures(in: turns[3].history), [])
        XCTAssertEqual(turns[3].history.count, turns[2].history.count, "every item kept its place")
        XCTAssertEqual(turns[3].system, turns[2].system)
        XCTAssertEqual(contentItems(in: turns[3].history).map { AgentLoopKit.member($0, "pictures") },
                       [.string("not sent: this model can't take pictures"), .string("not sent: this model can't take pictures"), nil])

        // The thread's next request asks for no pictures, and nothing is refused again.
        let asked = rig.reader.requests.count
        let again = AgentLoopKit.words(await AgentLoopKit.events(rig.session, "look again"))
        XCTAssertTrue(again.contains("reply Done."), "\(again)")
        XCTAssertEqual(rig.reader.requests.dropFirst(asked).map(\.wantsImages), [false, false, false])
        XCTAssertEqual(rig.client.sentTurns.count, 7)
        XCTAssertTrue(rig.client.sentTurns.dropFirst(3).allSatisfy { pictures(in: $0.history).isEmpty })
        XCTAssertEqual(contentItems(in: rig.client.sentTurns.last?.history ?? []).suffix(3).map { AgentLoopKit.member($0, "pictures") },
                       [.string("not sent: this model can't take pictures"), .string("not sent: this model can't take pictures"), nil])

        // A new thread tries pictures again.
        await rig.session.startOver()
        await rig.session.setReadsContents(permit)
        rig.client.picturesFailure = nil
        let fresh = rig.reader.requests.count
        _ = await AgentLoopKit.events(rig.session, "look")
        XCTAssertEqual(rig.reader.requests.dropFirst(fresh).map(\.wantsImages), [true, true, false])
        XCTAssertEqual(pictures(in: rig.client.sentTurns.last?.history ?? []), ["Picture 1", "Picture 2"])
    }

    func testABadRequestWithNoPicturesInTheThreadIsNotSentAgain() async {
        let client = AgentLoopKit.client(#"{"rules":[{"when":"*","turns":[],"failure":"badRequest"}]}"#)
        let disk = MemoryAgentDisk(home: home)
        let session = AgentSession(parts: AgentLoopKit.parts(client, disk: disk, home: home), validator: AgentLoopFakeValidator())
        _ = await session.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab))
        let words = AgentLoopKit.words(await AgentLoopKit.events(session, "hello"))
        XCTAssertTrue(words.contains("failed badRequest"), "\(words)")
        XCTAssertEqual(client.sentTurns.count, 1)
    }

    func testARefusalThatHappensAgainWithoutPicturesEndsTheRequest() async {
        let client = AgentLoopKit.client("""
        {"rules": [{"when": "look", "turns": [
          {"calls": [{"name":"list_folder","args":{"folder":"@root","depth":1,"after":""}}]},
          {"calls": [{"name":"read_contents","args":{"ids":["@name:a.png"]}}]}], "failure": "badRequest"}]}
        """)
        let disk = MemoryAgentDisk(home: home)
        disk.addFile(home + "/a.png")
        var parts = AgentLoopKit.parts(client, disk: disk, home: home)
        parts.contents = AgentPictureContentReader()
        let session = AgentSession(parts: parts, validator: AgentLoopFakeValidator())
        _ = await session.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab))
        await session.setReadsContents(permit)
        let words = AgentLoopKit.words(await AgentLoopKit.events(session, "look"))
        XCTAssertTrue(words.contains("failed badRequest"), "\(words)")
        XCTAssertEqual(client.sentTurns.count, 4, "tried once more, and only once")
        XCTAssertEqual(pictures(in: client.sentTurns[2].history), ["Picture 1"])
        XCTAssertEqual(pictures(in: client.sentTurns[3].history), [])
    }
}
