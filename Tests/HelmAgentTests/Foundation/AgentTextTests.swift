import XCTest
import HelmCore
@testable import HelmAgent

/// Every sentence AI mode shows, pinned word for word: curly quotes, the one-character ellipsis, the singular for
/// a count of 1 and the Mac's own number grouping.
final class AgentTextTests: XCTestCase {
    private typealias Row = (key: String, text: String, expected: String)

    /// One row a key: the member, called with plain values where it takes any, and the sentence it must give.
    private static let rows1: [Row] = [
        ("sparkTitle", AgentText.sparkTitle, "AI Panel"),
        ("sparkSetUp", AgentText.sparkSetUp, "Set Up AI Mode"),
        ("menuShowPanel", AgentText.menuShowPanel, "Show AI Panel"),
        ("menuHidePanel", AgentText.menuHidePanel, "Hide AI Panel"),
        ("foldersRowLabel", AgentText.foldersRowLabel, "Folders AI mode can use"),
        ("chipInICloud", AgentText.chipInICloud, "In iCloud Drive."),
        ("chipInProvider", AgentText.chipInProvider("Google Drive"), "In Google Drive."),
        ("chipInCloudFolder", AgentText.chipInCloudFolder, "In a cloud folder."),
        ("chipOnServer", AgentText.chipOnServer, "On a server."),
        ("chipOnExternal", AgentText.chipOnExternal, "On an external disk."),
        ("chipShared", AgentText.chipShared, "Shared"),
        ("chipReadOnly", AgentText.chipReadOnly, "Read-only"),
        ("chipNotResponding", AgentText.chipNotResponding, "Not responding"),
        ("chipRemove", AgentText.chipRemove("2026"), "Remove “2026”"),
        ("suggestOrganize", AgentText.suggestOrganize(214), "Organize 214 items"),
        ("suggestOrganizeSelected", AgentText.suggestOrganizeSelected(12), "Organize 12 selected"),
        ("depthThisFolder", AgentText.depthThisFolder, "This Folder"),
        ("depthTwoLevels", AgentText.depthTwoLevels, "2 Levels"),
        ("depthAllLevels", AgentText.depthAllLevels, "All Levels"),
        ("emptyFolder", AgentText.emptyFolder, "Nothing here to organize yet."),
        ("composerPlaceholder", AgentText.composerPlaceholder, "Ask, or type /add and a folder"),
        ("send", AgentText.send, "Send"),
        ("stop", AgentText.stop, "Stop"),
        ("modelMenuSettings", AgentText.modelMenuSettings, "AI Settings…"),
        ("noFolder", AgentText.noFolder, "Open a folder to use AI here."),
        ("folderRefused", AgentText.folderRefused, "Helm can't use AI in this folder."),
        ("openSettings", AgentText.openSettings, "Open Settings"),
        ("composerLooksLikeKey", AgentText.composerLooksLikeKey, "That looks like a key, so add it in Settings."),
        ("slashAdd", AgentText.slashAdd, "/add  Add a folder"),
        ("slashClear", AgentText.slashClear, "/clear  Start over"),
        ("statusReading", AgentText.statusReading(214), "Reading 214 names…"),
        ("statusThinking", AgentText.statusThinking, "Thinking…")
    ]
    private static let rows2: [Row] = [
        ("statusCheckingPlan", AgentText.statusCheckingPlan, "Checking the plan…"),
        ("statusStopping", AgentText.statusStopping, "Stopping…"),
        ("traceSent", AgentText.traceSent(names: 80, destination: "Ollama on this Mac"), "Sent 80 names to Ollama on this Mac."),
        ("noticeStopped", AgentText.noticeStopped, "Stopped."),
        ("noticeStartedOver", AgentText.noticeStartedOver, "Started over."),
        ("noticeFoldersNotLoaded", AgentText.noticeFoldersNotLoaded(3), "3 folders aren't loaded, so Helm skipped them."),
        ("noticeNotResponding", AgentText.noticeNotResponding("Server"), "“Server” isn't responding."),
        ("noticeDisconnected", AgentText.noticeDisconnected("Server"), "“Server” was disconnected."),
        ("addAdded", AgentText.addAdded("2026"), "Added “2026”."),
        ("addAlready", AgentText.addAlready("2026"), "“2026” is already added."),
        ("addFull", AgentText.addFull, "Remove a folder to add another."),
        ("addNotFound", AgentText.addNotFound, "Helm can't find that folder."),
        ("addRefused", AgentText.addRefused, "Helm can't add that folder."),
        ("serverConfirm", AgentText.serverConfirm("nas.local"), "Connect to “nas.local”?"),
        ("connect", AgentText.connect, "Connect"),
        ("planTitleOrganize", AgentText.planTitleOrganize("Downloads"), "Organize “Downloads”"),
        ("planTitleMove", AgentText.planTitleMove(12), "Move 12 Items"),
        ("planTitleCopy", AgentText.planTitleCopy(12), "Copy 12 Items"),
        ("planTitleRename", AgentText.planTitleRename(12), "Rename 12 Items"),
        ("planTitleTrash", AgentText.planTitleTrash(12), "Move 12 Items to Trash"),
        ("planTitleCreate", AgentText.planTitleCreate(2), "Create 2 Files"),
        ("countMoves", AgentText.countMoves(214), "214 moves"),
        ("countCopies", AgentText.countCopies(5), "5 copies"),
        ("countNewFolders", AgentText.countNewFolders(6), "6 new folders"),
        ("countNewFiles", AgentText.countNewFiles(2), "2 new files"),
        ("countRenames", AgentText.countRenames(3), "3 renames"),
        ("countTrash", AgentText.countTrash(2), "2 to Trash"),
        ("apply", AgentText.apply, "Apply"),
        ("cancel", AgentText.cancel, "Cancel"),
        ("tagNew", AgentText.tagNew, "New"),
        ("tagRenamed", AgentText.tagRenamed, "Renamed"),
        ("tagTrash", AgentText.tagTrash, "Trash"),
        ("tagKeepsBoth", AgentText.tagKeepsBoth, "Keeps both"),
        ("groupRenames", AgentText.groupRenames(30), "Rename 30 items"),
        ("groupMoves", AgentText.groupMoves(12, folder: "Images"), "Move 12 items to “Images”"),
        ("groupCopies", AgentText.groupCopies(12, folder: "Images"), "Copy 12 items to “Images”"),
        ("groupTrash", AgentText.groupTrash(12), "Move 12 items to the Trash"),
        ("groupNewFiles", AgentText.groupNewFiles(3, folder: "Trip"), "Create 3 files in “Trip”"),
        ("rowSize", AgentText.rowSize(1_234), "1.2 KB"),
        ("markGoesTo", AgentText.markGoesTo("Google Drive"), "Goes to Google Drive"),
        ("markLeaves", AgentText.markLeaves("iCloud Drive"), "Leaves iCloud Drive"),
        ("markCode", AgentText.markCode, "Code: check it before you apply it"),
        ("rowHolds", AgentText.rowHolds(37), "37 items"),
        ("noteNotAllowed", AgentText.noteNotAllowed(5), "5 changes weren't allowed, so Helm left them out."),
        ("noteNotDownloaded", AgentText.noteNotDownloaded(12), "12 items aren't downloaded, so Helm left them out.")
    ]
    private static let rows3: [Row] = [
        ("noteNoTrash", AgentText.noteNoTrash("Server"), "“Server” has no Trash, so Helm won't remove anything from it."),
        ("noteReadOnly", AgentText.noteReadOnly("Server"), "You can only view “Server”."),
        ("noteLeftOutSeveral", AgentText.noteLeftOutSeveral(17), "Helm left out 17 changes."),
        ("noteCantUndo", AgentText.noteCantUndo("Server"), "Copies on “Server” can't be undone."),
        ("noteSyncs", AgentText.noteSyncs, "Changes sync to your other devices."),
        ("noteShared", AgentText.noteShared("Server"), "Changes reach everyone who uses “Server”."),
        ("noteSyncsMaybeShared", AgentText.noteSyncsMaybeShared, "Changes sync to your devices and to anyone this is shared with."),
        ("planNothing", AgentText.planNothing, "Everything here is already in place."),
        ("planReplaced", AgentText.planReplaced, "Replaced by the plan below."),
        ("planDismissed", AgentText.planDismissed, "Plan dismissed."),
        ("planChanged", AgentText.planChanged, "This folder changed, so ask again."),
        ("applyMoving", AgentText.applyMoving(done: 3, total: 12, name: "a.png"), "Moving 3 of 12 · a.png"),
        ("applyCopying", AgentText.applyCopying(done: 3, total: 12, name: "a.png"), "Copying 3 of 12 · a.png"),
        ("applyRenaming", AgentText.applyRenaming(done: 3, total: 12, name: "a.png"), "Renaming 3 of 12 · a.png"),
        ("applyCreating", AgentText.applyCreating(done: 1, total: 2, name: "Notes.md"), "Creating 1 of 2 · Notes.md"),
        ("resultOrganized", AgentText.resultOrganized(items: 210, folders: 6), "Moved 210 items into 6 folders."),
        ("resultMoved", AgentText.resultMoved(12), "Moved 12 items."),
        ("resultCopied", AgentText.resultCopied(12), "Copied 12 items."),
        ("resultRenamed", AgentText.resultRenamed(12), "Renamed 12 items."),
        ("resultTrashed", AgentText.resultTrashed(12), "Moved 12 items to the Trash."),
        ("resultMadeFolders", AgentText.resultMadeFolders(6), "Made 6 new folders."),
        ("resultMadeFiles", AgentText.resultMadeFiles(3), "Made 3 new files."),
        ("resultPartial", AgentText.resultPartial(done: 210, total: 214, skipped: 4), "210 of 214 done, and 4 were skipped."),
        ("resultStopped", AgentText.resultStopped(done: 3, total: 12), "Stopped after 3 of 12."),
        ("undo", AgentText.undo, "Undo"),
        ("show", AgentText.show, "Show"),
        ("trashFailed", AgentText.trashFailed("a.png"), "“a.png” couldn't go to the Trash, and nothing was deleted."),
        ("undoDone", AgentText.undoDone, "Everything is back where it was."),
        ("undoRefused", AgentText.undoRefused, "These files changed, so Helm can't undo this."),
        ("busy", AgentText.busy, "Another change is running."),
        ("failNoKey", AgentText.failNoKey("Claude"), "Add a key in Settings to use Claude."),
        ("failKeyDenied", AgentText.failKeyDenied, "Helm needs your keychain to use this key."),
        ("failWrongKey", AgentText.failWrongKey, "That key didn't work."),
        ("failOutOfCredit", AgentText.failOutOfCredit("OpenAI"), "Your OpenAI account is out of credit."),
        ("failBusy", AgentText.failBusy("Gemini"), "Gemini is busy, so try again in a moment."),
        ("failNoSuchModel", AgentText.failNoSuchModel("Grok"), "Grok doesn't have that model."),
        ("failNoTools", AgentText.failNoTools, "This model can't work with files, so try another."),
        ("failUnreadable", AgentText.failUnreadable, "The model sent something Helm couldn't read."),
        ("failTooLarge", AgentText.failTooLarge, "That's a lot for one request, so try a smaller folder."),
        ("failUnreachable", AgentText.failUnreachable("Claude"), "Helm can't reach Claude right now."),
        ("failOllamaNotRunning", AgentText.failOllamaNotRunning, "Ollama isn't running."),
        ("failLMStudioNotRunning", AgentText.failLMStudioNotRunning, "Start the server in LM Studio."),
        ("failDeclined", AgentText.failDeclined, "The model declined this request.")
    ]
    private static let rows4: [Row] = [
        ("tryAgain", AgentText.tryAgain, "Try Again"),
        ("searchToggle", AgentText.searchToggle, "Find with AI"),
        ("searchPlaceholderFolder", AgentText.searchPlaceholderFolder("Downloads"), "Describe a file in Downloads"),
        ("searchPlaceholderMac", AgentText.searchPlaceholderMac, "Describe a file on this Mac"),
        ("searchHint", AgentText.searchHint("Claude"), "Return sends your words and matching file names to Claude."),
        ("searchThinking", AgentText.searchThinking, "Thinking…"),
        ("searchFailed", AgentText.searchFailed, "AI search isn't available."),
        ("searchOnThisMac", AgentText.searchOnThisMac, "Searched what's on this Mac."),
        ("searchNamesOnly", AgentText.searchNamesOnly, "Names only here."),
        ("searchLookedAt", AgentText.searchLookedAt(48), "Looked at 48"),
        ("searchCouldntLook", AgentText.searchCouldntLook(12, .timedOut, provider: "OpenAI"), "Couldn't look at 12: OpenAI took too long to answer"),
        ("searchReadingInside", AgentText.searchReadingInside, "Reading inside files…"),
        ("searchLooking", AgentText.searchLooking(34), "Looking at 34 files…"),
        ("searchTookTooLong", AgentText.searchTookTooLong("OpenAI"), "OpenAI took too long to answer."),
        ("searchKindRow", AgentText.searchKindRow, "File type"),
        ("searchKindAny", AgentText.searchKindAny, "Any"),
        ("searchKind(image)", AgentText.searchKind(.image), "Photo"),
        ("searchKind(video)", AgentText.searchKind(.video), "Video"),
        ("searchKind(document)", AgentText.searchKind(.document), "Document"),
        ("searchKind(folder)", AgentText.searchKind(.folder), "Folder"),
        ("searchKind(code)", AgentText.searchKind(.code), "Code"),
        ("searchKind(audio)", AgentText.searchKind(.audio), "Audio"),
        ("searchKind(archive)", AgentText.searchKind(.archive), "Archive"),
        ("searchKindShown(image)", AgentText.searchKindShown(.image), "Photos"),
        ("searchKindShown(video)", AgentText.searchKindShown(.video), "Videos"),
        ("searchKindShown(document)", AgentText.searchKindShown(.document), "Documents"),
        ("searchKindShown(folder)", AgentText.searchKindShown(.folder), "Folders"),
        ("searchKindShown(code)", AgentText.searchKindShown(.code), "Code"),
        ("searchKindShown(audio)", AgentText.searchKindShown(.audio), "Audio"),
        ("searchKindShown(archive)", AgentText.searchKindShown(.archive), "Archives"),
        ("aiTitle", AgentText.aiTitle, "AI Mode"),
        ("aiSentence", AgentText.aiSentence, "Ask Helm to organize, move and find files for you."),
        ("consent", AgentText.consent("Claude"), "Sends your requests and file names to Claude, never file contents."),
        ("destinationOnThisMac", AgentText.destinationOnThisMac("Ollama"), "Ollama on this Mac"),
        ("destinationNotSet", AgentText.destinationNotSet, "the address you enter"),
        ("providerLabel", AgentText.providerLabel, "Provider"),
        ("keyLabel", AgentText.keyLabel, "Key"),
        ("keyPlaceholder", AgentText.keyPlaceholder, "Paste your key"),
        ("done", AgentText.done, "Done"),
        ("setupHeader", AgentText.setupHeader, "Nothing leaves your Mac unless you turn on AI mode."),
        ("settingsAIMode", AgentText.settingsAIMode, "AI mode"),
        ("removeKey", AgentText.removeKey, "Remove Key"),
        ("keySaved", AgentText.keySaved, "Saved in your Mac's keychain."),
        ("stateChecking", AgentText.stateChecking, "Checking…"),
        ("stateConnected", AgentText.stateConnected, "Connected"),
        ("stateNoKey", AgentText.stateNoKey, "No key"),
        ("stateWrongKey", AgentText.stateWrongKey, "Wrong key"),
        ("stateCantReach", AgentText.stateCantReach("Ollama"), "Can't reach Ollama"),
        ("stateNoModels", AgentText.stateNoModels("Ollama"), "Ollama has no models yet."),
        ("portLabel", AgentText.portLabel, "Port"),
        ("addressLabel", AgentText.addressLabel, "Address"),
        ("addressPrompt", AgentText.addressPrompt, "https://"),
        ("addressNeedsHTTPS", AgentText.addressNeedsHTTPS, "Helm needs an https address."),
        ("addressOtherDevice", AgentText.addressOtherDevice, "Servers on other devices aren't supported yet."),
        ("modelLabel", AgentText.modelLabel, "Model"),
        ("modelPlaceholder", AgentText.modelPlaceholder, "Model name"),
        ("modelSeesPictures", AgentText.modelSeesPictures, "Sees pictures: with Read contents on, it gets small copies of them."),
        ("modelReadsTextOnly", AgentText.modelReadsTextOnly, "Reads text only: with Read contents on, Helm describes pictures to it in words."),
        ("aboutLine", AgentText.aboutLine, "An agentic file manager for your Mac.")
    ]
    /// The ChatGPT sign-in, Refresh Models and each provider's help.
    private static let rows5: [Row] = [
        ("refreshModels", AgentText.refreshModels, "Refresh Models"),
        ("continueWithChatGPT", AgentText.continueWithChatGPT, "Continue with ChatGPT"),
        ("useKeyInstead", AgentText.useKeyInstead, "Use an API key instead"),
        ("useChatGPTInstead", AgentText.useChatGPTInstead, "Use ChatGPT instead"),
        ("signInWaiting", AgentText.signInWaiting, "Continue in your browser."),
        ("signedInAs", AgentText.signedInAs("person@example.com"), "Signed in as person@example.com."),
        ("signedIn", AgentText.signedIn, "Signed in with ChatGPT."),
        ("removeSignIn", AgentText.removeSignIn, "Remove"),
        ("manageUsage", AgentText.manageUsage, "Manage usage"),
        ("signInDeclined", AgentText.signInDeclined, "ChatGPT plan use wasn't approved, so try again or use a key."),
        ("signInPlanOff", AgentText.signInPlanOff, "This sign-in doesn't allow ChatGPT plan use."),
        ("signInTimedOut", AgentText.signInTimedOut, "Sign-in took too long, so try again."),
        ("signInFailed", AgentText.signInFailed, "Sign-in didn't finish, so try again."),
        ("signInNoBrowser", AgentText.signInNoBrowser, "Helm couldn't open your browser."),
        ("signInUnavailable", AgentText.signInUnavailable, "Sign-in isn't available here."),
        ("signInFirst", AgentText.signInFirst, "Continue with ChatGPT to connect."),
        ("signOutUnconfirmed", AgentText.signOutUnconfirmed, "Disconnect Helm in ChatGPT's settings to finish."),
        ("planLimit", AgentText.planLimit, "You've reached your ChatGPT plan's usage limit."),
        ("statePlanNotCovered", AgentText.statePlanNotCovered, "Your ChatGPT plan can't be used with Helm."),
        ("failSignInAgain", AgentText.failSignInAgain, "Sign in with ChatGPT in Settings to use it."),
        ("failPlanNotCovered", AgentText.failPlanNotCovered, "Your ChatGPT plan doesn't cover this request."),
        ("signInPage", AgentText.signInPage, "You can close this tab and go back to Helm."),
        ("howToConnect", AgentText.howToConnect, "How to connect"),
        ("aboutProvider", AgentText.aboutProvider("Claude"), "About Claude"),
        ("helpClaude", AgentText.helpClaude, "Anthropic requires an API key for apps like Helm, billed by use."),
        ("helpChatGPT", AgentText.helpChatGPT, "Uses your ChatGPT plan, with no key to paste."),
        ("helpOpenAIKey", AgentText.helpOpenAIKey, "Uses an OpenAI API key, billed by use."),
        ("helpGemini", AgentText.helpGemini, "Uses a Gemini API key, with a free tier and paid use."),
        ("helpGrok", AgentText.helpGrok, "Uses an xAI API key, billed by use."),
        ("helpOllama", AgentText.helpOllama, "Free, and runs on this Mac while Ollama is running."),
        ("helpLMStudio", AgentText.helpLMStudio, "Free, and runs on this Mac while LM Studio's server is on."),
        ("helpOther", AgentText.helpOther, "Uses any OpenAI-compatible service at an https address, with its key if it needs one.")
    ]
    private static let rows: [Row] = rows1 + rows2 + rows3 + rows4 + rows5

