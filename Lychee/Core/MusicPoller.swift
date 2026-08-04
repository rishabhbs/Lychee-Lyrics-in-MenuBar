//
//  MusicPoller.swift
//  Lychee
//
//  Unified poller that checks both Spotify and Apple Music
//

import Foundation
import Combine
import AppKit

/// Unified music poller that manages both Spotify and Apple Music polling
class MusicPoller: ObservableObject {
    static let shared = MusicPoller()

    private var timer: Timer?
    private var lastSource: TrackState.TrackSource = .none
    private let pollQueue = DispatchQueue(label: "com.lychee.musicpoller", qos: .userInitiated)

    private var lastActiveTrack: TrackInfo? = nil
    private var lastActiveSource: TrackState.TrackSource = .none

    private enum PlayerPollResult {
        case playing(TrackInfo)
        case paused(TrackInfo)
        case stopped
        case notRunning
        case unavailable
    }

    private enum PlaybackDetection {
        case active(TrackInfo, TrackState.TrackSource)
        case paused(TrackInfo, TrackState.TrackSource)
        case sourceGap(lastTrack: TrackInfo, source: TrackState.TrackSource)
        case noSource
    }

    private enum PlaybackCommand {
        case playPause
        case nextTrack
        case previousTrack
        case seek(TimeInterval)
    }

    // Adaptive polling: slow down after the track has been stable for a while
    private var stableTickCount = 0
    private var skipCounter = 0
    private let stabilityThreshold = 8   // 8 × 250ms = 2s before slowing down
    private let slowSkipRate = 3          // poll every 4th tick = effectively 1s when stable

    // Partial-transition guard: Spotify AppleScript can return a new trackID before
    // name/artist have updated. We wait for two consecutive polls with the same new ID
    // (or for the name to also change) before committing, so we never lock in (B_ID, A_name).
    private var pendingTrackID: String = ""
    private var pendingPollCount: Int = 0

    // Source-loss confirmation lives on the main queue with TrackState updates.
    // Short "no active source" gaps are expected during Spotify/Apple Music track
    // handoffs, so they must not clear the UI or trigger compact mode.
    private let sourceLossGrace: TimeInterval = 4
    private var sourceLossStartedAt: Date?
    private var sourceLossStopNotified = false
    private var sourceLossClearNotified = false

    private init() {}

    // MARK: - Public API

