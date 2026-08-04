//
//  LyricsDebugTypes.swift
//  Lychee
//

#if DEBUG
import Foundation

// MARK: - Algorithm debug types

struct DebugCandidate: Codable, Identifiable {
    let id: UUID
    let lrcPreview: String
    let trackName: String
    let artistName: String
    let isSynced: Bool
    let totalScore: Int
    let languageScore: Int
    let titleScore: Int
    let artistScore: Int
    let durationScore: Int
    let sourceScore: Int
}

struct DebugResult: Codable {
    let candidates: [DebugCandidate]
    let chosenIndex: Int?
    let groupedCount: Int
    let removedNonPreferredCount: Int
    let totalRawCount: Int
}

struct DebugRun: Codable, Identifiable, Equatable {
    let id: UUID
    let trackName: String
    let artistName: String
    let albumName: String
    let timestamp: Date
    let rawCount: Int
    let current: DebugResult
    let improved: DebugResult

    static func == (lhs: DebugRun, rhs: DebugRun) -> Bool { lhs.id == rhs.id }
}

// MARK: - Performance types

struct PerformanceRecord: Codable, Identifiable {
    let id: UUID
    let trackID: String
    var trackName: String
    var artistName: String
    var source: String
    var algoVersion: String
    let detectedAt: Date
    var lyricsArrivedAt: Date?
    var outcome: Outcome
    var candidateCount: Int

    var timeToLyrics: TimeInterval? {
        lyricsArrivedAt.map { $0.timeIntervalSince(detectedAt) }
    }

    enum Outcome: String, Codable {
        case pending, synced, plain, notFound, error
        var label: String {
            switch self {
            case .pending:  return "…"
            case .synced:   return "Synced"
            case .plain:    return "Plain"
            case .notFound: return "Not Found"
            case .error:    return "Error"
            }
        }
    }
}

struct PerformanceSession: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var records: [PerformanceRecord]

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var isComplete: Bool { endedAt != nil }

    static func durationString(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t))s" }
        if t < 3600 { return "\(Int(t / 60))m" }
        return "\(Int(t / 3600))h \(Int((t.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}
#endif
