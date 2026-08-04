//
//  LRCLibService.swift
//  Lychee
//
//  LRCLIB API integration — parallel fetch + scoring algorithm
//

import Foundation

/// Response from LRCLIB API
struct LRCLIBResponse: Codable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

/// Service for fetching lyrics from LRCLIB
class LRCLibService {
    static let shared = LRCLibService()

    private let getURL    = "https://lrclib.net/api/get"
    private let searchURL = "https://lrclib.net/api/search"
    private var currentTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private let autosaveDelay: TimeInterval = 30

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public API

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    func fetchLyrics(for track: TrackInfo) {
        currentTask?.cancel()
        currentTask = nil
        TelemetryService.shared.recordActiveUse()
        let startedAt = Date()
        let trackID = track.trackID
        // Cache read happens on a background thread to avoid blocking the main
        // thread with synchronous disk I/O (which caused a visible ~100ms freeze).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cached = LyricsCache.shared.get(artist: track.artist, track: track.name)
            DispatchQueue.main.async {
                guard TrackState.shared.currentTrackID == trackID else { return }
                if let cached {
                    lycheeDebugLog("[LRCLib] Cache hit for: \(track.name) (\(cached.type))")
                    self.applyCacheHit(cached, startedAt: startedAt)
                } else {
                    lycheeDebugLog("[LRCLib] Fetching: \(track.name) — \(track.artist)")
                    TrackState.shared.setLoading()
                    self.currentTask = Task { await self.performFetch(for: track, startedAt: startedAt) }
                }
            }
        }
    }

    /// Re-fetches lyrics for a track, bypassing the cache entirely.
    /// Used by the Refresh button to retry after a failed or missing fetch.
    func refetchLyrics(for track: TrackInfo) {
        currentTask?.cancel()
        currentTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        guard TrackState.shared.currentTrackID == track.trackID else { return }
        TelemetryService.shared.recordActiveUse()
        let startedAt = Date()
        lycheeDebugLog("[LRCLib] Refetching (cache bypass): \(track.name) — \(track.artist)")
        TrackState.shared.setLoading()
        currentTask = Task { await self.performFetch(for: track, startedAt: startedAt) }
    }

    // Step through allCandidates by delta (+1 = next, -1 = prev). Call from main thread.
    func stepCandidate(by delta: Int) {
        let candidates = TrackState.shared.allCandidates
        guard candidates.count > 1 else { return }
        let newIndex = (TrackState.shared.candidateIndex + delta + candidates.count) % candidates.count
        TrackState.shared.lastCycleDirection = delta
        TrackState.shared.candidateIndex = newIndex
        let candidate = candidates[newIndex]
        if candidate.isSynced {
            TrackState.shared.setLyrics(parseLRC(candidate.lrc))
        } else {
            TrackState.shared.setPlainLyrics(candidate.lrc)
        }
        startAutosaveTimer()
    }

    // Save the currently displayed candidate to cache. Call from main thread.
    func saveCurrentCandidate() {
        let candidates = TrackState.shared.allCandidates
        let index = TrackState.shared.candidateIndex
        guard index < candidates.count else { return }
        let candidate = candidates[index]
        let entryType: LyricsCacheEntry.EntryType = candidate.isSynced ? .synced : .plain
        LyricsCache.shared.save(
            artist: TrackState.shared.artistName,
            track: TrackState.shared.trackName,
            entry: LyricsCacheEntry(type: entryType, content: candidate.lrc, savedAt: Date().timeIntervalSince1970)
        )
        TrackState.shared.savedCandidateLRC = candidate.lrc
        autosaveTask?.cancel()  // manual save supersedes pending autosave
        lycheeDebugLog("[LRCLib] Saved candidate \(index + 1)/\(candidates.count): \(candidate.trackName)")
    }

    // MARK: - Cache hit

    private func applyCacheHit(_ entry: LyricsCacheEntry, startedAt: Date) {
        switch entry.type {
        case .synced:
            guard let lrc = entry.content else { return }
            let parsed = parseLRC(lrc)
            DispatchQueue.main.async {
                // Restore the cached entry as the sole known candidate so the
                // cycling row appears immediately (Save shows as disabled = already saved).
                let cached = LyricsCandidate(
                    lrc:        lrc,
                    trackName:  TrackState.shared.trackName,
                    artistName: TrackState.shared.artistName,
                    score:      0,
                    isSynced:   true
                )
                TrackState.shared.allCandidates    = [cached]
                TrackState.shared.candidateIndex   = 0
                TrackState.shared.savedCandidateLRC = lrc
                TrackState.shared.setLyrics(parsed)
                TelemetryService.shared.recordLyricsOutcome(
                    .synced,
                    latency: Date().timeIntervalSince(startedAt)
                )
            }
            // Background search to hydrate the full candidate list so the user
            // can cycle to alternatives without pressing Restart.
            currentTask = Task { [weak self] in
                guard let self else { return }
                await self.hydrateCandidatesFromCache(cachedLRC: lrc)
            }
        case .plain:
            guard let plain = entry.content else { return }
            DispatchQueue.main.async {
                let candidate = LyricsCandidate(
                    lrc:        plain,
                    trackName:  TrackState.shared.trackName,
                    artistName: TrackState.shared.artistName,
                    score:      0,
                    isSynced:   false
                )
                TrackState.shared.allCandidates    = [candidate]
                TrackState.shared.candidateIndex   = 0
                TrackState.shared.savedCandidateLRC = plain
                TrackState.shared.setPlainLyrics(plain)
                TelemetryService.shared.recordLyricsOutcome(
                    .plain,
                    latency: Date().timeIntervalSince(startedAt)
                )
            }
        case .notFound:
            DispatchQueue.main.async {
                TrackState.shared.setNoLyrics()
                TelemetryService.shared.recordLyricsOutcome(
                    .notFound,
                    latency: Date().timeIntervalSince(startedAt)
                )
            }
        }
    }

    // After a cache hit, run the same search queries in background and rebuild
    // allCandidates so the cycling row has the full option set.
    private func hydrateCandidatesFromCache(cachedLRC: String) async {
        let trackName  = await MainActor.run { TrackState.shared.trackName }
        let artistName = await MainActor.run { TrackState.shared.artistName }
        guard !trackName.isEmpty else { return }
        await MainActor.run { TrackState.shared.isHydrating = true }

        let searchName = simplifyForSearch(trackName)
        var allResults = await search(query: searchName)
        if !artistName.isEmpty {
            let artistResults = await search(query: "\(artistName) \(searchName)")
            allResults += artistResults
        }
        if Task.isCancelled {
            await MainActor.run { TrackState.shared.isHydrating = false }
            return
        }
        let rawResponses: [(response: LRCLIBResponse, sourceScore: Int)] = allResults.map { ($0, 0) }

        var seenContent = Set<String>()
        var scoredSynced: [LyricsCandidate] = []
        for (response, sourceScore) in rawResponses {
            guard let lrc = response.syncedLyrics, !lrc.isEmpty else { continue }
            let key = String(lrc.prefix(200))
            guard !seenContent.contains(key) else { continue }
            seenContent.insert(key)
            let langScore  = isPreferredLanguage(lrc) ? 50 : 0
            let titleScore = titleSimilarity(response.trackName ?? "", trackName)
            let artScore   = artistInTitleBonus(response.trackName ?? "", artistName)
            scoredSynced.append(LyricsCandidate(
                lrc:        lrc,
                trackName:  response.trackName  ?? "",
                artistName: response.artistName ?? "",
                score:      100 + langScore + titleScore + artScore + sourceScore,
                isSynced:   true
            ))
        }

        var contentGroups: [String: LyricsCandidate] = [:]
        for candidate in scoredSynced {
            let key = lyricsTextKey(candidate.lrc)
            if let existing = contentGroups[key] {
                if candidate.score > existing.score { contentGroups[key] = candidate }
            } else {
                contentGroups[key] = candidate
            }
        }

        // Always include the cached entry as a candidate (may have been user-saved
        // and not present in search results).
        let cachedKey = lyricsTextKey(cachedLRC)
        if contentGroups[cachedKey] == nil {
            contentGroups[cachedKey] = LyricsCandidate(
                lrc:        cachedLRC,
                trackName:  trackName,
                artistName: artistName,
                score:      0,
                isSynced:   true
            )
        }

        let candidates = contentGroups.values.sorted { $0.score > $1.score }
        guard candidates.count > 1 else {
            await MainActor.run { TrackState.shared.isHydrating = false }
            return
        }

        lycheeDebugLog("[LRCLib] Cache hydration: \(candidates.count) unique candidates found")
        await MainActor.run {
            TrackState.shared.isHydrating = false
            // Only update if the track hasn't changed since we started
            guard TrackState.shared.trackName == trackName else { return }
            TrackState.shared.allCandidates = candidates
            // Keep candidateIndex pointing at whichever candidate matches the
            // currently displayed (cached) lyrics.
            if let cachedIdx = candidates.firstIndex(where: { $0.lrc == cachedLRC }) {
                TrackState.shared.candidateIndex = cachedIdx
            }
        }
    }

    // MARK: - Fetch Strategy

    private func performFetch(for track: TrackInfo, startedAt: Date) async {
        if Task.isCancelled { return }

        let artistCandidates = track.artist.isEmpty ? [] : buildArtistCandidates(from: track.artist)

        // Show "taking longer" after 4s if still in flight
        let phaseTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { TrackState.shared.setLoadingPhase(.takingLonger) }
        }
        defer { phaseTask.cancel() }

        // ── Phase 1: gather everything in parallel ────────────────────────
        var rawResponses: [(response: LRCLIBResponse, sourceScore: Int)] = []
        var earlyCommitted = false

        await withTaskGroup(of: [(LRCLIBResponse, Int)].self) { group in

            // GET full: first artist + album + duration (most specific)
            if let first = artistCandidates.first, !track.album.isEmpty, track.duration > 0 {
                group.addTask {
                    if let r = await self.get(artist: first, track: track.name,
                                              album: track.album, duration: Int(track.duration)) {
                        return [(r, 20)]
                    }
                    return []
                }
            }

            // GET broad: each artist candidate without album/duration
            for artist in artistCandidates {
                group.addTask {
                    if let r = await self.get(artist: artist, track: track.name,
                                              album: nil, duration: nil) {
                        return [(r, 10)]
                    }
                    return []
                }
            }

            let searchName = self.simplifyForSearch(track.name)

            // SEARCH by track name only — reliable even when Spotify has wrong artist.
            group.addTask {
                let results = await self.search(query: searchName)
                return results.map { ($0, 0) }
            }

            // SEARCH by primaryArtist+trackName — sourceScore 5 marks this as higher-
            // confidence than name-only SEARCH (artist is already baked into the query),
            // so the early-commit check only needs an exact title match, not artist too.
            if let first = artistCandidates.first, !first.isEmpty {
                group.addTask {
                    let results = await self.search(query: "\(first) \(searchName)")
                    return results.map { ($0, 5) }
                }
            }

            // Early-commit: show synced lyrics as soon as a high-confidence result arrives,
            // before all tasks complete. Three tiers:
            //   GET result (sourceScore >= 10): any preferred-language synced match qualifies.
            //   Artist+name SEARCH (sourceScore == 5): exact title match is enough — artist
            //     was already in the query so LRCLIB's own ranking handles artist relevance.
            //   Name-only SEARCH (sourceScore == 0): requires exact title AND exact artist match.
            for await batch in group {
                rawResponses.append(contentsOf: batch)
                if !earlyCommitted {
                    for (resp, sourceScore) in batch {
                        guard let lrc = resp.syncedLyrics, !lrc.isEmpty,
                              isPreferredLanguage(lrc) else { continue }
                        let qualifies: Bool
                        if sourceScore >= 10 {
                            qualifies = true
                        } else if sourceScore == 5 {
                            // Artist+name SEARCH: only need exact title match
                            let titleScore = titleSimilarity(resp.trackName ?? "", track.name)
                            qualifies = titleScore == 30
                        } else {
                            let titleScore = titleSimilarity(resp.trackName ?? "", track.name)
                            let artScore   = artistSimilarity(resp.artistName ?? "", track.artist)
                            qualifies = titleScore == 30 && artScore == 30
                        }
                        guard qualifies else { continue }
                        earlyCommitted = true
                        let parsed = self.parseLRC(lrc)
                        let earlyCandidate = LyricsCandidate(
                            lrc:        lrc,
                            trackName:  resp.trackName  ?? "",
                            artistName: resp.artistName ?? "",
                            score:      sourceScore,
                            isSynced:   true
                        )
                        await MainActor.run {
                            TrackState.shared.allCandidates  = [earlyCandidate]
                            TrackState.shared.candidateIndex = 0
                            TrackState.shared.isHydrating    = true
                            TrackState.shared.setLyrics(parsed)
                        }
                        TelemetryService.shared.recordLyricsLatency(
                            Date().timeIntervalSince(startedAt)
                        )
                        break
                    }
                }
            }
        }

        if Task.isCancelled { return }

        // ── Phase 2: score + select via active algorithm ─────────────────
        let (syncedCandidates, plainCandidates) = selectCandidates(from: rawResponses, track: track)

        // ── Phase 3: commit best, expose all for cycling ──────────────────
        if let best = syncedCandidates.first {
            let parsed = parseLRC(best.lrc)
            LyricsCache.shared.save(
                artist: track.artist, track: track.name,
                entry: LyricsCacheEntry(type: .synced, content: best.lrc,
                                        savedAt: Date().timeIntervalSince1970)
            )
            lycheeDebugLog("[LRCLib] ✓ \(syncedCandidates.count) synced + \(plainCandidates.count) plain candidates — best score \(best.score): \"\(best.trackName)\" by \(best.artistName)")
            for (i, c) in syncedCandidates.enumerated() {
                lycheeDebugLog("[LRCLib]   #\(i+1) score=\(c.score) preferred=\(isPreferredLanguage(c.lrc)) synced=\(c.isSynced) — \"\(c.trackName)\" by \(c.artistName)")
            }
            await MainActor.run {
                TrackState.shared.isHydrating    = false
                TrackState.shared.allCandidates  = syncedCandidates + plainCandidates
                TrackState.shared.candidateIndex = 0
                // savedCandidateLRC intentionally NOT set here — only set on cache hit
                // (restoring a prior manual save) or explicit user Save press.
                TrackState.shared.setLyrics(parsed)
                TelemetryService.shared.recordLyricsOutcome(
                    .synced,
                    latency: earlyCommitted ? nil : Date().timeIntervalSince(startedAt)
                )
            }
            startAutosaveTimer()
            return
        }

        // No synced at all — use plain candidates (accessible in cycling row)
        if let best = plainCandidates.first {
            lycheeDebugLog("[LRCLib] ✓ Plain lyrics only")
            LyricsCache.shared.save(
                artist: track.artist, track: track.name,
                entry: LyricsCacheEntry(type: .plain, content: best.lrc,
                                        savedAt: Date().timeIntervalSince1970)
            )
            await MainActor.run {
                TrackState.shared.isHydrating    = false
                TrackState.shared.allCandidates  = plainCandidates
                TrackState.shared.candidateIndex = 0
                TrackState.shared.setPlainLyrics(best.lrc)
                TelemetryService.shared.recordLyricsOutcome(
                    .plain,
                    latency: earlyCommitted ? nil : Date().timeIntervalSince(startedAt)
                )
            }
            startAutosaveTimer()
            return
        }

        // Nothing found
        lycheeDebugLog("[LRCLib] ✗ No lyrics found")
        LyricsCache.shared.save(
            artist: track.artist, track: track.name,
            entry: LyricsCacheEntry(type: .notFound, content: nil,
                                    savedAt: Date().timeIntervalSince1970)
        )
        await MainActor.run {
            TrackState.shared.isHydrating = false
            TrackState.shared.setNoLyrics()
            TelemetryService.shared.recordLyricsOutcome(
                .notFound,
                latency: earlyCommitted ? nil : Date().timeIntervalSince(startedAt)
            )
        }
    }

    // MARK: - Candidate selection (dispatches to legacy or improved algorithm)

    private func selectCandidates(
        from rawResponses: [(LRCLIBResponse, Int)],
        track: TrackInfo
    ) -> (synced: [LyricsCandidate], plain: [LyricsCandidate]) {
        let improved = TrackState.shared.algorithmVersion == .improved

        var seenPlain = Set<String>()
        var scoredSynced: [LyricsCandidate] = []
        var plainPool: [(text: String, score: Int)] = []

        for (response, origSource) in rawResponses {
            let sourceScore: Int
            if improved {
                switch origSource { case 20: sourceScore = 60; case 10: sourceScore = 40; default: sourceScore = 0 }
            } else {
                sourceScore = origSource
            }

            if let lrc = response.syncedLyrics, !lrc.isEmpty {
                let langScore  = isPreferredLanguage(lrc) ? 50 : (improved ? -40 : 0)
                let titleScore = titleSimilarity(response.trackName ?? "", track.name)
                let artScore   = improved
                    ? artistSimilarity(response.artistName ?? "", track.artist)
                    : artistInTitleBonus(response.trackName ?? "", track.artist)
                let durScore   = improved ? durationMatch(response.duration, track.duration) : 0
                let total      = 100 + langScore + titleScore + artScore + durScore + sourceScore
                scoredSynced.append(LyricsCandidate(
                    lrc: lrc, trackName: response.trackName ?? "",
                    artistName: response.artistName ?? "", score: total, isSynced: true
                ))
            }

            if let plain = response.plainLyrics, !plain.isEmpty {
                let key = String(plain.prefix(120))
                if !seenPlain.contains(key) {
                    seenPlain.insert(key)
                    let langScore  = isPreferredLanguage(plain) ? 50 : (improved ? -40 : 0)
                    let titleScore = titleSimilarity(response.trackName ?? "", track.name)
                    plainPool.append((plain, langScore + titleScore + sourceScore))
                }
            }
        }

        // Group synced by lyric text content; keep highest-scored variant per group
        var contentGroups: [String: LyricsCandidate] = [:]
        for c in scoredSynced {
            let key = lyricsTextKey(c.lrc)
            if let ex = contentGroups[key] { if c.score > ex.score { contentGroups[key] = c } }
            else { contentGroups[key] = c }
        }
        let allSynced = contentGroups.values.sorted { $0.score > $1.score }

        let synced: [LyricsCandidate]
        if improved {
            synced = allSynced   // language handled by penalty; no hard removal
        } else {
            let hasPreferred = allSynced.contains { isPreferredLanguage($0.lrc) }
            synced = hasPreferred ? allSynced.filter { isPreferredLanguage($0.lrc) } : allSynced
        }

        plainPool.sort { $0.score > $1.score }
        let plain: [LyricsCandidate]
        if improved {
            plain = plainPool.map { LyricsCandidate(lrc: $0.text, trackName: "", artistName: "", score: $0.score, isSynced: false) }
        } else {
            plain = plainPool.prefix(3).map { LyricsCandidate(lrc: $0.text, trackName: "", artistName: "", score: $0.score, isSynced: false) }
        }

        return (synced, plain)
    }

    // MARK: - HTTP

    private func get(
        artist: String,
        track: String,
        album: String?,
        duration: Int?,
        timeout: TimeInterval = 6
    ) async -> LRCLIBResponse? {
        var components = URLComponents(string: getURL)!
        var items = [URLQueryItem(name: "track_name", value: track)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let a = album,    !a.isEmpty { items.append(URLQueryItem(name: "album_name",  value: a)) }
        if let d = duration, d > 0      { items.append(URLQueryItem(name: "duration",    value: String(d))) }
        components.queryItems = items
        guard let url = components.url else { return nil }

        lycheeDebugLog("[LRCLib] GET \(url.absoluteString)")
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LRCLIBResponse.self, from: data)
        } catch {
            lycheeDebugLog("[LRCLib] GET failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func search(query: String, timeout: TimeInterval = 8) async -> [LRCLIBResponse] {
        var components = URLComponents(string: searchURL)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        lycheeDebugLog("[LRCLib] SEARCH \(url.absoluteString)")
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        do {
            // Decode as [LRCLIBResponse?] so null elements in the array don't fail the whole decode.
            return try JSONDecoder().decode([LRCLIBResponse?].self, from: data).compactMap { $0 }
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            lycheeDebugLog("[LRCLib] SEARCH decode failed (\(query)) — response: \(preview)")
            return []
        }
    }

    // MARK: - Scoring helpers

    // Strips parenthetical/bracketed suffixes from a Spotify track name so it
    // works as a clean LRCLIB search query.
    // "Janiye (from the Netflix Film "Chor Nikal Ke Bhaga")" → "Janiye"
    // "Blinding Lights [Official Audio]" → "Blinding Lights"
    private func simplifyForSearch(_ name: String) -> String {
        var result = name
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let lo = result.range(of: open) {
                if let hi = result[lo.upperBound...].range(of: close) {
                    result.removeSubrange(lo.lowerBound..<hi.upperBound)
                } else {
                    result = String(result[..<lo.lowerBound])
                    break
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Strips LRC timestamps and normalizes text into a content fingerprint.
    // Used to group candidates that have identical lyrics but different timing/metadata.
    private func lyricsTextKey(_ lrc: String) -> String {
        let pattern = #"^\[\d+:\d{2}\.\d+\]\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return String(lrc.prefix(300))
        }
        var lines: [String] = []
        for line in lrc.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 2 else { continue }
            let text = ns.substring(with: match.range(at: 1))
                         .trimmingCharacters(in: .whitespaces)
                         .lowercased()
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }

    // Gives +15 when the Spotify artist name appears inside the LRCLIB response's track
    // title — catches entries stored as "Song by Artist" with an empty artistName field.
    // e.g. "Fakira by Sanam Puri" (trackName) + "Sanam Puri" (Spotify artist) → +15
    private func artistInTitleBonus(_ responseTitle: String, _ queryArtist: String) -> Int {
        guard !queryArtist.isEmpty else { return 0 }
        let rt = normalizeTitle(responseTitle)
        for candidate in buildArtistCandidates(from: queryArtist) {
            let a = normalizeTitle(candidate)
            guard a.count > 2, rt.contains(a) else { continue }
            return 15
        }
        return 0
    }

    // Returns 0–30: exact normalized match = 30, contains = 20, word overlap = 0–15
    private func titleSimilarity(_ responseTitle: String, _ queryTitle: String) -> Int {
        let a = normalizeTitle(responseTitle)
        let b = normalizeTitle(queryTitle)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 30 }
        if a.contains(b) || b.contains(a) { return 20 }
        let wa = Set(a.split(separator: " ").map(String.init))
        let wb = Set(b.split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !wb.isEmpty else { return 0 }
        let overlap = wa.intersection(wb).count
        return Int(Double(overlap) / Double(wb.count) * 15.0)
    }

    private func normalizeTitle(_ s: String) -> String {
        s.lowercased()
         .folding(options: .diacriticInsensitive, locale: nil)
         .filter { $0.isLetter || $0.isWhitespace }
         .split(separator: " ")
         .joined(separator: " ")
    }

    // Returns true if text is predominantly Latin or Devanagari (Hindi/Marathi).
    // Rejects if > 25% of script letters are in other scripts (Gurmukhi, Arabic, CJK, Cyrillic…)
    private func isPreferredLanguage(_ text: String) -> Bool {
        var preferred = 0
        var foreign   = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 0x0041 && v <= 0x005A) ||
               (v >= 0x0061 && v <= 0x007A) ||
               (v >= 0x00C0 && v <= 0x024F) {
                preferred += 1
            } else if v >= 0x0900 && v <= 0x097F {
                preferred += 1
            } else if v >= 0x0080 {
                switch scalar.properties.generalCategory {
                case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter,
                     .modifierLetter,  .otherLetter:
                    foreign += 1
                default:
                    break
                }
            }
        }
        let total = preferred + foreign
        guard total > 15 else { return true }
        return Double(foreign) / Double(total) < 0.25
    }

    // Splits "Artist A, Artist B feat. Artist C & Artist D" into
    // ["Artist A, Artist B feat. Artist C & Artist D", "Artist A", "Artist B", "Artist C", "Artist D"]
    private func buildArtistCandidates(from artist: String) -> [String] {
        var candidates = [artist]
        let components = artist
            .components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: " feat. ") }
            .flatMap { $0.components(separatedBy: " feat ")  }
            .flatMap { $0.components(separatedBy: " & ")     }
            .map     { $0.trimmingCharacters(in: .whitespaces) }
            .filter  { !$0.isEmpty }
        for c in components where c != artist && !candidates.contains(c) {
            candidates.append(c)
        }
        return candidates
    }

    // MARK: - Autosave

    private func startAutosaveTimer() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(autosaveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.autosaveIfNeeded() }
        }
    }

    private func autosaveIfNeeded() {
        let candidates = TrackState.shared.allCandidates
        let index = TrackState.shared.candidateIndex
        guard index < candidates.count,
              TrackState.shared.savedCandidateLRC == nil else { return }
        let candidate = candidates[index]
        let entryType: LyricsCacheEntry.EntryType = candidate.isSynced ? .synced : .plain
        LyricsCache.shared.save(
            artist: TrackState.shared.artistName,
            track: TrackState.shared.trackName,
            entry: LyricsCacheEntry(type: entryType, content: candidate.lrc, savedAt: Date().timeIntervalSince1970)
        )
        TrackState.shared.savedCandidateLRC = candidate.lrc
        lycheeDebugLog("[LRCLib] Autosaved after \(Int(autosaveDelay))s: \"\(candidate.trackName)\"")
    }

    // MARK: - Debug: Fetch Layer (shared raw responses for both algorithms)

    #if DEBUG

    // Replicates the parallel fetch from performFetch but makes no network decisions:
    // no early-commit, no scoring, no UI updates. Returns every (response, sourceScore)
    // pair exactly as the production fetch would collect them.
    internal func fetchAllResponses(for track: TrackInfo) async -> [(response: LRCLIBResponse, sourceScore: Int)] {
        let artistCandidates = track.artist.isEmpty ? [] : buildArtistCandidates(from: track.artist)
        var rawResponses: [(response: LRCLIBResponse, sourceScore: Int)] = []

        await withTaskGroup(of: [(LRCLIBResponse, Int)].self) { group in
            if let first = artistCandidates.first, !track.album.isEmpty, track.duration > 0 {
                group.addTask {
                    if let r = await self.get(artist: first, track: track.name,
                                              album: track.album, duration: Int(track.duration)) {
                        return [(r, 20)]
                    }
                    return []
                }
            }
            for artist in artistCandidates {
                group.addTask {
                    if let r = await self.get(artist: artist, track: track.name, album: nil, duration: nil) {
                        return [(r, 10)]
                    }
                    return []
                }
            }
            let searchName = self.simplifyForSearch(track.name)
            group.addTask {
                let results = await self.search(query: searchName)
                return results.map { ($0, 0) }
            }
            if let first = artistCandidates.first, !first.isEmpty {
                group.addTask {
                    let results = await self.search(query: "\(first) \(searchName)")
                    return results.map { ($0, 5) }
                }
            }
            for await batch in group { rawResponses.append(contentsOf: batch) }
        }
        return rawResponses
    }

    // MARK: - Debug: Current Algorithm (mirrors performFetch Phase 2 exactly)

    internal func runCurrentAlgorithm(
        raw: [(LRCLIBResponse, Int)],
        track: TrackInfo
    ) -> DebugResult {
        var seenPlain = Set<String>()
        var scoredSynced: [(candidate: LyricsCandidate, debug: DebugCandidate)] = []
        typealias PlainEntry = (text: String, score: Int, langScore: Int, titleScore: Int, sourceScore: Int)
        var plainPool: [PlainEntry] = []

        for (response, sourceScore) in raw {
            if let lrc = response.syncedLyrics, !lrc.isEmpty {
                let langScore  = isPreferredLanguage(lrc) ? 50 : 0
                let titleScore = titleSimilarity(response.trackName ?? "", track.name)
                let artScore   = artistInTitleBonus(response.trackName ?? "", track.artist)
                let total      = 100 + langScore + titleScore + artScore + sourceScore
                scoredSynced.append((
                    candidate: LyricsCandidate(lrc: lrc, trackName: response.trackName ?? "",
                                               artistName: response.artistName ?? "",
                                               score: total, isSynced: true),
                    debug: DebugCandidate(id: UUID(), lrcPreview: String(lrc.prefix(500)),
                                          trackName: response.trackName ?? "",
                                          artistName: response.artistName ?? "",
                                          isSynced: true, totalScore: total,
                                          languageScore: langScore, titleScore: titleScore,
                                          artistScore: artScore, durationScore: 0, sourceScore: sourceScore)
                ))
            }
            if let plain = response.plainLyrics, !plain.isEmpty {
                let key = String(plain.prefix(120))
                guard !seenPlain.contains(key) else { continue }
                seenPlain.insert(key)
                let langScore  = isPreferredLanguage(plain) ? 50 : 0
                let titleScore = titleSimilarity(response.trackName ?? "", track.name)
                plainPool.append((plain, langScore + titleScore + sourceScore, langScore, titleScore, sourceScore))
            }
        }

        // Group synced by lyric text content; keep highest-scored variant per group
        var contentGroups: [String: (LyricsCandidate, DebugCandidate)] = [:]
        for (c, d) in scoredSynced {
            let key = lyricsTextKey(c.lrc)
            if let existing = contentGroups[key] {
                if c.score > existing.0.score { contentGroups[key] = (c, d) }
            } else {
                contentGroups[key] = (c, d)
            }
        }
        let groupedCount = max(0, scoredSynced.count - contentGroups.count)
        let allSynced = contentGroups.values.sorted { $0.0.score > $1.0.score }

        // Remove non-preferred-language candidates when preferred ones exist
        let hasPreferred = allSynced.contains { isPreferredLanguage($0.0.lrc) }
        let (syncedPairs, removedCount): ([(LyricsCandidate, DebugCandidate)], Int)
        if hasPreferred {
            let filtered = allSynced.filter { isPreferredLanguage($0.0.lrc) }
            syncedPairs = filtered
            removedCount = allSynced.count - filtered.count
        } else {
            syncedPairs = allSynced
            removedCount = 0
        }

        // Plain: top 3 only (matches production)
        plainPool.sort { $0.score > $1.score }
        let plainDebug: [DebugCandidate] = plainPool.prefix(3).map { p in
            DebugCandidate(id: UUID(), lrcPreview: String(p.text.prefix(500)),
                           trackName: "", artistName: "", isSynced: false,
                           totalScore: p.score, languageScore: p.langScore,
                           titleScore: p.titleScore, artistScore: 0,
                           durationScore: 0, sourceScore: p.sourceScore)
        }

        let allDebug = syncedPairs.map { $0.1 } + plainDebug
        return DebugResult(
            candidates: allDebug,
            chosenIndex: allDebug.isEmpty ? nil : 0,
            groupedCount: groupedCount,
            removedNonPreferredCount: removedCount,
            totalRawCount: raw.count
        )
    }

    // MARK: - Debug: Improved Algorithm

    internal func runImprovedAlgorithm(
        raw: [(LRCLIBResponse, Int)],
        track: TrackInfo
    ) -> DebugResult {
        var seenPlain = Set<String>()
        var scoredSynced: [(candidate: LyricsCandidate, debug: DebugCandidate)] = []
        var plainPool: [(debug: DebugCandidate, score: Int)] = []

        for (response, origSourceScore) in raw {
            // Stronger GET bias: full=60, broad=40, search=0
            let sourceScore: Int
            switch origSourceScore {
            case 20: sourceScore = 60
            case 10: sourceScore = 40
            default: sourceScore = 0
            }

            if let lrc = response.syncedLyrics, !lrc.isEmpty {
                // Language: penalty-based instead of hard filter
                let langScore     = isPreferredLanguage(lrc) ? 50 : -40
                let titleScore    = titleSimilarity(response.trackName ?? "", track.name)
                let artScore      = artistSimilarity(response.artistName ?? "", track.artist)
                let durationScore = durationMatch(response.duration, track.duration)
                let total         = 100 + langScore + titleScore + artScore + durationScore + sourceScore
                scoredSynced.append((
                    candidate: LyricsCandidate(lrc: lrc, trackName: response.trackName ?? "",
                                               artistName: response.artistName ?? "",
                                               score: total, isSynced: true),
                    debug: DebugCandidate(id: UUID(), lrcPreview: String(lrc.prefix(500)),
                                          trackName: response.trackName ?? "",
                                          artistName: response.artistName ?? "",
                                          isSynced: true, totalScore: total,
                                          languageScore: langScore, titleScore: titleScore,
                                          artistScore: artScore, durationScore: durationScore,
                                          sourceScore: sourceScore)
                ))
            }
            if let plain = response.plainLyrics, !plain.isEmpty {
                let key = String(plain.prefix(120))
                guard !seenPlain.contains(key) else { continue }
                seenPlain.insert(key)
                let langScore     = isPreferredLanguage(plain) ? 50 : -40
                let titleScore    = titleSimilarity(response.trackName ?? "", track.name)
                let artScore      = artistSimilarity(response.artistName ?? "", track.artist)
                let score         = langScore + titleScore + artScore + sourceScore
                let d = DebugCandidate(id: UUID(), lrcPreview: String(plain.prefix(500)),
                                       trackName: response.trackName ?? "",
                                       artistName: response.artistName ?? "",
                                       isSynced: false, totalScore: score,
                                       languageScore: langScore, titleScore: titleScore,
                                       artistScore: artScore, durationScore: 0, sourceScore: sourceScore)
                plainPool.append((d, score))
            }
        }

        // Same grouping logic as current
        var contentGroups: [String: (LyricsCandidate, DebugCandidate)] = [:]
        for (c, d) in scoredSynced {
            let key = lyricsTextKey(c.lrc)
            if let existing = contentGroups[key] {
                if c.score > existing.0.score { contentGroups[key] = (c, d) }
            } else {
                contentGroups[key] = (c, d)
            }
        }
        let groupedCount = max(0, scoredSynced.count - contentGroups.count)
        // No language filter — penalties applied in scoring
        let allSynced = contentGroups.values.sorted { $0.0.score > $1.0.score }

        // All plain candidates (no cap)
        plainPool.sort { $0.score > $1.score }

        let allDebug = allSynced.map { $0.1 } + plainPool.map { $0.debug }
        return DebugResult(
            candidates: allDebug,
            chosenIndex: allDebug.isEmpty ? nil : 0,
            groupedCount: groupedCount,
            removedNonPreferredCount: 0,
            totalRawCount: raw.count
        )
    }
    #endif

    // Exact match +30, contains +20, any word overlap +10
    private func artistSimilarity(_ responseArtist: String, _ queryArtist: String) -> Int {
        let a = normalizeTitle(responseArtist)
        let b = normalizeTitle(queryArtist)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 30 }
        if a.contains(b) || b.contains(a) { return 20 }
        let wa = Set(a.split(separator: " ").map(String.init))
        let wb = Set(b.split(separator: " ").map(String.init).filter { $0.count > 2 })
        return (!wb.isEmpty && !wa.intersection(wb).isEmpty) ? 10 : 0
    }

    // +25 if durations are within 2 seconds of each other
    private func durationMatch(_ responseDuration: Double?, _ trackDuration: TimeInterval) -> Int {
        guard let d = responseDuration, trackDuration > 0 else { return 0 }
        return abs(d - trackDuration) < 2 ? 25 : 0
    }

    // MARK: - LRC Parsing

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = #"^\[(\d+):(\d{2}\.\d+)\]\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for line in lrc.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 4 else { continue }
            let mins = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let secs = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let text = ns.substring(with: match.range(at: 3))
            let ts   = max(0, mins * 60.0 + secs - 0.2)
            lines.append(LyricLine(timestamp: ts, text: text))
        }

        lines.sort { $0.timestamp < $1.timestamp }
        lycheeDebugLog("[LRCLib] Parsed \(lines.count) lyric lines")
        return lines
    }
}