    func testEverySentenceIsWordForWord() {
        for row in Self.rows {
            XCTAssertEqual(row.text, row.expected, row.key)
        }
        XCTAssertEqual(Self.rows.count, 211)
        XCTAssertEqual(Set(Self.rows.map(\.key)).count, 211, "a key is listed twice")
    }

    func testQuotesAreCurlyAndTheEllipsisIsOneCharacter() {
        for row in Self.rows {
            XCTAssertFalse(row.text.contains("\""), row.key)
            XCTAssertFalse(row.text.contains("..."), row.key)
            XCTAssertEqual(row.text.filter { $0 == "“" }.count, row.text.filter { $0 == "”" }.count, row.key)
        }
        XCTAssertEqual(AgentText.statusThinking, "Thinking\u{2026}")
        XCTAssertEqual(AgentText.chipRemove("a"), "Remove \u{201C}a\u{201D}")
        XCTAssertEqual(AgentText.resultStopped(done: 1, total: 2), "Stopped after 1 of 2.")
        XCTAssertEqual(AgentText.applyMoving(done: 1, total: 2, name: "a"), "Moving 1 of 2 \u{00B7} a")
    }

    func testNoExplanationIsLongerThanOneSentence() {
        for row in Self.rows {
            for end in [". ", "? ", "! "] {
                XCTAssertFalse(row.text.contains(end), row.key)
            }
        }
    }

