import Foundation
import HelmCore

/// Every sentence AI mode shows the person, in one place. The windows and panes use these members and never write
/// one of the sentences themselves, so the wording can't drift between two screens.
///
/// A count is written with the Mac's own number grouping, and in the singular when it is 1. A name from the disk,
/// a place or a host is passed through `AgentTextEscaper` here, so a hidden character in one can't change how a line
/// reads. Nothing here is ever built from a model's text.
public enum AgentText {
    // MARK: Header and menus

    public static let sparkTitle = "AI Panel"
    public static let sparkSetUp = "Set Up AI Mode"
    public static let menuShowPanel = "Show AI Panel"
    public static let menuHidePanel = "Hide AI Panel"

    // MARK: Panel: folders row

    public static let foldersRowLabel = "Folders AI mode can use"
    public static let chipInICloud = "In iCloud Drive."
    public static func chipInProvider(_ provider: String) -> String { "In \(shown(provider))." }
    public static let chipInCloudFolder = "In a cloud folder."
    public static let chipOnServer = "On a server."
    public static let chipOnExternal = "On an external disk."
    public static let chipShared = "Shared"
    public static let chipReadOnly = "Read-only"
    public static let chipNotResponding = "Not responding"
    public static func chipRemove(_ name: String) -> String { "Remove “\(shown(name))”" }
    /// The switch at the end of the folders row, and the one chip that stands for every place Whole Mac adds.
    public static let scopeSwitchLabel = "Where AI mode looks"
    public static let scopeThisFolder = "This Folder"
    public static let scopeWholeMac = "Whole Mac"
    public static let scopeSwitchHelp = "Whole Mac lets AI mode look through your home folder, cloud folders and disks."
    public static let chipWholeMac = "Your home folder, iCloud Drive, cloud folders and disks."

    // MARK: Panel: suggestions

    public static func suggestOrganize(_ count: Int) -> String { "Organize \(counted(count, "item", "items"))" }
    public static func suggestOrganizeSelected(_ count: Int) -> String { "Organize \(number(count)) selected" }
    public static let suggestMoveAll = "Move everything to…"
    public static func suggestMoveSelected(_ count: Int) -> String { "Move \(number(count)) selected to…" }
    public static let suggestCopyAll = "Copy everything to…"
    public static func suggestCopySelected(_ count: Int) -> String { "Copy \(number(count)) selected to…" }
    public static let depthThisFolder = "This Folder"
    public static let depthTwoLevels = "2 Levels"
    public static let depthAllLevels = "All Levels"
    public static let emptyFolder = "Nothing here to organize yet."
    /// The four sentences typed into the composer end in a space, where the person goes on to name a folder.
    public static let fillMoveAll = "Move everything in this folder to "
    public static func fillMoveSelected(_ count: Int) -> String { "Move the \(number(count)) selected \(count == 1 ? "item" : "items") to " }
    public static let fillCopyAll = "Copy everything in this folder to "
    public static func fillCopySelected(_ count: Int) -> String { "Copy the \(number(count)) selected \(count == 1 ? "item" : "items") to " }

    // MARK: Panel: composer and resting states

    public static let composerPlaceholder = "Ask, or type /add and a folder"
    public static let send = "Send"
    public static let stop = "Stop"
    public static let modelMenuSettings = "AI Settings…"
    public static let noFolder = "Open a folder to use AI here."
    public static let folderRefused = "Helm can't use AI in this folder."
    public static let openSettings = "Open Settings"
    public static let composerLooksLikeKey = "That looks like a key, so add it in Settings."
    public static let slashAdd = "/add  Add a folder"
    public static let slashClear = "/clear  Start over"

    // MARK: Panel: status, trace and notices

