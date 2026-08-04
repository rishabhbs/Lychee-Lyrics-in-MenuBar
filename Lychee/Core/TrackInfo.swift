//
//  TrackInfo.swift
//  Lychee
//
//  Shared track information structure
//

import Foundation

/// Information about the currently playing track
struct TrackInfo {
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval  // seconds
    let position: TimeInterval  // seconds
    let trackID: String
    let isPlaying: Bool
    let artworkURL: URL?
}
