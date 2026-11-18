#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmSearch

/// Searches with a model's help: plan, fan out, look, fuse, rank.
///
/// The plain search on the person's own words runs first and is shown at once. The model then plans up to six
/// typed queries, which Helm runs here (Spotlight, and a walk of the folder searched), checks again item by item,
/// and merges with the plain results by reciprocal rank fusion. A last question orders the best rows. The runner
/// is the only sender of results for such a search, so once the merged list is on show a late plain result can't
/// put the plain order back. It runs in the tab's search lane: Escape, an edit or another search cancels it, and an
/// answer that arrives after that is dropped by the search's generation.
///
/// Every item that is merged or sent passes `AgentItemFilter.allowsSearchRow` and sits in no folder with the hidden
/// flag, whatever Show Hidden Files says. Hits are looked up with downloads off.
/// A model never sees a path: rows carry the name, the folder in Helm's words, the kind, a rounded size and dates.
///
/// With the kind row's Read contents switch on, and outside a server, Helm reads inside files and the model looks.
/// Up to 200 files are read on this Mac by `AgentContentReader` with the person's permit, and kept for the search
/// session by path and modification date: the files the model may look at (`isLookable`: pictures, videos, PDFs,
/// Word files and prose, with code and settings only for the kinds that ask for them) that the queries and the plain
/// search found, and those the queries describe in every way but their words for inside files: in the folder
/// searched, or for a search of the whole Mac only its pictures and videos. A picture or a video whose text or labels
/// hold every one of a query's words for inside files is a match of that query, read on this Mac. Then the model looks
/// at `AgentContentLimits.searchLooks` of them at most: those matches first, then the files found, and only in a search
/// kept to a folder the newest files described, so a search of the whole Mac never sends a file just for being new.
/// It is sent each file's row facts, a document's first lines, the words found on this Mac, and the small pictures
/// Helm makes of pictures, video frames and scanned pages, `looksPerQuestion` files a question. The files it says fit
/// come first, each with what it saw; one it says doesn't fit is no longer a match for what was read on this Mac. A
/// provider that turns pictures away gets the question again in words, and no pictures until AI mode or the provider
/// changes. A file that isn't downloaded is never read, and the status bar counts it and the files looked at.
@MainActor final class AISearchRunner: AISearchRunning {
    private let dependencies: WindowDependencies

    init(dependencies: WindowDependencies) { self.dependencies = dependencies }

    /// Tests stand in for Spotlight here: the paths each planned query finds. A fixture run never asks Spotlight for
    /// a planned query; it has the walk, and this.
    static var fanOutAnswersForTesting: ((AISearchQuery) -> [URL])?

    /// The search field's spark is on: Return asks the model. Off at launch and whenever the search closes.
    var isOn = false {
        didSet { if !isOn { contentPermit = nil } }
    }
    /// The person's permit while the kind row's Read contents switch is on. It goes, and what was read with it, when
    /// the spark goes off, as it does when the search closes.
    var contentPermit: AgentContentPermit? {
        didSet { if contentPermit == nil { memo.clear() } }
    }
    /// What this search session has read inside files.
    let memo = AgentContentMemo()
    /// A provider turned a look question with pictures away as a bad request: the looks go in words alone until AI
    /// mode, the provider or the model changes (`runtimeChanged()`).
    private(set) var picturesRefused = false

    /// AI mode turned on or off, or the provider or the model changed: the next look may carry pictures again.
    func runtimeChanged() { picturesRefused = false }
    /// Whether the kind row's Read contents switch is on.
    var readsContents: Bool { contentPermit != nil }
    /// What the window listens to so the spark follows the search and AI mode.
    var watch: AISearchWatch?

    /// How many items one planned query keeps, and how many Spotlight is read for.
    static let keptPerQuery = 200
    static let spotlightReadLimit = 2_000
    static let spotlightSeconds = 2.5
    /// Planned queries asked of Spotlight at once.
    static let queriesAtOnce = 3
    /// How long the merge waits for the plain search's first results when they haven't come yet.
    static let baselineWaitSeconds = 3.0

    func run(_ query: SearchQuery, generation: Generation, tab: TabID,
             baseline: @escaping @MainActor (_ deliver: @escaping @Sendable ([SearchResult]) -> Void) -> StoreEffectCancellation,
             send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        let delivery = AISearchDelivery(tab: tab, generation: generation, send: send)
        // With no model ready this is the plain search, sent as it always is.
        guard query.usesAI, case .ready(let provider, _, _, let isLocal) = dependencies.agent.runtime.state else {
            return baseline { results in delivery.baseline(results) }
        }
        // Words that hold a key are never sent, as in the panel's composer: the name matches show and the status
        // bar says why.
        if AgentComposerIntent.parse(query.text) == .looksLikeKey {
            delivery.assist(SearchAssist(phase: .done, readAs: AgentText.composerLooksLikeKey))
            return baseline { results in delivery.baseline(results) }
        }
        guard case .success(let client) = dependencies.agent.runtime.client() else {
            return baseline { results in delivery.baseline(results) }
        }
        delivery.assist(SearchAssist(phase: .thinking))
        let plain = baseline { results in delivery.baseline(results) }
        let task = Task { @MainActor [weak self] in
            await self?.assist(query, client: client, provider: provider, isLocal: isLocal, delivery: delivery)
        }
        return StoreEffectCancellation {
            plain.cancel()
            task.cancel()
        }
    }

    // MARK: The steps