    public static func statusReading(_ count: Int) -> String { "Reading \(counted(count, "name", "names"))…" }
    public static func statusReadingContents(_ count: Int) -> String { "Reading inside \(counted(count, "file", "files"))…" }
    public static let statusThinking = "Thinking…"
    public static let statusCheckingPlan = "Checking the plan…"
    public static let statusStopping = "Stopping…"
    public static func traceSent(names count: Int, destination: String) -> String {
        "Sent \(counted(count, "name", "names")) to \(shown(destination))."
    }
    /// The trace line of a request that also sent summaries of what is inside files.
    public static func traceSentSummaries(names: Int, summaries: Int, destination: String) -> String {
        "Sent \(counted(names, "name", "names")) and \(counted(summaries, "summary", "summaries")) to \(shown(destination))."
    }
    public static let noticeStopped = "Stopped."
    public static let noticeStartedOver = "Started over."
    public static func noticeFoldersNotLoaded(_ count: Int) -> String {
        count == 1 ? "1 folder isn't loaded, so Helm skipped it." : "\(number(count)) folders aren't loaded, so Helm skipped them."
    }
    public static func noticeNotResponding(_ name: String) -> String { "“\(shown(name))” isn't responding." }
    public static func noticeNotDownloadedNotRead(_ count: Int) -> String {
        count == 1 ? "1 file isn't downloaded, so Helm didn't read it." : "\(number(count)) files aren't downloaded, so Helm didn't read them."
    }
    public static func noticeDisconnected(_ name: String) -> String { "“\(shown(name))” was disconnected." }
    public static func addAdded(_ name: String) -> String { "Added “\(shown(name))”." }
    public static func addAlready(_ name: String) -> String { "“\(shown(name))” is already added." }
    public static let addFull = "Remove a folder to add another."
    public static let addNotFound = "Helm can't find that folder."
    public static let addRefused = "Helm can't add that folder."
    public static func serverConfirm(_ host: String) -> String { "Connect to “\(shown(host))”?" }
    public static let connect = "Connect"

    // MARK: Plan card and results