    // MARK: Counts

    func testACountOfOneIsSingular() {
        XCTAssertEqual(AgentText.suggestOrganize(1), "Organize 1 item")
        XCTAssertEqual(AgentText.statusReading(1), "Reading 1 name…")
        XCTAssertEqual(AgentText.traceSent(names: 1, destination: "Claude"), "Sent 1 name to Claude.")
        XCTAssertEqual(AgentText.noticeFoldersNotLoaded(1), "1 folder isn't loaded, so Helm skipped it.")
        XCTAssertEqual(AgentText.countMoves(1), "1 move")
        XCTAssertEqual(AgentText.countCopies(1), "1 copy")
        XCTAssertEqual(AgentText.countNewFolders(1), "1 new folder")
        XCTAssertEqual(AgentText.countRenames(1), "1 rename")
        XCTAssertEqual(AgentText.countTrash(1), "1 to Trash")
        XCTAssertEqual(AgentText.planTitleMove(1), "Move 1 Item")
        XCTAssertEqual(AgentText.planTitleCopy(1), "Copy 1 Item")
        XCTAssertEqual(AgentText.planTitleRename(1), "Rename 1 Item")
        XCTAssertEqual(AgentText.planTitleTrash(1), "Move 1 Item to Trash")
        XCTAssertEqual(AgentText.planTitleCreate(1), "Create 1 File")
        XCTAssertEqual(AgentText.countNewFiles(1), "1 new file")
        XCTAssertEqual(AgentText.groupNewFiles(1, folder: "Trip"), "Create 1 file in “Trip”")
        XCTAssertEqual(AgentText.resultMadeFiles(1), "Made 1 new file.")
        XCTAssertEqual(AgentText.rowSize(1), "1 byte")
        XCTAssertEqual(AgentText.groupRenames(1), "Rename 1 item")
        XCTAssertEqual(AgentText.groupMoves(1, folder: "Images"), "Move 1 item to “Images”")
        XCTAssertEqual(AgentText.groupCopies(1, folder: "Images"), "Copy 1 item to “Images”")
        XCTAssertEqual(AgentText.groupTrash(1), "Move 1 item to the Trash")
        XCTAssertEqual(AgentText.rowHolds(1), "1 item")
        XCTAssertEqual(AgentText.noteNotAllowed(1), "1 change wasn't allowed, so Helm left it out.")
        XCTAssertEqual(AgentText.noteNotDownloaded(1), "1 item isn't downloaded, so Helm left it out.")
        XCTAssertEqual(AgentText.noteLeftOutSeveral(1), "Helm left out 1 change.")
        XCTAssertEqual(AgentText.resultOrganized(items: 1, folders: 1), "Moved 1 item into 1 folder.")
        XCTAssertEqual(AgentText.resultOrganized(items: 12, folders: 1), "Moved 12 items into 1 folder.")
        XCTAssertEqual(AgentText.resultMoved(1), "Moved 1 item.")
        XCTAssertEqual(AgentText.resultCopied(1), "Copied 1 item.")
        XCTAssertEqual(AgentText.resultRenamed(1), "Renamed 1 item.")
        XCTAssertEqual(AgentText.resultTrashed(1), "Moved 1 item to the Trash.")
        XCTAssertEqual(AgentText.resultMadeFolders(1), "Made 1 new folder.")
        XCTAssertEqual(AgentText.resultPartial(done: 9, total: 10, skipped: 1), "9 of 10 done, and 1 was skipped.")
        // A count that isn't 1 is plural, zero included.
        XCTAssertEqual(AgentText.suggestOrganize(0), "Organize 0 items")
        XCTAssertEqual(AgentText.suggestOrganize(2), "Organize 2 items")
        XCTAssertEqual(AgentText.countCopies(2), "2 copies")
    }