    private func assist(_ query: SearchQuery, client: any AgentModelClient, provider: String, isLocal: Bool,
                        delivery: AISearchDelivery) async {
        let session = AISearchSession(client: client)
        let home = dependencies.home
        let scopeRoot: URL?
        if case .currentFolder(let url) = query.scope { scopeRoot = url } else { scopeRoot = nil }
        var place = StorageFacts.thisMac
        if let scopeRoot {
            // The place is read for the folder as the disk spells it, as the panel reads its folders' places: a
            // window may spell the same folder through a link, such as /tmp for /private/tmp.
            let spelled = await dependencies.agent.disk.canonicalPath(scopeRoot.path) ?? scopeRoot.path
            place = await dependencies.agent.storage.facts(for: URL(fileURLWithPath: spelled, isDirectory: true))
        }
        let coverage = Self.coverage(of: place, scoped: scopeRoot != nil)
        let label = scopeRoot.map { AgentItemFilter.placeWords(path: $0.path, home: home.path, storage: place).last ?? place.name }
            ?? StorageFacts.thisMac.name

        // Read contents, when its switch is on and this run can read inside files.
        let looking: (reader: any AgentContentReading, permit: AgentContentPermit)? = contentPermit.flatMap { permit in
            dependencies.agent.contents.map { ($0, permit) }
        }

        // 1. Plan.
        let plan: AISearchPlan
        do {
            plan = try await session.plan(request: query.text, scopeLabel: label, today: dependencies.clock.now(),
                                          languageCode: Locale.current.language.languageCode?.identifier ?? "en",
                                          kind: query.kind, readsContents: looking != nil)
        } catch {
            guard !Task.isCancelled else { return }
            // The name matches stay on show, the status bar says why, and Return again tries again.
            let failure = error as? AgentFailure ?? .unreadable
            delivery.assist(SearchAssist(phase: .failed, readAs: AgentText.searchFailedBecause(failure, provider: provider),
                                         coverage: coverage))
            return
        }
        guard !Task.isCancelled else { return }
        let queries = Self.queries(plan.queries, coverage: coverage, request: query.text, kind: query.kind)

        // 2. Fan out.
        let hiddenFolders = AISearchHiddenFolders(fileSystem: dependencies.fileSystem, home: home)
        let walked = await walk(query, scopeRoot: scopeRoot, place: place)
        var found = await fanOut(queries, search: query, scopeRoot: scopeRoot, walked: walked, coverage: coverage,
                                 hiddenFolders: hiddenFolders)
        guard !Task.isCancelled else { return }

        // 3. The plain search's results, which the look and the merge both take.
        let plainResults = await delivery.firstBaseline(waiting: Self.baselineWaitSeconds)
        guard !Task.isCancelled else { return }
        let plainKept = await hiddenFolders.outside(plainResults.map(\.entry).filter { allows($0) })
        guard !Task.isCancelled else { return }

        // 4. Inside files, with Read contents on: read on this Mac, then looked at by the model. A server is searched
        // by name only.
        var sightings: [ItemID: AISearchSighting] = [:]
        var notDownloaded = 0
        var looked = AISearchLooked()
        if let looking, coverage != .namesOnly {
            delivery.assist(SearchAssist(phase: .thinking, readAs: AgentText.searchReadingInside, coverage: coverage))
            let read = await readInside(queries, walked: walked, found: found, plain: plainKept, scopeRoot: scopeRoot,
                                        kind: query.kind, coverage: coverage, hiddenFolders: hiddenFolders,
                                        reader: looking.reader, permit: looking.permit,
                                        looks: AgentContentLimits.searchLooks(isLocal: isLocal))
            guard !Task.isCancelled else { return }
            notDownloaded = read.notDownloaded
            let picked = Array(read.pool.prefix(AgentContentLimits.searchLooks(isLocal: isLocal)))
            if !picked.isEmpty {
                delivery.assist(SearchAssist(phase: .thinking, readAs: AgentText.searchLooking(picked.count), coverage: coverage))
            }
            looked = await look(at: picked,
                                request: query.text, kind: query.kind, session: session, place: place, scopeRoot: scopeRoot,
                                reader: looking.reader, permit: looking.permit)
            guard !Task.isCancelled else { return }
            // A file the model looked at and said doesn't fit is no longer a match for what was read on this Mac.
            sightings = read.sightings.filter { !looked.misses.contains($0.key) }
            for (id, sighting) in looked.seen { sightings[id] = sighting }
            for (index, hits) in read.found.enumerated() where found.indices.contains(index) {
                let known = Set(found[index].map(\.id))
                found[index] += hits.filter { !known.contains($0.id) && !looked.misses.contains($0.id) }
            }
        }

        // 5. Fuse with the plain search, and show that at once. What the model looked at and said fits comes first,
        // in its order; the rest is merged as before.
        var entries: [ItemID: FileEntry] = [:]
        var foundBy: [ItemID: Int] = [:]
        var lists: [(weight: Double, ids: [ItemID])] = []
        for (index, hits) in found.enumerated() {
            for entry in hits {
                if entries[entry.id] == nil { entries[entry.id] = entry }
                if foundBy[entry.id] == nil { foundBy[entry.id] = index }
            }
            lists.append((RankFusion.queryWeights[min(index, RankFusion.queryWeights.count - 1)], hits.map(\.id)))
        }
        for entry in plainKept where entries[entry.id] == nil { entries[entry.id] = entry }
        lists.append((RankFusion.baselineWeight, plainKept.map(\.id)))
        let limit = max(1, query.limit)
        let fits = Self.sorted(Array(looked.fits.prefix(limit)), by: plan.sort)
        let fitIDs = Set(fits.map(\.id))
        var rest = RankFusion.fuse(lists).compactMap { entries[$0] }.filter { !fitIDs.contains($0.id) }
        rest = Self.sorted(Array(rest.prefix(limit - fits.count)), by: plan.sort)
        var order = fits + rest

        let calendar = Calendar.current, locale = Locale.current
        func queryReason(_ entry: FileEntry) -> SearchReason? {
            guard let index = foundBy[entry.id] else { return nil }
            let planned = queries[index]
            return SearchReasonBuilder.reason(codes: Self.codes(of: planned), entry: entry, query: planned,
                                              scopeRoot: scopeRoot, calendar: calendar, locale: locale,
                                              sighting: sightings[entry.id])
        }
        // A fit says what the model saw, alone; with no phrase, what the query that found it asked.
        func fitReason(_ entry: FileEntry) -> SearchReason? {
            let planned = foundBy[entry.id].map { queries[$0] }
            let sighting = sightings[entry.id]
            let codes: [SearchReasonCode] = sighting?.seen != nil ? [.content] : [.content] + (planned.map(Self.codes) ?? [])
            return SearchReasonBuilder.reason(codes: codes, entry: entry, query: planned, scopeRoot: scopeRoot,
                                              calendar: calendar, locale: locale, sighting: sighting)
        }
        var reasons: [ItemID: SearchReason] = [:]
        for entry in rest { reasons[entry.id] = queryReason(entry) }
        for entry in fits { reasons[entry.id] = fitReason(entry) }
        // A word a model chose for a name, a folder or an extension is shown only when the person typed it or a
        // result bears it. A query left with nothing to show has no line. The kind the person chose is named once,
        // at the end of the status bar's line, so a query that asks for just that kind doesn't say it again.
        func shown(_ planned: AISearchQuery) -> AISearchQuery {
            var backed = SearchReasonBuilder.backed(planned, request: query.text, results: order, scopeRoot: scopeRoot)
            if let kind = query.kind, backed.kinds == [kind] { backed.kinds = [] }
            return backed
        }
        let queriesRead = queries.map { SearchReasonBuilder.readAs(count: nil, query: shown($0), calendar: calendar, locale: locale) }
            .filter { !$0.isEmpty }
        delivery.settle(order)
        delivery.assist(SearchAssist(phase: .thinking, reasons: reasons, queriesRead: queriesRead, coverage: coverage))

        // 6. Rank the rest; the fits aren't ranked again. A sorted list, or a handful of results, needs no judgement.
        if plan.sort == .relevance, rest.count > 5 {
            let shown = Array(rest.prefix(AISearchSession.maxRows(isLocal: isLocal)))
            let rows = await self.rows(shown, place: place, scopeRoot: scopeRoot)
            if let verdicts = try? await session.rank(request: query.text, rows: rows) {
                guard !Task.isCancelled else { return }
                var first: [FileEntry] = []
                for verdict in verdicts {
                    let entry = shown[verdict.row - 1]
                    first.append(entry)
                    let planned = foundBy[entry.id].map { queries[$0] }
                    // What a picture or a video was seen to hold comes first, whatever the model said made it fit.
                    var why = verdict.why
                    if sightings[entry.id] != nil, !why.contains(.content) { why.insert(.content, at: 0) }
                    if let reason = SearchReasonBuilder.reason(codes: why, entry: entry, query: planned,
                                                               scopeRoot: scopeRoot, calendar: calendar, locale: locale,
                                                               sighting: sightings[entry.id]) {
                        reasons[entry.id] = reason
                    }
                }
                let chosen = Set(first.map(\.id))
                rest = first + rest.filter { !chosen.contains($0.id) }
                order = fits + rest
                delivery.update(order)
            }
            // A failed ranking leaves the merged list, with the queries' reasons.
        }
        guard !Task.isCancelled else { return }
        // How the request was read, from the strictest query; with no query left, the count alone. The kind the
        // person chose follows, then the files the model looked at: "12 matches · “beach” · Photos · Looked at 48".
        var readAs = SearchReasonBuilder.readAs(count: order.count, query: shown(queries.first ?? AISearchQuery()), calendar: calendar,
                                                locale: locale)
        if let kind = query.kind { readAs += " · " + AgentText.searchKindShown(kind) }
        if looked.count > 0 { readAs += " · " + AgentText.searchLookedAt(looked.count) }
        if looked.failed > 0 { readAs += " · " + AgentText.searchCouldntLook(looked.failed, looked.failure, provider: provider) }
        if notDownloaded > 0 { readAs += " · " + AgentText.searchNotDownloaded(notDownloaded) }
        delivery.assist(SearchAssist(phase: .done, reasons: reasons, readAs: readAs, queriesRead: queriesRead, coverage: coverage))
    }