    public static func planTitleOrganize(_ folder: String) -> String { "Organize “\(shown(folder))”" }
    public static func planTitleMove(_ count: Int) -> String { "Move \(counted(count, "Item", "Items"))" }
    public static func planTitleCopy(_ count: Int) -> String { "Copy \(counted(count, "Item", "Items"))" }
    public static func planTitleRename(_ count: Int) -> String { "Rename \(counted(count, "Item", "Items"))" }
    public static func planTitleTrash(_ count: Int) -> String { "Move \(counted(count, "Item", "Items")) to Trash" }
    public static func planTitleCreate(_ count: Int) -> String { "Create \(counted(count, "File", "Files"))" }
    public static func countMoves(_ count: Int) -> String { counted(count, "move", "moves") }
    public static func countCopies(_ count: Int) -> String { counted(count, "copy", "copies") }
    public static func countNewFolders(_ count: Int) -> String { counted(count, "new folder", "new folders") }
    public static func countNewFiles(_ count: Int) -> String { counted(count, "new file", "new files") }
    public static func countRenames(_ count: Int) -> String { counted(count, "rename", "renames") }
    public static func countTrash(_ count: Int) -> String { "\(number(count)) to Trash" }
    public static let apply = "Apply"
    public static let cancel = "Cancel"
    public static let tagNew = "New"
    public static let tagRenamed = "Renamed"
    public static let tagTrash = "Trash"
    public static let tagKeepsBoth = "Keeps both"
    /// After a group's path, when the plan makes the folder it goes to.
    public static let pathNewFolder = "new folder"
    public static func groupRenames(_ count: Int) -> String { "Rename \(counted(count, "item", "items"))" }
    public static func groupMoves(_ count: Int, folder: String) -> String {
        "Move \(counted(count, "item", "items")) to “\(shown(folder))”"
    }
    public static func groupCopies(_ count: Int, folder: String) -> String {
        "Copy \(counted(count, "item", "items")) to “\(shown(folder))”"
    }
    public static func groupTrash(_ count: Int) -> String { "Move \(counted(count, "item", "items")) to the Trash" }
    public static func groupNewFiles(_ count: Int, folder: String) -> String {
        "Create \(counted(count, "file", "files")) in “\(shown(folder))”"
    }
    public static func markGoesTo(_ place: String) -> String { "Goes to \(shown(place))" }
    public static func markLeaves(_ place: String) -> String { "Leaves \(shown(place))" }
    /// The mark on a group of new files that are code or web pages.
    public static let markCode = "Code: check it before you apply it"
    /// How many items a folder holds. A folder's items are counted up to `AgentLimits.holdsCap`, and a count that
    /// reached it is written with a plus.
    public static func rowHolds(_ count: Int) -> String {
        count >= AgentLimits.holdsCap ? "\(number(AgentLimits.holdsCap))+ items" : counted(count, "item", "items")
    }
    /// The size of the text a new file holds, as Helm writes sizes everywhere: "1.2 KB".
    public static func rowSize(_ bytes: Int) -> String { ByteCountText.format(Int64(bytes)) }
    public static func noteNotAllowed(_ count: Int) -> String {
        count == 1 ? "1 change wasn't allowed, so Helm left it out." : "\(number(count)) changes weren't allowed, so Helm left them out."
    }
    public static func noteNotDownloaded(_ count: Int) -> String {
        count == 1 ? "1 item isn't downloaded, so Helm left it out." : "\(number(count)) items aren't downloaded, so Helm left them out."
    }
    public static func noteNoTrash(_ place: String) -> String { "“\(shown(place))” has no Trash, so Helm won't remove anything from it." }
    public static func noteReadOnly(_ place: String) -> String { "You can only view “\(shown(place))”." }
    public static func noteLeftOutSeveral(_ count: Int) -> String { "Helm left out \(counted(count, "change", "changes"))." }
    public static func noteCantUndo(_ place: String) -> String { "Copies on “\(shown(place))” can't be undone." }
    public static let noteSyncs = "Changes sync to your other devices."
    public static func noteShared(_ place: String) -> String { "Changes reach everyone who uses “\(shown(place))”." }
    public static let noteSyncsMaybeShared = "Changes sync to your devices and to anyone this is shared with."
    public static let planNothing = "Everything here is already in place."
    public static let planReplaced = "Replaced by the plan below."
    public static let planDismissed = "Plan dismissed."
    public static let planChanged = "This folder changed, so ask again."
    public static func applyMoving(done: Int, total: Int, name: String) -> String {
        "Moving \(number(done)) of \(number(total)) · \(shown(name))"
    }
    public static func applyCopying(done: Int, total: Int, name: String) -> String {
        "Copying \(number(done)) of \(number(total)) · \(shown(name))"
    }
    public static func applyRenaming(done: Int, total: Int, name: String) -> String {
        "Renaming \(number(done)) of \(number(total)) · \(shown(name))"
    }
    public static func applyCreating(done: Int, total: Int, name: String) -> String {
        "Creating \(number(done)) of \(number(total)) · \(shown(name))"
    }
    public static func resultOrganized(items: Int, folders: Int) -> String {
        "Moved \(counted(items, "item", "items")) into \(counted(folders, "folder", "folders"))."
    }
    public static func resultMoved(_ count: Int) -> String { "Moved \(counted(count, "item", "items"))." }
    public static func resultCopied(_ count: Int) -> String { "Copied \(counted(count, "item", "items"))." }
    public static func resultRenamed(_ count: Int) -> String { "Renamed \(counted(count, "item", "items"))." }
    public static func resultTrashed(_ count: Int) -> String { "Moved \(counted(count, "item", "items")) to the Trash." }
    public static func resultMadeFolders(_ count: Int) -> String { "Made \(counted(count, "new folder", "new folders"))." }
    public static func resultMadeFiles(_ count: Int) -> String { "Made \(counted(count, "new file", "new files"))." }
    public static func resultPartial(done: Int, total: Int, skipped: Int) -> String {
        "\(number(done)) of \(number(total)) done, and \(number(skipped)) \(skipped == 1 ? "was" : "were") skipped."
    }
    public static func resultStopped(done: Int, total: Int) -> String { "Stopped after \(number(done)) of \(number(total))." }
    public static let undo = "Undo"
    public static let show = "Show"
    public static func trashFailed(_ name: String) -> String { "“\(shown(name))” couldn't go to the Trash, and nothing was deleted." }
    public static let undoDone = "Everything is back where it was."
    public static let undoRefused = "These files changed, so Helm can't undo this."
    public static let busy = "Another change is running."

    // MARK: Failures