    func testCountsUseTheMacsNumberGrouping() {
        XCTAssertEqual(AgentText.number(1_240, locale: Locale(identifier: "en_US")), "1,240")
        XCTAssertEqual(AgentText.number(999, locale: Locale(identifier: "en_US")), "999")
        XCTAssertEqual(AgentText.number(1_234_567, locale: Locale(identifier: "en_US")), "1,234,567")
        XCTAssertEqual(AgentText.number(1_240, locale: Locale(identifier: "de_DE")), "1.240")
        // On this Mac, whatever its region is set to.
        let grouped = 1_240.formatted(.number)
        XCTAssertEqual(AgentText.number(1_240), grouped)
        XCTAssertEqual(AgentText.traceSent(names: 1_240, destination: "Claude"), "Sent \(grouped) names to Claude.")
        XCTAssertEqual(AgentText.suggestOrganize(1_240), "Organize \(grouped) items")
        XCTAssertEqual(AgentText.suggestOrganizeSelected(1_240), "Organize \(grouped) selected")
        XCTAssertEqual(AgentText.statusReading(1_240), "Reading \(grouped) names…")
        XCTAssertEqual(AgentText.countMoves(1_240), "\(grouped) moves")
        XCTAssertEqual(AgentText.planTitleMove(1_240), "Move \(grouped) Items")
        XCTAssertEqual(AgentText.applyCopying(done: 1_240, total: 1_240, name: "a"), "Copying \(grouped) of \(grouped) · a")
        XCTAssertEqual(AgentText.resultPartial(done: 1_240, total: 2_480, skipped: 1_240),
                       "\(grouped) of \(2_480.formatted(.number)) done, and \(grouped) were skipped.")
    }

