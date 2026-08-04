//
//  TrackState.swift
//  Lychee
//
//  Shared observable state for track playback and lyrics
//

import Foundation
import Combine
import SwiftUI

/// A single scored lyrics candidate from any source (GET or search)
struct LyricsCandidate {
    let lrc: String          // raw LRC string (isSynced=true) or plain text (isSynced=false)
    let trackName: String    // from LRCLIB response
    let artistName: String   // from LRCLIB response
    let score: Int           // higher = better match
    let isSynced: Bool       // false = plain text only, no timestamps
}

/// Represents a single lyric line with timestamp
struct LyricLine: Identifiable {
    let id = UUID()
    let timestamp: TimeInterval   // seconds
    let text: String
}

/// Shared state for the currently playing track and lyrics
class TrackState: ObservableObject {
    static let shared = TrackState()

    // Track metadata
    @Published var trackName: String = ""
    @Published var artistName: String = ""
    @Published var albumName: String = ""
    @Published var artworkURL: URL? = nil
    @Published var artworkData: Data? = nil
    @Published var currentTrackID: String = ""

    // Playback state
    @Published var isPlaying: Bool = false
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var source: TrackSource = .none

    // Lyrics state
    @Published var lyricsState: LyricsState = .idle
    @Published var loadingPhase: LoadingPhase = .initial
    @Published var lines: [LyricLine] = []
    @Published var plainLyrics: String = ""

    // All scored lyrics candidates (from GET + search), sorted best-first
    @Published var allCandidates: [LyricsCandidate] = []
    @Published var candidateIndex: Int = 0
    @Published var savedCandidateLRC: String? = nil  // LRC currently written to cache

    // Session-only lyrics rejection (no cache write — resets on track change via clear())
    @Published var lyricsRejectedForSession: Bool = false

    // Display preferences
    @Published var gapStyle: GapStyle = .fade
    @Published var inactivityTimeout: InactivityTimeout = .fiveMin
    @Published var isMinimized: Bool = false
    @Published var isPopoverShown: Bool = false
    @Published var isHydrating: Bool = false
    @Published var popoverTheme: PopoverTheme = .system
    @Published var algorithmVersion: AlgorithmVersion = .legacy
    @Published var lyricsFontSize: LyricsFontSize = .medium
    @Published var menuBarWidth: MenuBarWidth = .standard
    // Actual current display width — may be smaller than menuBarWidth.pixels when the
    // system has pushed us down due to menu bar crowding. Set exclusively by AppDelegate.
    @Published var effectiveMenuBarPixels: CGFloat = MenuBarWidth.standard.pixels

    // Non-published: direction hint for lyrics panel slide animation (+1 = forward, -1 = back)
    var lastCycleDirection: Int = 1

    private var inactivityTimer: Timer?

    private init() {
        UserDefaults.standard.register(defaults: [
            "popoverTheme": PopoverTheme.system.rawValue,
            "menuBarWidth": MenuBarWidth.standard.rawValue
        ])

        // Load saved gap style from UserDefaults
        if let savedGapStyle = UserDefaults.standard.string(forKey: "gapStyle"),
           let style = GapStyle(rawValue: savedGapStyle) {
            gapStyle = style
        }

        // Load saved inactivity timeout from UserDefaults
        if let savedTimeout = UserDefaults.standard.string(forKey: "inactivityTimeout") {
            if let timeout = InactivityTimeout(rawValue: savedTimeout) {
                inactivityTimeout = timeout
            } else if savedTimeout == "Instant" {
                inactivityTimeout = .immediate
                UserDefaults.standard.set(InactivityTimeout.immediate.rawValue, forKey: "inactivityTimeout")
            }
        }

        // Load saved popover theme from UserDefaults
        if let savedTheme = UserDefaults.standard.string(forKey: "popoverTheme"),
           let theme = PopoverTheme(rawValue: savedTheme) {
            popoverTheme = theme
        }
        if let saved = UserDefaults.standard.string(forKey: "algorithmVersion"),
           let v = AlgorithmVersion(rawValue: saved) {
            algorithmVersion = v
        }
        if let saved = UserDefaults.standard.string(forKey: "lyricsFontSize"),
           let size = LyricsFontSize(rawValue: saved) {
            lyricsFontSize = size
        }
        if let saved = UserDefaults.standard.string(forKey: "menuBarWidth"),
           let width = MenuBarWidth(rawValue: saved) {
            menuBarWidth = width
            effectiveMenuBarPixels = width.pixels
        }
    }