    /// Runs every planned query and answers what each found, best first, in the plan's order. Each hit is looked up
    /// with downloads off, so a hit in a cloud folder that isn't loaded is skipped and nothing is fetched.
    private func fanOut(_ queries: [AISearchQuery], search: SearchQuery, scopeRoot: URL?, walked: [FileEntry],
                        coverage: SearchAssist.Coverage, hiddenFolders: AISearchHiddenFolders) async -> [[FileEntry]] {
        let fileSystem = dependencies.fileSystem
        let hook = Self.fanOutAnswersForTesting
        // A fixture run keeps its keys in memory. It never asks Spotlight; the walk and the hook stand in.
        let asksSpotlight = hook == nil && !dependencies.agent.secrets.isMemoryOnly && coverage != .namesOnly
        var found = Array(repeating: [FileEntry](), count: queries.count)
        var next = 0
        while next < queries.count, !Task.isCancelled {
            let batch = Array(next..<min(next + Self.queriesAtOnce, queries.count))
            next += batch.count
            await withTaskGroup(of: (Int, [URL]).self) { group in
                for index in batch {
                    let planned = queries[index]
                    group.addTask { @MainActor in
                        if let hook { return (index, hook(planned)) }
                        guard asksSpotlight, let predicate = AISearchPredicates.predicate(for: planned) else { return (index, []) }
                        let scopes: [Any] = scopeRoot.map { [$0.path] } ?? [NSMetadataQueryLocalComputerScope]
                        let urls = await AISearchSpotlightGather.gather(predicate, scopes: scopes,
                                                                        limit: Self.spotlightReadLimit, seconds: Self.spotlightSeconds)
                        return (index, urls)
                    }
                }
                for await (index, urls) in group {
                    let indexed = await DatalessGuard.off { () async -> [FileEntry] in
                        var indexed: [FileEntry] = []
                        for url in urls.prefix(Self.spotlightReadLimit) {
                            guard !Task.isCancelled else { break }
                            if let entry = try? await fileSystem.entry(at: url) { indexed.append(entry) }
                        }
                        return indexed
                    }
                    let outside = await hiddenFolders.outside(indexed)
                    found[index] = keep(outside, walked: walked, for: queries[index], search: search, scopeRoot: scopeRoot)
                }
            }
        }
        return found
    }

    // MARK: Inside files

