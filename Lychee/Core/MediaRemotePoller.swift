//
//  MediaRemotePoller.swift
//  Lychee
//
//  Passive observer using macOS MediaRemote private framework.
//  Responsibilities: artwork, position, and hinting MusicPoller of track changes.
//  Does NOT manage TrackState track info — MusicPoller owns that.
//

import Foundation
import AppKit

/// Passive music poller using MediaRemote private framework
class MediaRemotePoller {
    static let shared = MediaRemotePoller()

    private var timer: Timer?
    private var lastTrackID: String = ""
    // Sequence number to discard stale callbacks: getNowPlayingInfo is async and the
    // 0.5s timer fires new calls before previous callbacks return, so older callbacks
    // can arrive out-of-order carrying the previous song's data.
    private var pollSequence: Int = 0

    // MediaRemote function pointers
    private var MRMediaRemoteGetNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunction?
    private var bundle: CFBundle?

    // Function type definitions
    typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void

    // MediaRemote constants
    private let kMRMediaRemoteNowPlayingInfoTitle = "kMRMediaRemoteNowPlayingInfoTitle"
    private let kMRMediaRemoteNowPlayingInfoArtist = "kMRMediaRemoteNowPlayingInfoArtist"
    private let kMRMediaRemoteNowPlayingInfoElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    private let kMRMediaRemoteNowPlayingInfoArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"

    private init() {
        loadMediaRemoteFramework()
    }

    // MARK: - Framework Loading

    private func loadMediaRemoteFramework() {
        guard let loadedBundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else { return }

        bundle = loadedBundle

        if let ptr = CFBundleGetFunctionPointerForName(loadedBundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        }
    }

    // MARK: - Public API

    func start() {
        stop()

        if let bundle = bundle,
           let registerPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            let register = unsafeBitCast(registerPtr, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
            register(DispatchQueue.main)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(self.timer!, forMode: .common)
        }

        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling Logic
    // Passive: only updates artwork and position. MusicPoller owns all track state.

    private func poll() {
        guard let getNowPlayingInfo = MRMediaRemoteGetNowPlayingInfo else { return }

        // Stamp this call so stale callbacks are discarded. The 0.5s timer issues a new
        // getNowPlayingInfo call before the previous callback returns. If the OS is slow,
        // the older callback arrives AFTER a newer one — carrying the previous song's data.
        // Without this guard that stale callback would corrupt TrackState permanently:
        // it would set lastTrackID back, look like a "new" song, and since currentTrackID
        // was already updated by MusicPoller the change-detection in handleTrackInfo
        // would see trackChanged=false and never fix it.
        pollSequence &+= 1
        let mySequence = pollSequence

        getNowPlayingInfo(DispatchQueue.main) { [weak self] info in
            guard let self = self, mySequence == self.pollSequence else { return }

            guard !info.isEmpty else {
                self.lastTrackID = ""
                return
            }

            let title   = info[self.kMRMediaRemoteNowPlayingInfoTitle]  as? String ?? ""
            let artist  = info[self.kMRMediaRemoteNowPlayingInfoArtist] as? String ?? ""
            let elapsed = info[self.kMRMediaRemoteNowPlayingInfoElapsedTime] as? Double ?? 0
            let trackID = "\(title)-\(artist)"

            // Always feed position to the lyrics engine
            LyricsEngine.shared.onPositionPolled(elapsed)

            // Update artwork only when MediaRemote's title matches what MusicPoller has
            // confirmed in TrackState. During the transition window (MediaRemote has the new
            // song, AppleScript hasn't confirmed yet), this prevents new artwork from showing
            // alongside the old song name — the mismatch the user actually sees.
            if let data = info[self.kMRMediaRemoteNowPlayingInfoArtworkData] as? Data,
               !TrackState.shared.trackName.isEmpty,
               TrackState.shared.trackName == title {
                TrackState.shared.artworkData = data
            }

            // Hint MusicPoller to poll immediately when a new song is detected.
            // MusicPoller is the sole owner of trackName/artistName/currentTrackID.
            // Never write those here — doing so caused a permanent stale-state bug when
            // a second stale OS callback arrived after MusicPoller had already confirmed
            // the new song (corrupting the name back and preventing handleTrackInfo from
            // re-triggering because currentTrackID already matched).
            if trackID != self.lastTrackID && !title.isEmpty {
                self.lastTrackID = trackID
                MusicPoller.shared.noteExternalTrackChange()
            }
        }
    }

}