    // MARK: - State Management

    /// Starts a new track session without ever publishing an empty track name.
    /// `clear()` is reserved for confirmed idle/no-source states; normal song
    /// changes should move directly from old metadata to new metadata.
    func beginTrackSession(_ track: TrackInfo, source newSource: TrackSource) {
        artworkData = nil
        artworkURL = track.artworkURL
        currentTrackID = track.trackID
        trackName = track.name
        artistName = track.artist
        albumName = track.album
        isPlaying = track.isPlaying
        position = track.position
        duration = track.duration
        source = newSource
        lyricsState = .loading
        loadingPhase = .initial
        lines = []
        plainLyrics = ""
        allCandidates = []
        candidateIndex = 0
        savedCandidateLRC = nil
        isHydrating = false
        lyricsRejectedForSession = false
    }

    /// Updates metadata for the current track without resetting lyrics state.
    func updateTrackMetadata(_ track: TrackInfo, source newSource: TrackSource) {
        artworkURL = track.artworkURL
        currentTrackID = track.trackID
        trackName = track.name
        artistName = track.artist
        albumName = track.album
        duration = track.duration
        self.source = newSource
    }

    func clear() {
        trackName = ""
        artistName = ""
        albumName = ""
        artworkURL = nil
        artworkData = nil
        currentTrackID = ""
        isPlaying = false
        position = 0
        duration = 0
        source = .none
        lyricsState = .idle
        loadingPhase = .initial
        lines = []
        plainLyrics = ""
        allCandidates = []
        candidateIndex = 0
        savedCandidateLRC = nil
        isHydrating = false
        lyricsRejectedForSession = false
    }

    /// Resets only lyrics state, leaving track metadata intact.
    /// Used when re-committing the same track ID (name correction) to avoid the
    /// trackName="" flash that full clear() would produce.
    func clearLyrics() {
        lyricsState = .idle
        loadingPhase = .initial
        lines = []
        plainLyrics = ""
        allCandidates = []
        candidateIndex = 0
        savedCandidateLRC = nil
        isHydrating = false
        lyricsRejectedForSession = false
    }

    // MARK: - Inactivity Timer