    func testAFolderThatReachedTheCountingCapShowsAPlus() {
        let cap = 1_000.formatted(.number)
        XCTAssertEqual(AgentText.rowHolds(999), "999 items")
        XCTAssertEqual(AgentText.rowHolds(1_000), "\(cap)+ items")
        XCTAssertEqual(AgentText.rowHolds(50_000), "\(cap)+ items")
        XCTAssertEqual(AgentText.rowHolds(0), "0 items")
        XCTAssertEqual(AgentLimits.holdsCap, 1_000)
    }

    // MARK: Names

    func testNamesAreShownWithHiddenCharactersWrittenOut() {
        // A name that reads backwards, one with a line break and one with a character that takes no space.
        XCTAssertEqual(AgentText.addAdded("a\u{202E}gnp.exe"), "Added “a\\u{202E}gnp.exe”.")
        XCTAssertEqual(AgentText.planTitleOrganize("Down\nloads"), "Organize “Down\\u{A}loads”")
        XCTAssertEqual(AgentText.chipRemove("a\u{200B}b"), "Remove “a\\u{200B}b”")
        XCTAssertEqual(AgentText.noteNoTrash("Ser\u{7}ver"), "“Ser\\u{7}ver” has no Trash, so Helm won't remove anything from it.")
        XCTAssertEqual(AgentText.serverConfirm("nas\u{2028}.local"), "Connect to “nas\\u{2028}.local”?")
        XCTAssertEqual(AgentText.applyRenaming(done: 1, total: 2, name: "x\ty"), "Renaming 1 of 2 · x\\u{9}y")
        XCTAssertEqual(AgentText.consent("Clau\u{0}de"), "Sends your requests and file names to Clau\\u{0}de, never file contents.")
        // An ordinary name is shown as it is, accents and emoji included.
        XCTAssertEqual(AgentText.addAdded("Übersicht 写真 👨‍👩‍👧"), "Added “Übersicht 写真 👨‍👩‍👧”.")
        XCTAssertEqual(AgentText.groupMoves(2, folder: "Tax “2026”"), "Move 2 items to “Tax “2026””")
    }