    /// Reads inside the files a search may be about, on this Mac, with the person's permit: the files the model may
    /// look at (`isLookable` for the chosen `kind`) that the queries and the plain search found, and every such file a
    /// query describes in every way but its words for inside files: from the walk of the folder searched
    /// (`lookQuery`), or for a search of the whole Mac its pictures and videos from Spotlight (`visualQuery`), which
    /// are read only to be matched on this Mac. As many found files as the model looks at come first, then the
    /// described ones, newest first, then the rest of the found ones: `AgentContentLimits.searchCandidates` at most. A
    /// picture or a video a query's pictures-and-videos form (`visualQuery`) describes, whose text or labels hold every
    /// one of its words for inside files, is a match of that query. Answers each query's matches, what was seen in
    /// each, how many weren't read because they aren't downloaded, and the files read that the model may look at, in
    /// the order it is to look at them: the matches, then the files found, then, in a search kept to a folder alone,
    /// the newest.
    private func readInside(_ queries: [AISearchQuery], walked: [FileEntry], found: [[FileEntry]], plain: [FileEntry],
                            scopeRoot: URL?, kind: AISearchKind?, coverage: SearchAssist.Coverage,
                            hiddenFolders: AISearchHiddenFolders, reader: any AgentContentReading, permit: AgentContentPermit,
                            looks: Int) async -> AISearchReading {
        var foundFirst: [FileEntry] = []
        var known: Set<ItemID> = []
        for entry in Array(found.joined()) + plain
            where allows(entry) && Self.isLookable(entry, kind: kind) && known.insert(entry.id).inserted {
            foundFirst.append(entry)
        }
        var described: [FileEntry] = []
        let describe = scopeRoot == nil ? Self.visualQuery : Self.lookQuery
        for (index, look) in queries.map(describe).enumerated() {
            guard let look else { continue }
            var pool = walked
            if scopeRoot == nil {
                pool += await spotlightHits(for: look, original: queries[index], coverage: coverage, hiddenFolders: hiddenFolders)
            }
            for entry in pool where !known.contains(entry.id) && allows(entry) && Self.isLookable(entry, kind: kind)
                && AISearchMatcher.matches(entry, look, scopeRoot: scopeRoot, contentVerified: false) {
                known.insert(entry.id)
                described.append(entry)
            }
        }
        let newest = described.sorted { $0.modificationDate > $1.modificationDate }
        let chosen = Array((foundFirst.prefix(looks) + newest + foundFirst.dropFirst(looks)).prefix(AgentContentLimits.searchCandidates))
        guard !chosen.isEmpty, !Task.isCancelled else { return AISearchReading(found: queries.map { _ in [] }) }

        // Read what this session hasn't read yet. A file that isn't downloaded is never opened.
        var summaries: [ItemID: AgentContentSummary] = [:]
        var notDownloaded = 0
        var unread: [FileEntry] = []
        for entry in chosen {
            if entry.cloudAvailability == .evicted {
                notDownloaded += 1
            } else if let known = memo.summary(path: entry.url.path, modified: entry.modificationDate) {
                summaries[entry.id] = known
            } else {
                unread.append(entry)
            }
        }
        if !unread.isEmpty {
            let answers = await reader.summaries(of: unread.map { Self.request(for: $0, pictures: false) }, permit: permit,
                                                 seconds: AgentContentLimits.secondsPerSearch)
            for (entry, summary) in zip(unread, answers) {
                if summary.status == .not_downloaded { notDownloaded += 1 }
                memo.keep(summary, path: entry.url.path, modified: entry.modificationDate)
                summaries[entry.id] = summary
            }
        }

        var reading = AISearchReading(found: queries.map { _ in [FileEntry]() })
        reading.notDownloaded = notDownloaded
        var sightedBy: [ItemID: Int] = [:]
        let byDate = chosen.sorted { $0.modificationDate > $1.modificationDate }
        for (index, look) in queries.map(Self.visualQuery).enumerated() {
            guard let look else { continue }
            for entry in byDate where AISearchMatcher.matches(entry, look, scopeRoot: scopeRoot, contentVerified: false) {
                guard let summary = summaries[entry.id],
                      let sighting = AISearchMatcher.sighting(of: queries[index].contentAll, in: summary) else { continue }
                reading.found[index].append(entry)
                if reading.sightings[entry.id] == nil {
                    reading.sightings[entry.id] = sighting
                    sightedBy[entry.id] = index
                }
            }
        }
        // The order the model looks in: matches by the query that saw them, then the files found in the order found,
        // then the newest. A search of the whole Mac stops before the newest: a file there is looked at only when this
        // Mac matched it or a search found it.
        let foundAt = Dictionary(foundFirst.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ entry: FileEntry) -> (tier: Int, place: Int) {
            if let query = sightedBy[entry.id] { return (0, query) }
            if let place = foundAt[entry.id] { return (1, place) }
            return (2, 0)
        }
        let lastTier = scopeRoot == nil ? 1 : 2
        let lookable = byDate.filter { summaries[$0.id]?.status == .read && rank($0).tier <= lastTier }
        reading.pool = lookable.enumerated().sorted { left, right in
            let one = rank(left.element), other = rank(right.element)
            if one.tier != other.tier { return one.tier < other.tier }
            if one.place != other.place { return one.place < other.place }
            return left.offset < right.offset
        }.map { AISearchRead(entry: $0.element, summary: summaries[$0.element.id] ?? .notRead(.other, .unreadable)) }
        return reading
    }

    /// Shows the model `picked`, `looksPerQuestion` files a question and `lookQuestionsAtOnce` questions at once, and
    /// answers what it said: the files it says fit, in its order within a question and question order after, what it
    /// saw in each, the files it says don't fit, and how many files were in questions it answered. Pictures go
    /// along unless a provider turned them away (`picturesRefused`). A question that fails, or runs out of time,
    /// leaves what was read on this Mac as it was.
    private func look(at picked: [AISearchRead], request: String, kind: AISearchKind?, session: AISearchSession,
                      place: StorageFacts, scopeRoot: URL?, reader: any AgentContentReading,
                      permit: AgentContentPermit) async -> AISearchLooked {
        guard !picked.isEmpty else { return AISearchLooked() }
        // A model that can't see pictures, as its provider said, gets Apple's descriptions of them alone.
        let sendsPictures = !picturesRefused && dependencies.agent.runtime.modelSeesPictures
        let shown = sendsPictures ? await withPictures(picked, reader: reader, permit: permit) : picked
        guard !Task.isCancelled else { return AISearchLooked() }
        let facts = await shownFacts(shown.map(\.entry), place: place, scopeRoot: scopeRoot)
        let home = dependencies.home.path
        let spelled = await dependencies.agent.disk.canonicalPath(home) ?? home
        let homes = spelled == home ? [home] : [home, spelled]
        var questions: [[(entry: FileEntry, item: AISearchLookItem)]] = []
        for start in stride(from: 0, to: shown.count, by: AgentContentLimits.looksPerQuestion) {
            let end = min(start + AgentContentLimits.looksPerQuestion, shown.count)
            questions.append((start..<end).map { index in
                let read = shown[index], fact = facts[index]
                let modified = read.entry.modificationDate == .distantPast ? nil : read.entry.modificationDate
                return (read.entry, AISearchLookItem(item: index - start + 1, name: fact.name, folder: fact.folder, kind: fact.kind,
                                                     modified: modified, summary: read.summary))
            })
        }
        var answers: [Int: [AISearchLook]] = [:]
        var failures: [Int: AgentFailure] = [:]
        var next = 0
        while next < questions.count, !Task.isCancelled {
            let batch = Array(next..<min(next + AgentContentLimits.lookQuestionsAtOnce, questions.count))
            next += batch.count
            let pictures = !picturesRefused && sendsPictures
            await withTaskGroup(of: (Int, [AISearchLook]?, Bool, AgentFailure?).self) { group in
                for index in batch {
                    let items = questions[index].map(\.item)
                    group.addTask {
                        let answer = await Self.ask(session, request: request, kind: kind, items: items, homes: homes, pictures: pictures)
                        return (index, answer.looks, answer.refused, answer.failure)
                    }
                }
                for await (index, looks, refused, failure) in group {
                    if refused { picturesRefused = true }
                    if let looks { answers[index] = looks } else { failures[index] = failure ?? .unreadable }
                }
            }
        }
        var looked = AISearchLooked()
        for (index, question) in questions.enumerated() {
            guard let looks = answers[index] else {
                // Not answered: counted and said in the status bar, so a look that failed is never silent.
                if !Task.isCancelled, let failure = failures[index] {
                    looked.failed += question.count
                    if looked.failure == nil { looked.failure = failure }
                }
                continue
            }
            looked.count += question.count
            for look in looks where question.indices.contains(look.item - 1) {
                let (entry, item) = question[look.item - 1]
                guard look.fits else { looked.misses.insert(entry.id); continue }
                looked.fits.append(entry)
                if !look.seen.isEmpty {
                    looked.seen[entry.id] = AISearchSighting(medium: Self.medium(of: item.summary.kind), textWords: [], labels: [],
                                                             seen: look.seen)
                }
            }
        }
        return looked
    }

