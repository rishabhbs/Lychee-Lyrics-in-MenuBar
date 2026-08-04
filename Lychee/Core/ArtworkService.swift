//
//  ArtworkService.swift
//  Lychee
//
//  Fetches album artwork for Apple Music tracks via iTunes Search API
//

import Foundation

class ArtworkService {
    static let shared = ArtworkService()

    private init() {}

    func fetchAppleMusicArtwork(track: String, artist: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track) \(artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]]
            let artworkURLString = results?.first?["artworkUrl100"] as? String
            return artworkURLString.flatMap {
                URL(string: $0.replacingOccurrences(of: "100x100", with: "600x600"))
            }
        } catch {
            return nil
        }
    }
}
