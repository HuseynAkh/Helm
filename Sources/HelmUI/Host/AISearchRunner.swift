#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmSearch

/// Searches with a model's help: plan, fan out, fuse, rank.
///
/// The plain search on the person's own words runs first and is shown at once. The model then plans up to six
/// typed queries, which Helm runs here (Spotlight, and a walk of the folder searched), checks again item by item,
/// and merges with the plain results by reciprocal rank fusion. A second question orders the best rows. The runner
/// is the only sender of results for such a search, so once the merged list is on show a late plain result can't
/// put the plain order back. It runs in the tab's search lane: Escape, an edit or another search cancels it, and an
/// answer that arrives after that is dropped by the search's generation.
///
/// Every item that is merged or sent passes `AgentItemFilter.allowsSearchRow` and sits in no folder with the hidden
/// flag, whatever Show Hidden Files says. Hits are looked up with downloads off.
/// A model never sees a path: rows carry the name, the folder in Helm's words, the kind, a rounded size and dates.
///
/// With the kind row's Read contents switch on, a planned query's words for inside files are also looked for inside
/// pictures and videos: up to 200 of them in the search's place, read on this Mac by `AgentContentReader` with the
/// person's permit, and kept for the search session by path and modification date. A picture or a video whose text
/// or whose labels hold every one of those words is a match of that query, and its reason says what was seen. What
/// was read inside a file is never sent; a file that isn't downloaded is never read, and the status bar counts it.
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
    /// What this search session has read inside pictures and videos.
    let memo = AgentContentMemo()
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
        guard query.usesAI, case .ready(_, _, _, let isLocal) = dependencies.agent.runtime.state else {
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
            await self?.assist(query, client: client, isLocal: isLocal, delivery: delivery)
        }
        return StoreEffectCancellation {
            plain.cancel()
            task.cancel()
        }
    }

    // MARK: The steps

    private func assist(_ query: SearchQuery, client: any AgentModelClient, isLocal: Bool, delivery: AISearchDelivery) async {
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
            // The name matches stay on show, and Return again tries again.
            delivery.assist(SearchAssist(phase: .failed, coverage: coverage))
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
        // 2b. Inside pictures and videos, with Read contents on. A server is searched by name only.
        var sightings: [ItemID: AISearchSighting] = [:]
        var notDownloaded = 0
        if let looking, coverage != .namesOnly {
            let seen = await lookInside(queries, walked: walked, scopeRoot: scopeRoot, coverage: coverage,
                                        hiddenFolders: hiddenFolders, reader: looking.reader, permit: looking.permit)
            guard !Task.isCancelled else { return }
            for (index, hits) in seen.found.enumerated() where found.indices.contains(index) {
                let known = Set(found[index].map(\.id))
                found[index] += hits.filter { !known.contains($0.id) }
            }
            sightings = seen.sightings
            notDownloaded = seen.notDownloaded
        }

        // 3. Fuse with the plain search, and show that at once.
        let plainResults = await delivery.firstBaseline(waiting: Self.baselineWaitSeconds)
        guard !Task.isCancelled else { return }
        let plainKept = await hiddenFolders.outside(plainResults.map(\.entry).filter { allows($0) })
        guard !Task.isCancelled else { return }
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
        var order = RankFusion.fuse(lists).prefix(max(1, query.limit)).compactMap { entries[$0] }
        order = Self.sorted(order, by: plan.sort)

        let calendar = Calendar.current, locale = Locale.current
        func queryReason(_ entry: FileEntry) -> SearchReason? {
            guard let index = foundBy[entry.id] else { return nil }
            let planned = queries[index]
            return SearchReasonBuilder.reason(codes: Self.codes(of: planned), entry: entry, query: planned,
                                              scopeRoot: scopeRoot, calendar: calendar, locale: locale,
                                              sighting: sightings[entry.id])
        }
        var reasons: [ItemID: SearchReason] = [:]
        for entry in order { reasons[entry.id] = queryReason(entry) }
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

        // 4. Rank. A sorted list, or a handful of results, needs no judgement.
        if plan.sort == .relevance, order.count > 5 {
            let shown = Array(order.prefix(AISearchSession.maxRows(isLocal: isLocal)))
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
                order = first + order.filter { !chosen.contains($0.id) }
                delivery.update(order)
            }
            // A failed ranking leaves the merged list, with the queries' reasons.
        }
        guard !Task.isCancelled else { return }
        // How the request was read, from the strictest query; with no query left, the count alone. The kind the
        // person chose ends it: "12 matches · “beach” · Photos".
        var readAs = SearchReasonBuilder.readAs(count: order.count, query: shown(queries.first ?? AISearchQuery()), calendar: calendar,
                                                locale: locale)
        if let kind = query.kind { readAs += " · " + AgentText.searchKindShown(kind) }
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
                        guard asksSpotlight else { return (index, []) }
                        let scopes: [Any] = scopeRoot.map { [$0.path] } ?? [NSMetadataQueryLocalComputerScope]
                        let urls = await AISearchSpotlightGather.gather(AISearchPredicates.predicate(for: planned), scopes: scopes,
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

    // MARK: Inside pictures and videos

    /// What Read contents finds for the queries that look for words inside files: for each such query, the pictures
    /// and videos it describes in every other way, from the walk of the folder searched and, on this Mac outside a
    /// folder, from Spotlight; read on this Mac, 200 at most for the whole search, newest first, and kept when every
    /// word is in what they show or the text they hold. Answers each query's matches, what was seen in each, and how
    /// many weren't read because they aren't downloaded.
    private func lookInside(_ queries: [AISearchQuery], walked: [FileEntry], scopeRoot: URL?, coverage: SearchAssist.Coverage,
                            hiddenFolders: AISearchHiddenFolders, reader: any AgentContentReading,
                            permit: AgentContentPermit) async -> (found: [[FileEntry]], sightings: [ItemID: AISearchSighting], notDownloaded: Int) {
        let looks = queries.map(Self.visualQuery)
        var candidates: [ItemID: FileEntry] = [:]
        for (index, look) in looks.enumerated() {
            guard let look else { continue }
            var pool = walked
            if scopeRoot == nil {
                pool += await spotlightHits(for: look, original: queries[index], coverage: coverage, hiddenFolders: hiddenFolders)
            }
            for entry in pool where candidates[entry.id] == nil && allows(entry)
                && AISearchMatcher.matches(entry, look, scopeRoot: scopeRoot, contentVerified: false) {
                candidates[entry.id] = entry
            }
        }
        let chosen = candidates.values.sorted { $0.modificationDate > $1.modificationDate }.prefix(AgentContentLimits.searchCandidates)
        guard !chosen.isEmpty, !Task.isCancelled else { return (queries.map { _ in [] }, [:], 0) }

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
            let requests = unread.map { entry in
                AgentContentRequest(path: entry.url.path, name: entry.name, identity: entry.objectIdentity,
                                    typeIdentifier: entry.contentTypeIdentifier, size: entry.size,
                                    modified: entry.modificationDate, isDataless: false)
            }
            let answers = await reader.summaries(of: requests, permit: permit, seconds: AgentContentLimits.secondsPerSearch)
            for (entry, summary) in zip(unread, answers) {
                if summary.status == .not_downloaded { notDownloaded += 1 }
                memo.keep(summary, path: entry.url.path, modified: entry.modificationDate)
                summaries[entry.id] = summary
            }
        }

        var found = queries.map { _ in [FileEntry]() }
        var sightings: [ItemID: AISearchSighting] = [:]
        for (index, look) in looks.enumerated() {
            guard let look else { continue }
            for entry in chosen where AISearchMatcher.matches(entry, look, scopeRoot: scopeRoot, contentVerified: false) {
                guard let summary = summaries[entry.id],
                      let sighting = AISearchMatcher.sighting(of: queries[index].contentAll, in: summary) else { continue }
                found[index].append(entry)
                if sightings[entry.id] == nil { sightings[entry.id] = sighting }
            }
        }
        return (found, sightings, notDownloaded)
    }

    /// A query that looks for words inside files, as one for the pictures and videos it describes: the same names,
    /// folders, dates and sizes, with no words inside files, and kept to pictures and videos. Nil for a query with no
    /// such words, and for one kept to kinds that are neither.
    static func visualQuery(_ query: AISearchQuery) -> AISearchQuery? {
        guard !query.contentAll.isEmpty else { return nil }
        var look = query
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
            guard !dependencies.agent.secrets.isMemoryOnly, coverage != .namesOnly else { return [] }
            urls = await AISearchSpotlightGather.gather(AISearchPredicates.predicate(for: look), scopes: [NSMetadataQueryLocalComputerScope],
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
        let home = dependencies.home.path
        var volumeFacts: [String: StorageFacts] = [:]
        var rows: [AISearchRow] = []
        for (index, entry) in entries.enumerated() {
            let folder = entry.url.deletingLastPathComponent()
            var facts = StorageFacts.thisMac
            if let root = scopeRoot, folder.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents) {
                facts = place
            } else if AgentItemFilter.area(ofPath: folder.path, home: home) == .volume {
                let disk = Array(folder.standardizedFileURL.pathComponents.prefix(3)).joined(separator: "/")
                if let known = volumeFacts[disk] { facts = known } else {
                    facts = await dependencies.agent.storage.facts(for: folder)
                    volumeFacts[disk] = facts
                }
            }
            let words = AgentItemFilter.placeWords(path: folder.path, home: home, storage: facts)
            let kind = AISearchMatcher.kind(of: entry)?.rawValue ?? (entry.isDirectoryLike ? AISearchKind.folder.rawValue : "other")
            let sized = entry.isDirectoryLike || entry.kind == .package ? 0 : AgentItemFilter.roundedBytes(entry.size)
            rows.append(AISearchRow(row: index + 1, name: AgentTextEscaper.escape(entry.name),
                                    folder: words.map(AgentTextEscaper.escape).joined(separator: " / "), kind: kind, bytes: sized,
                                    modified: entry.modificationDate == .distantPast ? nil : entry.modificationDate,
                                    created: entry.creationDate == .distantPast ? nil : entry.creationDate,
                                    cloud: entry.cloudAvailability == .evicted))
        }
        return rows
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
    static func queries(_ planned: [AISearchQuery], coverage: SearchAssist.Coverage, request: String,
                        kind: AISearchKind? = nil) -> [AISearchQuery] {
        let kept = placeQueries(planned, coverage: coverage, request: request)
        guard let kind else { return kept }
        return AISearchPlan(sort: .relevance, queries: kept).limited(to: kind).queries
    }

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