    /// One look question. Asked with pictures and turned away as a bad request, it is asked once more in words alone,
    /// with the words found on this Mac standing in, and the answer says pictures were refused. Any other failure
    /// answers no looks, and why.
    nonisolated private static func ask(_ session: AISearchSession, request: String, kind: AISearchKind?,
                                        items: [AISearchLookItem], homes: [String],
                                        pictures: Bool) async -> (looks: [AISearchLook]?, refused: Bool, failure: AgentFailure?) {
        let carries = pictures && items.contains { !$0.summary.images.isEmpty }
        do {
            return (try await session.look(request: request, kind: kind, items: items, homes: homes, pictures: carries), false, nil)
        } catch AgentFailure.badRequest where carries {
            do {
                return (try await session.look(request: request, kind: kind, items: items, homes: homes, pictures: false), true, nil)
            } catch {
                return (nil, true, error as? AgentFailure ?? .unreadable)
            }
        } catch {
            return (nil, false, error as? AgentFailure ?? .unreadable)
        }
    }

    /// The files to look at, with the small pictures made of each picture, video and PDF: from this search session's
    /// memo when it holds them, else read again on this Mac. A file whose pictures can't be made keeps the words read
    /// first.
    private func withPictures(_ picked: [AISearchRead], reader: any AgentContentReading,
                              permit: AgentContentPermit) async -> [AISearchRead] {
        var shown = picked
        var unread: [Int] = []
        for (index, read) in picked.enumerated() where [.image, .video, .pdf].contains(read.summary.kind) {
            if let known = memo.summary(path: read.entry.url.path, modified: read.entry.modificationDate, withPictures: true) {
                shown[index].summary = known
            } else {
                unread.append(index)
            }
        }
        guard !unread.isEmpty else { return shown }
        let answers = await reader.summaries(of: unread.map { Self.request(for: picked[$0].entry, pictures: true) }, permit: permit,
                                             seconds: AgentContentLimits.secondsPerSearch)
        for (index, summary) in zip(unread, answers) where summary.status == .read {
            let entry = picked[index].entry
            memo.keep(summary, path: entry.url.path, modified: entry.modificationDate, withPictures: true)
            shown[index].summary = summary
        }
        return shown
    }

    /// What Read contents is asked for one file. It is never marked as not downloaded: such a file isn't asked for.
    private static func request(for entry: FileEntry, pictures: Bool) -> AgentContentRequest {
        AgentContentRequest(path: entry.url.path, name: entry.name, identity: entry.objectIdentity,
                            typeIdentifier: entry.contentTypeIdentifier, size: entry.size,
                            modified: entry.modificationDate, isDataless: false, wantsImages: pictures)
    }

    /// Whether the model may look inside this file in a search kept to `kind`, nil for Any: a picture, a video, a PDF,
    /// a Word file or prose (`AISearchKind.proseExtensions`) always; code only when the person chose Code; other text,
    /// such as settings in JSON, YAML or XML, or text with no extension, only when they chose Document or Code. Code
    /// and settings can hold keys and addresses that have nothing to do with a search for a photo or a letter.
    static func isLookable(_ entry: FileEntry, kind chosen: AISearchKind?) -> Bool {
        let ext = entry.url.pathExtension
        switch AgentContentLimits.kind(typeIdentifier: entry.contentTypeIdentifier, extension: ext, kind: entry.kind) {
        case .other: return false
        case .image, .video, .pdf: return true
        case .text:
            let lowered = ext.lowercased()
            if AISearchKind.proseExtensions.contains(lowered) || AgentContentLimits.wordExtensions.contains(lowered) { return true }
            if AISearchKind.of(typeIdentifier: entry.contentTypeIdentifier, extension: ext, kind: entry.kind) == .code {
                return chosen == .code
            }
            return chosen == .document || chosen == .code
        }
    }

    private static func medium(of kind: AgentContentKind) -> AISearchSighting.Medium {
        switch kind {
        case .image: return .image
        case .video: return .video
        case .text, .pdf, .other: return .document
        }
    }

    /// A query that looks for words inside files, as one for the files the model may look at: the same names,
    /// folders, dates and sizes, with no words inside files, and kept to the kinds Read contents reads that the
    /// query's kinds cover: pictures, videos and documents (PDFs, text, code and Word files) when it names no kind.
    /// Nil for a query with no such words, and for one kept to kinds Read contents doesn't read.
    static func lookQuery(_ query: AISearchQuery) -> AISearchQuery? {
        guard !query.contentAll.isEmpty else { return nil }
        var look = withoutRepeatedNames(query)
        look.contentAll = []
        let readable: [AISearchKind] = [.image, .video, .pdf, .text, .code, .document]
        if query.kinds.isEmpty {
            look.kinds = readable
        } else {
            look.kinds = readable.filter { kind in query.kinds.contains { $0.covers(kind) } }
            guard !look.kinds.isEmpty else { return nil }
        }
        if !look.extensions.isEmpty {
            look.extensions = look.extensions.filter { ext in
                AgentContentLimits.kind(typeIdentifier: nil, extension: ext, kind: .regular) != .other
            }
            if look.extensions.isEmpty { return nil }
        }
        return look
    }