    /// Called by MediaRemotePoller when it detects a track change.
    /// Resets adaptive polling so MusicPoller catches the new song via AppleScript quickly.
    func noteExternalTrackChange() {
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            self.stableTickCount = 0
            self.skipCounter = 0
            DispatchQueue.main.async { [weak self] in
                self?.pendingTrackID = ""
                self?.pendingPollCount = 0
                self?.resetSourceLossConfirmation()
            }
            self.poll()
        }
    }

    func start() {
        stop()
        stableTickCount = 0
        skipCounter = 0
        DispatchQueue.main.async { [weak self] in
            self?.resetSourceLossConfirmation()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pollQueue.async { self?.poll() }
            }
            RunLoop.main.add(self.timer!, forMode: .common)
        }

        pollQueue.async { [weak self] in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func playPause() {
        sendPlaybackCommand(.playPause)
    }

    func nextTrack() {
        sendPlaybackCommand(.nextTrack)
    }

    func previousTrack() {
        sendPlaybackCommand(.previousTrack)
    }

    func seek(to time: TimeInterval) {
        sendPlaybackCommand(.seek(time))
    }

    // MARK: - Polling Logic

    private func poll() {
        // Adaptive rate: once the track is stable, only poll every 4th tick (~1s effective)
        if stableTickCount >= stabilityThreshold {
            skipCounter += 1
            if skipCounter < slowSkipRate { return }
            skipCounter = 0
        }

        switch detectPlayback() {
        case .active(let trackInfo, let source):
            handleTrackInfo(trackInfo, source: source)
        case .paused(let trackInfo, let source):
            handleTrackInfo(trackInfo, source: source)
        case .sourceGap(let lastTrack, let source):
            stableTickCount = 0
            skipCounter = 0
            handleSourceGap(lastTrack: lastTrack, source: source)
        case .noSource:
            stableTickCount = 0
            skipCounter = 0
            handleNoSource()
        }
    }

    private func detectPlayback() -> PlaybackDetection {
        let spotifyRunning     = isAppRunning("com.spotify.client")
        let appleMusicRunning  = isAppRunning("com.apple.Music")

        var activeCandidates: [(track: TrackInfo, source: TrackState.TrackSource)] = []
        var pausedCandidates: [(track: TrackInfo, source: TrackState.TrackSource)] = []

        if spotifyRunning {
            switch pollSpotify() {
            case .playing(let track):
                activeCandidates.append((track, .spotifyApp))
            case .paused(let track):
                pausedCandidates.append((track, .spotifyApp))
            case .stopped, .notRunning, .unavailable:
                break
            }
        }
        if appleMusicRunning {
            switch pollAppleMusic() {
            case .playing(let track):
                activeCandidates.append((track, .appleMusicApp))
            case .paused(let track):
                pausedCandidates.append((track, .appleMusicApp))
            case .stopped, .notRunning, .unavailable:
                break
            }
        }

        if let active = activeCandidates.first {
            lastActiveTrack = active.track
            lastActiveSource = active.source
            return .active(active.track, active.source)
        }

        if let paused = preferredPausedCandidate(pausedCandidates) {
            lastActiveTrack = paused.track
            lastActiveSource = paused.source
            return .paused(paused.track, paused.source)
        }

        // No source currently reports a playable track. If the last source app is still
        // alive, treat this as a source handoff gap and preserve the committed UI until
        // the gap is old enough to be a real idle state.
        if let last = lastActiveTrack {
            let source = lastActiveSource == .none ? source(for: last) : lastActiveSource
            if isSource(source, runningWithSpotify: spotifyRunning, appleMusic: appleMusicRunning) {
                return .sourceGap(lastTrack: last, source: source)
            }
        }

        return .noSource
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func preferredPausedCandidate(
        _ candidates: [(track: TrackInfo, source: TrackState.TrackSource)]
    ) -> (track: TrackInfo, source: TrackState.TrackSource)? {
        if let current = candidates.first(where: { $0.source == lastSource }) {
            return current
        }
        if let last = candidates.first(where: { $0.source == lastActiveSource }) {
            return last
        }
        return candidates.first
    }

    private func source(for track: TrackInfo) -> TrackState.TrackSource {
        track.trackID.hasPrefix("applemusic:") ? .appleMusicApp : .spotifyApp
    }

    private func isSource(
        _ source: TrackState.TrackSource,
        runningWithSpotify spotifyRunning: Bool,
        appleMusic appleMusicRunning: Bool
    ) -> Bool {
        switch source {
        case .spotifyApp:
            return spotifyRunning
        case .appleMusicApp:
            return appleMusicRunning
        case .none:
            return false
        }
    }

    private func resetSourceLossConfirmation() {
        sourceLossStartedAt = nil
        sourceLossStopNotified = false
        sourceLossClearNotified = false
    }

    private func sourceLossElapsed() -> TimeInterval {
        if let started = sourceLossStartedAt {
            return Date().timeIntervalSince(started)
        }
        sourceLossStartedAt = Date()
        return 0
    }

    private func handleSourceGap(lastTrack: TrackInfo, source: TrackState.TrackSource) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSource = source

            if TrackState.shared.currentTrackID.isEmpty {
                TrackState.shared.updateTrackMetadata(lastTrack, source: source)
            }

            guard self.sourceLossElapsed() >= self.sourceLossGrace else { return }
            guard !self.sourceLossStopNotified else { return }

            self.sourceLossStopNotified = true
            TrackState.shared.isPlaying = false
            TrackState.shared.onPlaybackStopped()
        }
    }

    private func handleNoSource() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard !TrackState.shared.currentTrackID.isEmpty else {
                self.lastSource = .none
                self.pollQueue.async { [weak self] in
                    self?.lastActiveTrack = nil
                    self?.lastActiveSource = .none
                }
                self.resetSourceLossConfirmation()
                return
            }

            guard self.sourceLossElapsed() >= self.sourceLossGrace else { return }
            guard !self.sourceLossClearNotified else { return }

            self.sourceLossClearNotified = true
            self.lastSource = .none
            self.pollQueue.async { [weak self] in
                self?.lastActiveTrack = nil
                self?.lastActiveSource = .none
            }
            LRCLibService.shared.cancel()
            TrackState.shared.onPlaybackStopped()
            TrackState.shared.clear()
        }
    }

    private func handleTrackInfo(_ info: TrackInfo, source: TrackState.TrackSource) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.resetSourceLossConfirmation()

            let currentTrackID = TrackState.shared.currentTrackID
            let idChanged = info.trackID != currentTrackID
            let nameChanged = !info.name.isEmpty && info.name != TrackState.shared.trackName
            let sourceChanged = source != self.lastSource
            let wasPlaying = TrackState.shared.isPlaying

            var shouldCommit = false

            if sourceChanged {
                // App switch → always commit immediately
                shouldCommit = true
                self.pendingTrackID   = ""
                self.pendingPollCount = 0
            } else if idChanged {
                if nameChanged {
                    // Both ID and name changed → Spotify metadata has settled, safe to commit
                    shouldCommit = true
                    self.pendingTrackID   = ""
                    self.pendingPollCount = 0
                } else {
                    // ID changed but name is still the previous song's — Spotify partial
                    // transition. Wait for the name to settle before committing so we never
                    // lock in (B_ID, A_name). Fall through after 2 consecutive polls with
                    // the same new ID as a safety valve (handles identical-title edge case).
                    if self.pendingTrackID == info.trackID {
                        self.pendingPollCount += 1
                        shouldCommit = self.pendingPollCount >= 2
                    } else {
                        self.pendingTrackID   = info.trackID
                        self.pendingPollCount = 1
                        shouldCommit = false
                    }
                }
            } else if nameChanged {
                // Same ID but name changed: recovers the case where a previous bad commit
                // locked in (B_ID, A_name). Next poll sees same ID + new name → re-commit.
                shouldCommit = true
                self.pendingTrackID   = ""
                self.pendingPollCount = 0
            } else {
                // Nothing changed → stable
                self.pendingTrackID   = ""
                self.pendingPollCount = 0
                self.stableTickCount += 1
            }

            if shouldCommit {
                self.stableTickCount = 0
                self.skipCounter = 0
                self.lastSource = source

                LRCLibService.shared.cancel()

                if idChanged {
                    TrackState.shared.beginTrackSession(info, source: source)
                } else {
                    TrackState.shared.clearLyrics()
                    TrackState.shared.updateTrackMetadata(info, source: source)
                    TrackState.shared.setLoading()
                }

                if source == .appleMusicApp {
                    Task {
                        if let artworkURL = await ArtworkService.shared.fetchAppleMusicArtwork(track: info.name, artist: info.artist) {
                            await MainActor.run {
                                if TrackState.shared.currentTrackID == info.trackID {
                                    TrackState.shared.artworkURL = artworkURL
                                }
                            }
                        }
                    }
                }

                LRCLibService.shared.fetchLyrics(for: info)
            }

            if shouldCommit || !idChanged {
                LyricsEngine.shared.onPositionPolled(info.position)
            }
            TrackState.shared.isPlaying = info.isPlaying

            if info.isPlaying {
                if !wasPlaying {
                    TrackState.shared.onPlaybackStarted()
                }
            } else if wasPlaying && !TrackState.shared.currentTrackID.isEmpty {
                TrackState.shared.onPlaybackStopped()
            }
        }
    }

    // MARK: - AppleScript Execution

    private let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")

    private func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = osascriptURL
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendPlaybackCommand(_ command: PlaybackCommand) {
        let source = TrackState.shared.source
        guard let script = playbackScript(for: source, command: command) else { return }

        pollQueue.async { [weak self] in
            guard let self else { return }
            _ = self.runAppleScript(script)
            self.stableTickCount = 0
            self.skipCounter = 0
            self.poll()
        }
    }

    private func playbackScript(
        for source: TrackState.TrackSource,
        command: PlaybackCommand
    ) -> String? {
        let applicationName: String
        switch source {
        case .spotifyApp:
            applicationName = "Spotify"
        case .appleMusicApp:
            applicationName = "Music"
        case .none:
            return nil
        }

        let statement: String
        switch command {
        case .playPause:
            statement = "playpause"
        case .nextTrack:
            statement = "next track"
        case .previousTrack:
            statement = "previous track"
        case .seek(let time):
            statement = "set player position to \(max(0, time))"
        }

        return """
        if application "\(applicationName)" is running then
            tell application "\(applicationName)"
                \(statement)
            end tell
        end if
        """
    }

    // MARK: - Spotify Polling

    private func pollSpotify() -> PlayerPollResult {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set trackID to id of current track
                    set artworkUrl to artwork url of current track
                    return "playing|" & trackName & "|" & artistName & "|" & albumName & "|" & (trackDuration as string) & "|" & (trackPosition as string) & "|" & trackID & "|" & artworkUrl
                else if player state is paused then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set trackID to id of current track
                    set artworkUrl to artwork url of current track
                    return "paused|" & trackName & "|" & artistName & "|" & albumName & "|" & (trackDuration as string) & "|" & (trackPosition as string) & "|" & trackID & "|" & artworkUrl
                else
                    return "stopped"
                end if
            end tell
        else
            return "not_running"
        end if
        """

        guard let result = runAppleScript(script) else {
            return .unavailable
        }

        if result == "not_running" {
            return .notRunning
        }
        if result == "stopped" {
            return .stopped
        }
        if result.hasPrefix("error|") {
            return .unavailable
        }

        guard let track = parseSpotifyResult(result) else { return .unavailable }

        return track.isPlaying ? .playing(track) : .paused(track)
    }

    private func parseSpotifyResult(_ result: String) -> TrackInfo? {
        let parts = result.components(separatedBy: "|")
        guard parts.count >= 8 else { return nil }

        let playerState = parts[0]
        let trackName = parts[1]
        let artistName = parts[2]
        let albumName = parts[3]

        // Duration is in milliseconds from Spotify
        let durationMs = Double(parts[4]) ?? 0
        let duration = durationMs / 1000.0

        let position = Double(parts[5]) ?? 0
        let trackID = parts[6]
        let artworkURLString = parts[7]

        // Ignore ads (spotify:ad:...) and podcasts (spotify:episode:...)
        guard trackID.hasPrefix("spotify:track:") || trackID.hasPrefix("spotify:local:") else {
            return nil
        }

        let isPlaying = (playerState == "playing")
        let artworkURL = URL(string: artworkURLString)

        return TrackInfo(
            name: trackName,
            artist: artistName,
            album: albumName,
            duration: duration,
            position: position,
            trackID: trackID,
            isPlaying: isPlaying,
            artworkURL: artworkURL
        )
    }

    // MARK: - Apple Music Polling

    private func pollAppleMusic() -> PlayerPollResult {
        let script = """
        if application "Music" is running then
            tell application "Music"
                if player state is playing then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set trackID to database ID of current track
                    return "playing|" & trackName & "|" & artistName & "|" & albumName & "|" & (trackDuration as string) & "|" & (trackPosition as string) & "|" & (trackID as string)
                else if player state is paused then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set trackID to database ID of current track
                    return "paused|" & trackName & "|" & artistName & "|" & albumName & "|" & (trackDuration as string) & "|" & (trackPosition as string) & "|" & (trackID as string)
                else
                    return "stopped"
                end if
            end tell
        else
            return "not_running"
        end if
        """

        guard let result = runAppleScript(script) else {
            return .unavailable
        }

        if result == "not_running" {
            return .notRunning
        }
        if result == "stopped" {
            return .stopped
        }
        if result.hasPrefix("error|") {
            return .unavailable
        }

        guard let track = parseAppleMusicResult(result) else { return .unavailable }

        return track.isPlaying ? .playing(track) : .paused(track)
    }

    private func parseAppleMusicResult(_ result: String) -> TrackInfo? {
        let parts = result.components(separatedBy: "|")

        guard parts.count >= 7 else {
            return nil
        }

        let playerState = parts[0]
        let trackName = parts[1]
        let artistName = parts[2]
        let albumName = parts[3]

        // Duration is in seconds from Apple Music
        let duration = Double(parts[4]) ?? 0
        let position = Double(parts[5]) ?? 0
        let trackID = "applemusic:\(parts[6])"  // Prefix to distinguish from Spotify IDs

        let isPlaying = (playerState == "playing")

        // Apple Music doesn't provide artwork URL via AppleScript easily
        let artworkURL: URL? = nil

        return TrackInfo(
            name: trackName,
            artist: artistName,
            album: albumName,
            duration: duration,
            position: position,
            trackID: trackID,
            isPlaying: isPlaying,
            artworkURL: artworkURL
        )
    }
}