    func testWhereRequestsGoIsSaidTheSameWayEverywhere() {
        XCTAssertEqual(AgentText.consent(AgentText.destinationOnThisMac("LM Studio")),
                       "Sends your requests and file names to LM Studio on this Mac, never file contents.")
        XCTAssertEqual(AgentText.traceSent(names: 80, destination: AgentText.destinationOnThisMac("Ollama")),
                       "Sent 80 names to Ollama on this Mac.")
        XCTAssertEqual(AgentText.searchHint("models.example.com"),
                       "Return sends your words and matching file names to models.example.com.")
    }

    func testEachSignInFailureHasItsLineButAStoppedOne() {
        for failure in AgentSignInFailure.allCases {
            XCTAssertEqual(AgentText.signInFailure(failure) == nil, failure == .cancelled, failure.rawValue)
        }
        XCTAssertEqual(AgentText.signInFailure(.unreachable), "Can't reach OpenAI")
    }

    func testEachProvidersHelpSaysWhatItUsesAndCostsInOneSentence() {
        for provider in AgentProviderID.allCases {
            for usesChatGPT in [false, true] {
                let line = AgentText.providerHelp(provider, usesChatGPT: usesChatGPT)
                XCTAssertTrue(line.hasSuffix("."), line)
                XCTAssertFalse([". ", "? ", "! "].contains { line.contains($0) }, line)
            }
        }
        XCTAssertEqual(AgentText.providerHelp(.openAI, usesChatGPT: true), AgentText.helpChatGPT)
        XCTAssertEqual(AgentText.providerHelp(.openAI, usesChatGPT: false), AgentText.helpOpenAIKey)
        XCTAssertEqual(AgentText.providerHelp(.claude, usesChatGPT: true), AgentText.helpClaude, "only OpenAI has a sign-in")
    }

    /// The kind row's words are one or two words each, and every kind the row offers has a word to choose it by and
    /// one for the status bar's line, each its own.
    func testTheKindRowsWordsAreShortAndEachItsOwn() {
        let words = [AgentText.searchKindRow, AgentText.searchKindAny] + AISearchKind.searchChoices.map(AgentText.searchKind)
            + AISearchKind.searchChoices.map(AgentText.searchKindShown)
        for word in words {
            XCTAssertTrue((1...2).contains(word.split(separator: " ").count), word)
            XCTAssertFalse(word.hasSuffix("."), word)
        }
        let choices = [AgentText.searchKindAny] + AISearchKind.searchChoices.map(AgentText.searchKind)
        XCTAssertEqual(choices, ["Any", "Photo", "Video", "Document", "Folder", "Code", "Audio", "Archive"])
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertEqual(Set(AISearchKind.allCases.map(AgentText.searchKind)).count, AISearchKind.allCases.count, "every kind has a word")
        XCTAssertEqual(Set(AISearchKind.allCases.map(AgentText.searchKindShown)).count, AISearchKind.allCases.count)
    }
}