    /// `query` without the name words that say again a word it looks for inside files, as a model planning "a bird"
    /// says it: every query of gpt-oss's asked for "bird" in the name as well as inside, so no photo was ever read. A
    /// list of other names that holds such a word goes whole, since its words are other names for the same thing.
    /// A name word of its own, such as "trip" beside "dog", stays.
    static func withoutRepeatedNames(_ query: AISearchQuery) -> AISearchQuery {
        func folded(_ word: String) -> String {
            word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let inside = Set(query.contentAll.map(folded))
        var look = query
        look.nameAll = query.nameAll.filter { !inside.contains(folded($0)) }
        if query.nameAny.contains(where: { inside.contains(folded($0)) }) { look.nameAny = [] }
        return look
    }

    /// A query that looks for words inside files, as one for the pictures and videos it describes: the same names,
    /// folders, dates and sizes, with no words inside files, and kept to pictures and videos. Nil for a query with no
    /// such words, and for one kept to kinds that are neither.
    static func visualQuery(_ query: AISearchQuery) -> AISearchQuery? {
        guard !query.contentAll.isEmpty else { return nil }
        var look = withoutRepeatedNames(query)
        look.contentAll = []
        let seen: [AISearchKind] = [.image, .video]
        if query.kinds.isEmpty {
            look.kinds = seen
        } else {
            look.kinds = seen.filter { kind in query.kinds.contains { $0.covers(kind) } }
            guard !look.kinds.isEmpty else { return nil }
        }
        if !look.extensions.isEmpty {
            look.extensions = look.extensions.filter { ext in
                let kind = AISearchKind.of(typeIdentifier: nil, extension: ext, kind: .regular)
                return kind == .image || kind == .video
            }
            if look.extensions.isEmpty { return nil }
        }
        return look
    }

    /// Spotlight's pictures and videos for a query searched outside any folder, looked up with downloads off. A
    /// fixture run never asks Spotlight; the hook stands in.
    private func spotlightHits(for look: AISearchQuery, original: AISearchQuery, coverage: SearchAssist.Coverage,
                               hiddenFolders: AISearchHiddenFolders) async -> [FileEntry] {
        let fileSystem = dependencies.fileSystem
        let urls: [URL]
        if let hook = Self.fanOutAnswersForTesting {
            urls = hook(look)
        } else {
            guard !dependencies.agent.secrets.isMemoryOnly, coverage != .namesOnly,
                  let predicate = AISearchPredicates.predicate(for: look) else { return [] }
            urls = await AISearchSpotlightGather.gather(predicate, scopes: [NSMetadataQueryLocalComputerScope],
                                                        limit: Self.spotlightReadLimit, seconds: Self.spotlightSeconds)
        }
        let entries = await DatalessGuard.off { () async -> [FileEntry] in
            var entries: [FileEntry] = []
            for url in urls.prefix(Self.spotlightReadLimit) where !Task.isCancelled {
                if let entry = try? await fileSystem.entry(at: url) { entries.append(entry) }
            }
            return entries
        }
        return await hiddenFolders.outside(entries)
    }

    /// What one query keeps: the index's hits checked again (the index already checked words inside files), and the
    /// walk's items that the query describes. Each item once, allowed, ranked by its name against the query's words.
    private func keep(_ indexed: [FileEntry], walked: [FileEntry], for planned: AISearchQuery, search: SearchQuery,
                      scopeRoot: URL?) -> [FileEntry] {
        var seen: Set<ItemID> = []
        var kept: [SearchCandidate] = []
        for (entries, verified) in [(indexed, true), (walked, false)] {
            for entry in entries where seen.insert(entry.id).inserted {
                guard allows(entry),
                      AISearchMatcher.matches(entry, planned, scopeRoot: scopeRoot, contentVerified: verified) else { continue }
                kept.append(SearchCandidate(entry: entry))
            }
        }
        var ranking = search
        ranking.text = (planned.nameAll + planned.nameAny).joined(separator: " ")
        ranking.limit = Self.keptPerQuery
        let context = HostEffectRunner.rankingContext(ranking, settings: dependencies.settings.snapshot)
        return SearchRanker.rank(kept, context: context, clock: dependencies.clock).results.prefix(Self.keptPerQuery).map(\.entry)
    }

    /// Everything in the folder searched, within the place's limits, with downloads off and never into a folder
    /// that isn't loaded. Nothing is walked for a search of the whole Mac.
    private func walk(_ search: SearchQuery, scopeRoot: URL?, place: StorageFacts) async -> [FileEntry] {
        guard let scopeRoot else { return [] }
        let limits = Self.walkLimits(place)
        let options = SearchWalkOptions(maxDepth: limits.depth, visitLimit: limits.entries, skipsNotLoaded: true)
        let home = dependencies.home
        let volumes = dependencies.volumes.volumes.filter { !$0.isInternal }.map(\.url)
        let engine = SearchEngine(fileSystem: dependencies.fileSystem,
                                  resolver: SearchRootResolver(home: home, computerRoots: [home], removableVolumeRoots: volumes),
                                  clock: dependencies.clock)
        var everything = search
        everything.text = ""; everything.filters = []; everything.limit = limits.entries; everything.showHidden = false
        let context = SearchRankingContext(query: everything, preferredRoots: [])
        let request = SearchRequest(text: "", scope: .currentFolder(scopeRoot), includeHidden: false)
        let walk = Task.detached { () -> [FileEntry] in
            let batch = await DatalessGuard.off { try? await engine.collect(request, context: context, options: options) }
            return batch?.results.map(\.entry) ?? []
        }
        return await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
    }

    /// The rows sent to be ranked, numbered from 1, in the order on show.
    private func rows(_ entries: [FileEntry], place: StorageFacts, scopeRoot: URL?) async -> [AISearchRow] {
        let facts = await shownFacts(entries, place: place, scopeRoot: scopeRoot)
        return zip(entries, facts).enumerated().map { index, pair in
            let (entry, fact) = pair
            let sized = entry.isDirectoryLike || entry.kind == .package ? 0 : AgentItemFilter.roundedBytes(entry.size)
            return AISearchRow(row: index + 1, name: fact.name, folder: fact.folder, kind: fact.kind, bytes: sized,
                               modified: entry.modificationDate == .distantPast ? nil : entry.modificationDate,
                               created: entry.creationDate == .distantPast ? nil : entry.creationDate,
                               cloud: entry.cloudAvailability == .evicted)
        }
    }

    /// How each entry is named to a model, in order: its name, escaped; its folder in Helm's words, never a path;
    /// and its kind's word.
    private func shownFacts(_ entries: [FileEntry], place: StorageFacts,
                            scopeRoot: URL?) async -> [(name: String, folder: String, kind: String)] {
        let home = dependencies.home.path
        var volumeFacts: [String: StorageFacts] = [:]
        var facts: [(name: String, folder: String, kind: String)] = []
        for entry in entries {
            let folder = entry.url.deletingLastPathComponent()
            var storage = StorageFacts.thisMac
            if let root = scopeRoot, folder.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents) {
                storage = place
            } else if AgentItemFilter.area(ofPath: folder.path, home: home) == .volume {
                let disk = Array(folder.standardizedFileURL.pathComponents.prefix(3)).joined(separator: "/")
                if let known = volumeFacts[disk] { storage = known } else {
                    storage = await dependencies.agent.storage.facts(for: folder)
                    volumeFacts[disk] = storage
                }
            }
            let words = AgentItemFilter.placeWords(path: folder.path, home: home, storage: storage)
            let kind = AISearchMatcher.kind(of: entry)?.rawValue ?? (entry.isDirectoryLike ? AISearchKind.folder.rawValue : "other")
            facts.append((AgentTextEscaper.escape(entry.name), words.map(AgentTextEscaper.escape).joined(separator: " / "), kind))
        }
        return facts
    }