    /// The lines whose provider is "ChatGPT", OpenAI reached with a ChatGPT sign-in, speak of the sign-in and the plan
    /// in place of a key and an account's credit.
    public static func failNoKey(_ provider: String) -> String {
        isChatGPT(provider) ? failSignInAgain : "Add a key in Settings to use \(shown(provider))."
    }
    public static let failKeyDenied = "Helm needs your keychain to use this key."
    public static let failWrongKey = "That key didn't work."
    public static func failOutOfCredit(_ provider: String) -> String {
        isChatGPT(provider) ? planLimit : "Your \(shown(provider)) account is out of credit."
    }
    public static func failBusy(_ provider: String) -> String { "\(shown(provider)) is busy, so try again in a moment." }
    public static func failNoSuchModel(_ provider: String) -> String {
        isChatGPT(provider) ? failPlanNotCovered : "\(shown(provider)) doesn't have that model."
    }
    /// A ChatGPT sign-in that's missing, ended, or that OpenAI couldn't verify.
    public static let failSignInAgain = "Sign in with ChatGPT in Settings to use it."
    /// A ChatGPT plan's usage limit was reached: in the panel and in Settings.
    public static let planLimit = "You've reached your ChatGPT plan's usage limit."
    /// A request the ChatGPT plan doesn't cover: an account, workspace or policy that can't use it, or a feature it
    /// doesn't take.
    public static let failPlanNotCovered = "Your ChatGPT plan doesn't cover this request."
    public static let failNoTools = "This model can't work with files, so try another."
    public static let failUnreadable = "The model sent something Helm couldn't read."
    public static let failTooLarge = "That's a lot for one request, so try a smaller folder."
    public static func failUnreachable(_ provider: String) -> String { "Helm can't reach \(shown(provider)) right now." }
    public static let failOllamaNotRunning = "Ollama isn't running."
    public static let failLMStudioNotRunning = "Start the server in LM Studio."
    public static let failDeclined = "The model declined this request."
    public static let tryAgain = "Try Again"

    // MARK: AI search

    public static let searchToggle = "Find with AI"
    public static func searchPlaceholderFolder(_ folder: String) -> String { "Describe a file in \(shown(folder))" }
    public static let searchPlaceholderMac = "Describe a file on this Mac"
    public static func searchHint(_ destination: String) -> String {
        "Return sends your words and matching file names to \(shown(destination))."
    }
    /// The status bar's hint while the search's Read contents switch is on too.
    public static func searchHintContents(_ destination: String) -> String {
        "Return sends your words, file names and the contents of files the model looks at to \(shown(destination))."
    }
    /// The part of the status bar's line that counts pictures and videos left unread because they aren't downloaded.
    public static func searchNotDownloaded(_ count: Int) -> String { "\(number(count)) not downloaded" }
    /// The part of the status bar's line that counts the files the model looked inside, with Read contents on.
    public static func searchLookedAt(_ count: Int) -> String { "Looked at \(number(count))" }
    public static let searchThinking = "Thinking…"
    public static let searchFailed = "AI search isn't available."
    public static let searchOnThisMac = "Searched what's on this Mac."
    public static let searchNamesOnly = "Names only here."
    /// The kind row under the header while the search is open: its VoiceOver label, then its first choice.
    public static let searchKindRow = "File type"
    public static let searchKindAny = "Any"
    /// A choice in the kind row, and the word VoiceOver reads for it. The row offers `AISearchKind.searchChoices`;
    /// the other kinds have a word too, so every kind has one.
    public static func searchKind(_ kind: AISearchKind) -> String {
        switch kind {
        case .image: return "Photo"
        case .video: return "Video"
        case .document: return "Document"
        case .folder: return "Folder"
        case .code: return "Code"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .pdf: return "PDF"
        case .text: return "Text"
        case .spreadsheet: return "Spreadsheet"
        case .presentation: return "Presentation"
        case .app: return "App"
        case .font: return "Font"
        }
    }
    /// The chosen kind as the status bar's line names it at its end: "12 matches · “beach” · Photos".
    public static func searchKindShown(_ kind: AISearchKind) -> String {
        switch kind {
        case .image: return "Photos"
        case .video: return "Videos"
        case .document: return "Documents"
        case .folder: return "Folders"
        case .code: return "Code"
        case .audio: return "Audio"
        case .archive: return "Archives"
        case .pdf: return "PDFs"
        case .text: return "Text"
        case .spreadsheet: return "Spreadsheets"
        case .presentation: return "Presentations"
        case .app: return "Apps"
        case .font: return "Fonts"
        }
    }

