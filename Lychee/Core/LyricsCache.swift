//
//  LyricsCache.swift
//  Lychee
//
//  Per-song file cache — each entry is a tiny JSON file named by SHA256 of the cache key.
//  No big JSON dict, no full-file rewrites. Each lookup/save touches only one ~4KB file.
//  Stored at ~/Library/Application Support/Lychee/lyrics/<hash>.json
//

import Foundation
import CryptoKit

nonisolated struct LyricsCacheEntry: Codable {
    enum EntryType: String, Codable { case synced, plain, notFound }
    let type: EntryType
    let content: String?   // raw LRC string (synced), plain text (plain), nil (notFound)
    let savedAt: Double    // Unix timestamp
}

class LyricsCache {
    static let shared = LyricsCache()

    private let cacheDir: URL
    private let queue = DispatchQueue(label: "com.lychee.lyrics-cache")
    private let notFoundTTL: TimeInterval = 24 * 3600  // 1 day — short enough that transient API failures don't stick

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDir = appSupport.appendingPathComponent("Lychee/lyrics")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let count = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count) ?? 0
        lycheeDebugLog("[LyricsCache] Ready — \(count) songs cached")
    }

    // MARK: - Public API

    func get(artist: String, track: String) -> LyricsCacheEntry? {
        let url = fileURL(artist: artist, track: track)
        return queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: data) else {
                return nil
            }
            if entry.type == .notFound, Date().timeIntervalSince1970 - entry.savedAt > notFoundTTL {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return entry
        }
    }

    func save(artist: String, track: String, entry: LyricsCacheEntry) {
        let url = fileURL(artist: artist, track: track)
        queue.async {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: url, options: .atomic)
            lycheeDebugLog("[LyricsCache] Saved \(entry.type) for: \(track) - \(artist)")
        }
    }

    func clearAll() {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: self.cacheDir.path)) ?? []
            for file in files {
                try? FileManager.default.removeItem(at: self.cacheDir.appendingPathComponent(file))
            }
            lycheeDebugLog("[LyricsCache] Cleared all \(files.count) cached entries")
        }
    }

    /// Delete only entries whose `savedAt` timestamp falls after `cutoff`.
    /// Pass `nil` to delete everything (equivalent to `clearAll`).
    func clearEntries(savedSince cutoff: Date?) {
        queue.async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(atPath: self.cacheDir.path)) ?? []
            var count = 0
            for file in files {
                let url = self.cacheDir.appendingPathComponent(file)
                if let cutoff {
                    guard let data = try? Data(contentsOf: url),
                          let entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: data)
                    else { continue }
                    if entry.savedAt > cutoff.timeIntervalSince1970 {
                        try? fm.removeItem(at: url)
                        count += 1
                    }
                } else {
                    try? fm.removeItem(at: url)
                    count += 1
                }
            }
            lycheeDebugLog("[LyricsCache] Cleared \(count) entries (cutoff: \(cutoff?.description ?? "all time"))")
        }
    }

    // MARK: - Private

    private func fileURL(artist: String, track: String) -> URL {
        let a = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let t = track.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(a)|\(t)"
        let hash = SHA256.hash(data: Data(key.utf8))
        let filename = hash.map { String(format: "%02x", $0) }.joined() + ".json"
        return cacheDir.appendingPathComponent(filename)
    }
}