    /// Whether an item may be a result, and a row a model sees.
    private func allows(_ entry: FileEntry) -> Bool {
        AgentItemFilter.allowsSearchRow(path: entry.url.path, name: entry.name, isHidden: entry.isHidden,
                                        home: dependencies.home.path)
    }

    // MARK: Rules

    /// How much of a place a search can cover. Cloud folders are searched for what is on this Mac; a server by name.
    static func coverage(of place: StorageFacts, scoped: Bool) -> SearchAssist.Coverage {
        guard scoped else { return .full }
        switch place.kind {
        case .iCloud, .cloud: return .onThisMacOnly
        case .network: return .namesOnly
        case .thisMac, .external: return .full
        }
    }

    /// The plan's queries for this place. Where only names can be searched, words inside files are dropped, never
    /// broadened, and a query left with nothing to look for goes. None left: the request's own words, by name.
    /// With a kind chosen in the kind row, every query that runs is kept to it, whichever way it was made.
    /// With the kind row at Any and no kind named in the request, the last and loosest query looks at every kind, so a
    /// model that guessed one, such as documents for "a receipt" that's a photo, can't hide the rest.
    static func queries(_ planned: [AISearchQuery], coverage: SearchAssist.Coverage, request: String,
                        kind: AISearchKind? = nil) -> [AISearchQuery] {
        let kept = placeQueries(planned, coverage: coverage, request: request)
        guard let kind else { return everyKindLast(kept, request: request) }
        return AISearchPlan(sort: .relevance, queries: kept).limited(to: kind).queries
    }

    /// Adds the last query again without its kinds and extensions, when every query has some and the request names
    /// no kind of file. A request that names one, in English, keeps the model's kinds as they are.
    static func everyKindLast(_ queries: [AISearchQuery], request: String) -> [AISearchQuery] {
        guard let last = queries.last, queries.allSatisfy({ !$0.kinds.isEmpty || !$0.extensions.isEmpty }),
              !namesAKind(request) else { return queries }
        var open = last
        open.kinds = []; open.extensions = []
        guard open != AISearchQuery(), !queries.contains(open) else { return queries }
        return queries + [open]
    }
    /// Whether the request names a kind of file: a word such as photo, PDF, video or folder, or an extension.
    static func namesAKind(_ request: String) -> Bool {
        let words = request.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "." }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return words.contains { kindWords.contains($0) || kindWords.contains(String($0.dropLast())) }
    }
    private static let kindWords: Set<String> = [
        "photo", "picture", "pic", "image", "screenshot", "selfie", "jpg", "jpeg", "png", "heic", "gif",
        "video", "movie", "clip", "film", "footage", "mp4", "mov",
        "document", "doc", "docx", "pdf", "spreadsheet", "presentation", "slide", "deck", "txt", "csv", "xlsx", "pptx",
        "folder", "directory", "directorie", "code", "script",
        "audio", "song", "music", "podcast", "recording", "mp3", "wav", "m4a",
        "archive", "zip", "dmg"
    ]

    private static func placeQueries(_ planned: [AISearchQuery], coverage: SearchAssist.Coverage, request: String) -> [AISearchQuery] {
        guard coverage == .namesOnly else { return planned }
        var kept: [AISearchQuery] = []
        for var query in planned {
            query.contentAll = []
            if query != AISearchQuery(), !kept.contains(query) { kept.append(query) }
        }
        if kept.isEmpty {
            let words = request.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
            let own = AISearchQuery(nameAny: words).clamped(request: request)
            if own != AISearchQuery() { kept.append(own) }
        }
        return kept
    }

    /// The facts a planned query asks about, as reason codes, in the order a reason names them.
    static func codes(of query: AISearchQuery) -> [SearchReasonCode] {
        var codes: [SearchReasonCode] = []
        if !query.nameAll.isEmpty || !query.nameAny.isEmpty { codes.append(.name) }
        if !query.contentAll.isEmpty { codes.append(.content) }
        if !query.kinds.isEmpty || !query.extensions.isEmpty { codes.append(.kind) }
        if query.dateField != .none { codes.append(.date) }
        if !query.folderAny.isEmpty { codes.append(.folder) }
        if query.sizeMinBytes > 0 || query.sizeMaxBytes > 0 { codes.append(.size) }
        return codes
    }

    /// The results in the order the person asked for, when they asked for one.
    static func sorted(_ entries: [FileEntry], by sort: AISearchSort) -> [FileEntry] {
        switch sort {
        case .relevance: return entries
        case .newest: return entries.sorted { $0.modificationDate > $1.modificationDate }
        case .oldest: return entries.sorted { $0.modificationDate < $1.modificationDate }
        case .largest: return entries.sorted { $0.size > $1.size }
        case .smallest: return entries.sorted { $0.size < $1.size }
        }
    }

    /// Depth and entries a walk may cover, by the place searched.
    static func walkLimits(_ place: StorageFacts) -> (depth: Int, entries: Int) {
        switch place.kind {
        case .thisMac, .external: return (8, 5_000)
        case .iCloud, .cloud: return (6, 5_000)
        case .network: return (4, 2_000)
        }
    }
}