    // MARK: AI mode screen

    public static let aiTitle = "AI Mode"
    public static let aiSentence = "Ask Helm to organize, move and find files for you."
    public static func consent(_ destination: String) -> String {
        "Sends your requests and file names to \(shown(destination)), never file contents."
    }
    /// The consent line at the top of a thread while Whole Mac is on.
    public static func consentWholeMac(_ destination: String) -> String {
        "Sends your requests and file names from your home folder and disks to \(shown(destination)), never file contents."
    }
    /// The line under AI mode's switch in Settings and on the AI Mode screen: what is sent and to whom, and that
    /// Helm, which has no servers, gets none of it.
    public static func consentSetup(_ destination: String) -> String {
        "Sends your requests and file names to \(shown(destination)); file contents only while Read contents is on. Helm has no servers and collects nothing."
    }
    public static func destinationOnThisMac(_ provider: String) -> String { "\(shown(provider)) on this Mac" }

    // MARK: Read contents

    /// The switch beside the composer and at the end of AI search's kind row: its words and VoiceOver label.
    public static let readContents = "Read contents"
    /// The panel switch's tooltip.
    public static let readContentsHelp = "Lets AI mode read documents and look at pictures and videos, for this thread."
    /// The search switch's tooltip.
    public static let readContentsSearchHelp = "Lets the model read documents and look at photos and videos to find matches, for this search."
    /// The consent line at the top of a thread while Read contents is on, for a model on this Mac.
    public static let consentContentsOnThisMac = "Reads text, pictures and video frames inside files on this Mac; nothing leaves your Mac."
    /// The same, for a model elsewhere.
    public static func consentContents(_ destination: String) -> String {
        "Sends your requests, file names and what it reads inside files to \(shown(destination)): text, and small copies of pictures and video frames."
    }
    /// With Whole Mac on too, for a model on this Mac.
    public static let consentContentsWholeMacOnThisMac = "Reads file names and contents from your home folder and disks on this Mac; nothing leaves your Mac."
    /// With Whole Mac on too, for a model elsewhere.
    public static func consentContentsWholeMac(_ destination: String) -> String {
        "Sends your requests, file names and what it reads inside files, from your home folder and disks, to \(shown(destination))."
    }
    public static let destinationNotSet = "the address you enter"
    public static let providerLabel = "Provider"
    public static let keyLabel = "Key"
    public static let keyPlaceholder = "Paste your key"
    public static let done = "Done"
    public static let setupHeader = "Nothing leaves your Mac unless you turn on AI mode."

    // MARK: Settings › AI

    public static let settingsAIMode = "AI mode"
    public static let removeKey = "Remove Key"
    public static let keySaved = "Saved in your Mac's keychain."
    public static let stateChecking = "Checking…"
    public static let stateConnected = "Connected"
    public static let stateNoKey = "No key"
    public static let stateWrongKey = "Wrong key"
    public static func stateCantReach(_ provider: String) -> String { "Can't reach \(shown(provider))" }
    public static func stateNoModels(_ provider: String) -> String { "\(shown(provider)) has no models yet." }
    public static let portLabel = "Port"
    public static let addressLabel = "Address"
    /// The Address field's prompt: the one scheme a typed address may have. It is put together as the app runs, so
    /// neither the source nor the app holds a web address the privacy checks would have to allow.
    public static var addressPrompt: String { [AgentProviderCatalog.secureScheme, ":", "/", "/"].joined() }
    public static let addressNeedsHTTPS = "Helm needs an https address."
    public static let addressOtherDevice = "Servers on other devices aren't supported yet."
    public static let modelLabel = "Model"
    public static let modelPlaceholder = "Model name"
    /// The button beside the model menu that asks the provider for its models again.
    public static let refreshModels = "Refresh Models"

    // MARK: ChatGPT sign-in