    /// Call when playback becomes active — cancels any pending minimize
    func onPlaybackStarted() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        guard isMinimized else { return }
        isMinimized = false
    }

    /// Call when playback stops — starts the inactivity countdown
    func onPlaybackStopped() {
        guard inactivityTimeout != .never else { return }
        inactivityTimer?.invalidate()

        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: inactivityTimeout.seconds,
            repeats: false
        ) { [weak self] _ in
            // Direct assignment — no inner async. Timer fires on the main run loop, so we're
            // already on the main thread. The inner async was creating a race where the queued
            // block could fire after onPlaybackStarted() had already set isMinimized=false.
            self?.isMinimized = true
        }
    }

    func setInactivityTimeout(_ timeout: InactivityTimeout) {
        inactivityTimeout = timeout
        UserDefaults.standard.set(timeout.rawValue, forKey: "inactivityTimeout")
        // Re-arm timer with new duration if already counting down
        if !isPlaying {
            onPlaybackStopped()
        }
    }
    func updatePosition(_ pos: TimeInterval) {
        position = pos
    }

    func setLyrics(_ parsed: [LyricLine]) {
        lines = parsed
        lyricsState = .synced
    }

    func setPlainLyrics(_ text: String) {
        plainLyrics = text
        lyricsState = .plainOnly
    }

    func setNoLyrics() {
        lyricsState = .notFound
    }

    func setLoading() {
        lyricsState = .loading
        loadingPhase = .initial
    }

    func setLoadingPhase(_ phase: LoadingPhase) {
        loadingPhase = phase
    }

    func setGapStyle(_ style: GapStyle) {
        gapStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "gapStyle")
    }

    func setPopoverTheme(_ theme: PopoverTheme) {
        popoverTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "popoverTheme")
    }

    func setAlgorithmVersion(_ v: AlgorithmVersion) {
        algorithmVersion = v
        UserDefaults.standard.set(v.rawValue, forKey: "algorithmVersion")
    }

    func setLyricsFontSize(_ size: LyricsFontSize) {
        lyricsFontSize = size
        UserDefaults.standard.set(size.rawValue, forKey: "lyricsFontSize")
    }

    func setMenuBarWidth(_ width: MenuBarWidth) {
        menuBarWidth = width
        UserDefaults.standard.set(width.rawValue, forKey: "menuBarWidth")
    }
}

// MARK: - Enums

extension TrackState {
    enum LyricsState {
        case idle           // Nothing playing
        case loading        // Fetching from LRCLIB
        case synced         // Timestamped lyrics ready
        case plainOnly      // Only plain lyrics available
        case notFound       // No lyrics found after all attempts
    }

    enum LoadingPhase {
        case initial        // "Song name — loading lyrics..."
        case takingLonger   // "Taking a bit longer than usual..."
        case nicheChoice    // "Song name — very niche choice hm?"
        case lastTry        // "Alright one last try..."
    }

    enum GapStyle: String, CaseIterable {
        case none = "None"
        case dots = "Dots"
        case fade = "Fade"
        case wave = "Wave"
    }

    enum InactivityTimeout: String, CaseIterable {
        case immediate = "5 seconds"
        case oneMin    = "1 min"
        case fiveMin   = "5 min"
        case never     = "Never"

        var seconds: TimeInterval {
            switch self {
            case .immediate: return 5
            case .oneMin:    return 60
            case .fiveMin:   return 300
            case .never:     return .infinity
            }
        }
    }

    enum TrackSource: Equatable {
        case none
        case spotifyApp
        case appleMusicApp
    }

    enum PopoverTheme: String, CaseIterable {
        case system = "System"
        case dark   = "Dark"
        case light  = "Light"
    }

    enum AlgorithmVersion: String, CaseIterable {
        case legacy   = "Legacy"
        case improved = "Improved"
    }

    enum LyricsFontSize: String, CaseIterable {
        case small  = "Small"
        case medium = "Medium"
        case large  = "Large"
        case xLarge = "XL"

        var syncedSize: CGFloat {
            switch self {
            case .small:  return 13
            case .medium: return 16
            case .large:  return 19
            case .xLarge: return 22
            }
        }

        var plainSize: CGFloat {
            switch self {
            case .small:  return 11
            case .medium: return 13
            case .large:  return 15
            case .xLarge: return 17
            }
        }

        var lineGap: CGFloat {
            switch self {
            case .small:  return 14
            case .medium: return 18
            case .large:  return 22
            case .xLarge: return 26
            }
        }

        var noteSize: CGFloat { syncedSize + 2 }
    }

    enum MenuBarWidth: String, CaseIterable {
        case tiny     = "Tiny"
        case narrow   = "Narrow"
        case standard = "Standard"
        case wide     = "Wide"

        var pixels: CGFloat {
            switch self {
            case .tiny:     return 160
            case .narrow:   return 220
            case .standard: return 308
            case .wide:     return 380
            }
        }

        var lyricsMaxWidth: CGFloat { pixels - 48 }
    }
}