/// One file Read contents read for an AI search, with what was read inside it.
private struct AISearchRead {
    let entry: FileEntry
    var summary: AgentContentSummary
}

/// What Read contents read on this Mac for one AI search, before the model looks.
private struct AISearchReading {
    /// For each planned query, the pictures and videos whose text or labels hold every word it looks for inside files.
    var found: [[FileEntry]]
    var sightings: [ItemID: AISearchSighting] = [:]
    var notDownloaded = 0
    /// Every file read, in the order the model is to look at them.
    var pool: [AISearchRead] = []
}

/// What the model said of the files it looked at in one AI search.
private struct AISearchLooked {
    /// The files it said fit, in its order within a question and question order after.
    var fits: [FileEntry] = []
    /// What it saw in each file that fits, when it said.
    var seen: [ItemID: AISearchSighting] = [:]
    var misses: Set<ItemID> = []
    /// The files in the questions it answered.
    var count = 0
    /// The files in the questions it didn't answer, and why the first of those wasn't.
    var failed = 0
    var failure: AgentFailure?
}

/// The folders of one AI search that carry macOS's hidden flag. An agent listing never enters such a folder, so an
/// item inside one is never a result or a row either, whoever found it. Each folder between the item's place (the
/// home folder, a cloud provider's folder, a disk or the Shared folder) and the item is looked up once, with
/// downloads off; one that can't be read counts as hidden.
@MainActor private final class AISearchHiddenFolders {
    private let fileSystem: any FileSystem
    private let home: URL
    private var known: [String: Bool] = [:]

    init(fileSystem: any FileSystem, home: URL) { self.fileSystem = fileSystem; self.home = home }

    /// The entries no hidden folder holds, in order.
    func outside(_ entries: [FileEntry]) async -> [FileEntry] {
        var kept: [FileEntry] = []
        for entry in entries where !Task.isCancelled {
            if await !isInHiddenFolder(entry) { kept.append(entry) }
        }
        return kept
    }

    private func isInHiddenFolder(_ entry: FileEntry) async -> Bool {
        let homeParts = home.standardizedFileURL.pathComponents.count
        let placeParts: Int
        switch AgentItemFilter.area(ofPath: entry.url.path, home: home.path) {
        case .home, .shared: placeParts = homeParts
        // Library, the cloud folder's parent and the provider's own folder. Library itself carries the flag.
        case .cloud: placeParts = homeParts + 3
        case .volume: placeParts = 3
        case .refused: return true
        }
        var folder = entry.url.standardizedFileURL.deletingLastPathComponent()
        while folder.pathComponents.count > placeParts {
            if known[folder.path] == nil {
                let lookedUp = await DatalessGuard.off { [fileSystem, folder] in try? await fileSystem.entry(at: folder) }
                known[folder.path] = lookedUp?.isHidden ?? true
            }
            if known[folder.path] == true { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }
}

/// What one AI search sends to the store, in the order it is sent. The plain search's results go through until the
/// merged list is on show; after that only the runner's lists do. Results are sent under the lock, so a plain
/// result that comes in at the same moment as the merged list can't land after it.
private final class AISearchDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let tab: TabID
    private let generation: Generation
    private let send: @Sendable (WindowStoreAction) -> Void
    private var settled = false
    private var latest: [SearchResult]?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(tab: TabID, generation: Generation, send: @escaping @Sendable (WindowStoreAction) -> Void) {
        self.tab = tab; self.generation = generation; self.send = send
    }

    /// A list from the plain search.
    func baseline(_ results: [SearchResult]) {
        let resumed: [CheckedContinuation<Void, Never>] = locked {
            latest = results
            if !settled { send(.tab(tab, .searchResults(generation, results))) }
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }

    /// The plain search's latest list, waiting a little for its first one.
    func firstBaseline(waiting seconds: Double) async -> [SearchResult] {
        if let known = locked({ latest }) { return known }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.wake()
        }
        await withCheckedContinuation { continuation in
            let ready = locked { () -> Bool in
                if latest != nil { return true }
                waiting.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        timer.cancel()
        return locked { latest } ?? []
    }

    /// The merged list. From now on the plain search's lists aren't sent.
    func settle(_ entries: [FileEntry]) {
        locked {
            settled = true
            send(.tab(tab, .searchResults(generation, Self.results(entries))))
        }
    }

    /// The ranked list, in place of the merged one.
    func update(_ entries: [FileEntry]) {
        locked { send(.tab(tab, .searchResults(generation, Self.results(entries)))) }
    }

    func assist(_ assist: SearchAssist) {
        locked { send(.tab(tab, .searchAssist(generation, assist))) }
    }

    private func wake() {
        let resumed: [CheckedContinuation<Void, Never>] = locked {
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }

    private static func results(_ entries: [FileEntry]) -> [SearchResult] {
        entries.enumerated().map { SearchResult(entry: $1, rank: $0) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// One planned query asked of Spotlight: the gathering phase only, then the query stops. Answers the paths found,
/// or what was found by the time limit.
@MainActor private final class AISearchSpotlightGather: NSObject {
    private let metadata = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[URL], Never>?
    private let limit: Int

    private init(predicate: NSPredicate, scopes: [Any], limit: Int) {
        self.limit = limit
        super.init()
        metadata.predicate = predicate
        metadata.searchScopes = scopes
    }

    static func gather(_ predicate: NSPredicate, scopes: [Any], limit: Int, seconds: Double) async -> [URL] {
        let query = AISearchSpotlightGather(predicate: predicate, scopes: scopes, limit: limit)
        return await withTaskCancellationHandler {
            await query.start(seconds: seconds)
        } onCancel: {
            Task { @MainActor in query.finish() }
        }
    }

    private func start(seconds: Double) async -> [URL] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadata,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            guard metadata.start() else { finish(); return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        metadata.disableUpdates()
        var urls: [URL] = []
        for index in 0..<min(metadata.resultCount, limit) {
            if let item = metadata.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        metadata.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        continuation.resume(returning: urls)
    }
}
#endif