    /// The button that starts a ChatGPT sign-in, in OpenAI's own words for it.
    public static let continueWithChatGPT = "Continue with ChatGPT"
    public static let useKeyInstead = "Use an API key instead"
    public static let useChatGPTInstead = "Use ChatGPT instead"
    public static let signInWaiting = "Continue in your browser."
    public static func signedInAs(_ email: String) -> String { "Signed in as \(shown(email))." }
    public static let signedIn = "Signed in with ChatGPT."
    /// Signs out of ChatGPT.
    public static let removeSignIn = "Remove"
    /// Opens ChatGPT's usage settings in the browser.
    public static let manageUsage = "Manage usage"
    public static let signInDeclined = "ChatGPT plan use wasn't approved, so try again or use a key."
    public static let signInPlanOff = "This sign-in doesn't allow ChatGPT plan use."
    public static let signInTimedOut = "Sign-in took too long, so try again."
    public static let signInFailed = "Sign-in didn't finish, so try again."
    public static let signInNoBrowser = "Helm couldn't open your browser."
    public static let signInUnavailable = "Sign-in isn't available here."
    public static let signInFirst = "Continue with ChatGPT to connect."
    public static let signOutUnconfirmed = "Disconnect Helm in ChatGPT's settings to finish."
    public static let statePlanNotCovered = "Your ChatGPT plan can't be used with Helm."
    /// The page the browser shows once it has handed the sign-in back to Helm.
    public static let signInPage = "You can close this tab and go back to Helm."

    /// The line for a sign-in that didn't finish. Nil when the person stopped it, which needs no line.
    public static func signInFailure(_ failure: AgentSignInFailure) -> String? {
        switch failure {
        case .cancelled: return nil
        case .timedOut: return signInTimedOut
        case .noBrowser: return signInNoBrowser
        case .declined: return signInDeclined
        case .planOff: return signInPlanOff
        case .unreachable: return stateCantReach(AgentProviderCatalog.name(.openAI))
        case .failed: return signInFailed
        case .unavailable: return signInUnavailable
        }
    }

    // MARK: Help for each provider

    /// The link beside each provider that opens its official page on connecting.
    public static let howToConnect = "How to connect"
    /// The info button's VoiceOver label.
    public static func aboutProvider(_ provider: String) -> String { "About \(shown(provider))" }
    public static let helpClaude = "Anthropic requires an API key for apps like Helm, billed by use."
    public static let helpChatGPT = "Uses your ChatGPT plan, with no key to paste."
    public static let helpOpenAIKey = "Uses an OpenAI API key, billed by use."
    public static let helpGemini = "Uses a Gemini API key, with a free tier and paid use."
    public static let helpGrok = "Uses an xAI API key, billed by use."
    public static let helpOllama = "Free, and runs on this Mac while Ollama is running."
    public static let helpLMStudio = "Free, and runs on this Mac while LM Studio's server is on."
    public static let helpOther = "Uses any OpenAI-compatible service at an https address, with its key if it needs one."

    /// The info button's tooltip: what the provider uses and what it costs.
    public static func providerHelp(_ provider: AgentProviderID, usesChatGPT: Bool) -> String {
        switch provider {
        case .claude: return helpClaude
        case .openAI: return usesChatGPT ? helpChatGPT : helpOpenAIKey
        case .gemini: return helpGemini
        case .grok: return helpGrok
        case .ollama: return helpOllama
        case .lmStudio: return helpLMStudio
        case .other: return helpOther
        }
    }

    // MARK: Elsewhere

    public static let aboutLine = "An agentic file manager for your Mac."

    // MARK: Counts and names

    /// A count with the number grouping of `locale`, as in "1,240".
    static func number(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.locale(locale))
    }

    /// A count and what it counts, in the singular for 1: "1 item", "214 items".
    static func counted(_ count: Int, _ one: String, _ many: String) -> String {
        "\(number(count)) \(count == 1 ? one : many)"
    }

    /// A name, a place or a host as it may be shown: hidden and control characters are written out as escapes.
    static func shown(_ name: String) -> String { AgentTextEscaper.escape(name) }

    private static func isChatGPT(_ provider: String) -> Bool { provider == AgentProviderCatalog.chatGPTName }
}
