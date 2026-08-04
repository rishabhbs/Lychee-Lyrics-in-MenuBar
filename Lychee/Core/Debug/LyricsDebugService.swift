//
//  LyricsDebugService.swift
//  Lychee
//

#if DEBUG
import Foundation
import Combine
import AppKit

@MainActor
class LyricsDebugService: ObservableObject {
    static let shared = LyricsDebugService()

    // Algorithm tab
    @Published var currentRun: DebugRun?
    @Published var history: [DebugRun] = []
    @Published var isRunning: Bool = false

    // Performance tab — current session (live) + past sessions (from disk)
    @Published var currentSession: PerformanceSession
    @Published var pastSessions: [PerformanceSession] = []

    private var cancellables = Set<AnyCancellable>()
    private var pendingPerfID: UUID?
    private let historyURL: URL
    private let sessionsURL: URL
    private let maxHistory = 100

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lychee")
        historyURL  = appSupport.appendingPathComponent("algo_debug_history.json")
        sessionsURL = appSupport.appendingPathComponent("perf_sessions.json")
        currentSession = PerformanceSession(id: UUID(), startedAt: Date(), endedAt: nil, records: [])
        loadHistory()
        loadSessions()
        subscribeToTrackChanges()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flushSessionOnQuit() }
            .store(in: &cancellables)
    }

    // MARK: - Subscriptions

    private func subscribeToTrackChanges() {
        TrackState.shared.$currentTrackID
            .dropFirst()
            .filter { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                let t = Date()
                DispatchQueue.main.async { self?.startPerfRecord(trackID: id, detectedAt: t) }
            }
            .store(in: &cancellables)

        TrackState.shared.$lyricsState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.completePerfRecord(state: state) }
            .store(in: &cancellables)

        TrackState.shared.$currentTrackID
            .dropFirst()
            .filter { !$0.isEmpty }
            .debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.runForCurrentTrack() } }
            .store(in: &cancellables)
    }

    // MARK: - Performance tracking

    private func startPerfRecord(trackID: String, detectedAt: Date) {
        let ts = TrackState.shared
        guard ts.currentTrackID == trackID else { return }
        let rec = PerformanceRecord(
            id: UUID(), trackID: trackID,
            trackName: ts.trackName, artistName: ts.artistName,
            source: sourceLabel(ts.source), algoVersion: ts.algorithmVersion.rawValue,
            detectedAt: detectedAt, outcome: .pending, candidateCount: 0
        )
        pendingPerfID = rec.id
        currentSession.records.insert(rec, at: 0)
    }

    private func completePerfRecord(state: TrackState.LyricsState) {
        guard let pid = pendingPerfID,
              let idx = currentSession.records.firstIndex(where: { $0.id == pid }) else { return }
        switch state {
        case .synced:    currentSession.records[idx].outcome = .synced
        case .plainOnly: currentSession.records[idx].outcome = .plain
        case .notFound:  currentSession.records[idx].outcome = .notFound
        case .loading, .idle: return
        }
        currentSession.records[idx].lyricsArrivedAt = Date()
        currentSession.records[idx].candidateCount = TrackState.shared.allCandidates.count
        pendingPerfID = nil
        saveSessions()          // persist completed record immediately
    }

    private func sourceLabel(_ s: TrackState.TrackSource) -> String {
        switch s {
        case .spotifyApp:    return "Spotify"
        case .appleMusicApp: return "Apple Music"
        case .none:          return "—"
        }
    }

    // MARK: - Session mutations (called from UI)

    func deleteCurrentRecord(id: UUID) {
        currentSession.records.removeAll { $0.id == id }
        saveSessions()
    }

    func clearCurrentSession() {
        currentSession.records.removeAll()
        saveSessions()
    }

    func deletePastSession(id: UUID) {
        pastSessions.removeAll { $0.id == id }
        saveSessions()
    }

    // MARK: - Algorithm run

    @discardableResult
    func runForCurrentTrack() async -> UUID? {
        let ts = TrackState.shared
        guard !ts.trackName.isEmpty else { return nil }
        let track = TrackInfo(
            name: ts.trackName, artist: ts.artistName, album: ts.albumName,
            duration: ts.duration, position: ts.position, trackID: ts.currentTrackID,
            isPlaying: ts.isPlaying, artworkURL: ts.artworkURL
        )
        isRunning = true
        let raw = await LRCLibService.shared.fetchAllResponses(for: track)
        let cur = LRCLibService.shared.runCurrentAlgorithm(raw: raw, track: track)
        let imp = LRCLibService.shared.runImprovedAlgorithm(raw: raw, track: track)
        let run = DebugRun(id: UUID(), trackName: track.name, artistName: track.artist,
                           albumName: track.album, timestamp: Date(), rawCount: raw.count,
                           current: cur, improved: imp)
        isRunning = false
        currentRun = run
        history.insert(run, at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        saveHistory()
        return run.id
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let runs = try? JSONDecoder().decode([DebugRun].self, from: data) else { return }
        history = runs
        currentRun = runs.first
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsURL),
              let sessions = try? JSONDecoder().decode([PerformanceSession].self, from: data) else { return }
        pastSessions = sessions
    }

    // Saves current session (with endedAt=nil) + all past sessions.
    // Called after each completed record so crashes don't lose data.
    private func saveSessions() {
        let snapshot = PerformanceSession(
            id: currentSession.id, startedAt: currentSession.startedAt,
            endedAt: nil, records: currentSession.records
        )
        let all = [snapshot] + pastSessions
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    // On quit: set endedAt, prepend current session, reload next launch as past session.
    private func flushSessionOnQuit() {
        var closed = currentSession
        closed.endedAt = Date()
        let all = [closed] + pastSessions
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }
}
#endif
