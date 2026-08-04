//
//  LyricsEngine.swift
//  Lychee
//
//  Syncs current lyric line to playback position
//

import Foundation
import Combine

/// Engine for tracking current lyric line based on playback position
class LyricsEngine: ObservableObject {
    static let shared = LyricsEngine()
    
    @Published var currentLineIndex: Int = 0
    @Published var currentLine: String = ""
    @Published var nextLine: String = ""
    
    private var lines: [LyricLine] = []
    private var cancellables = Set<AnyCancellable>()

    private var lastPollTime: Date = Date()
    private var lastPolledPosition: TimeInterval = 0
    private var displayTimerID: UUID?

    /// True when the current position falls in a musical gap (instrumental section).
    /// Primary: LRC file has an explicit empty-text line at this position.
    /// Backup (no explicit gaps in file): gap to next line is ≥ 5s AND the lyric has
    /// already been shown for at least 1.5s (so the lyric displays first, then ♪ music).
    /// True when the current position falls in a musical gap (intro or explicit empty-text LRC line).
    /// The engine sets currentLine = "" in these cases — no timestamp heuristics.
    var isInGap: Bool {
        guard !lines.isEmpty else { return false }
        return currentLine.isEmpty
    }
    
    private init() {
        observeTrackState()
    }
    
    // MARK: - Observation
    
    private func observeTrackState() {
        // Observe lyrics changes
        TrackState.shared.$lines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLines in
                self?.lines = newLines
                self?.currentLineIndex = 0
                self?.update(position: TrackState.shared.position)
                if !newLines.isEmpty {
                    self?.startInterpolation()
                }
            }
            .store(in: &cancellables)
        
        // Observe lyrics state changes
        TrackState.shared.$lyricsState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .idle || state == .loading || state == .notFound {
                    self?.clear()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Position Interpolation
    
    func startInterpolation() {
        guard displayTimerID == nil else { return }
        displayTimerID = DisplayTimer.shared.add { [weak self] in
            guard let self = self else { return }
            guard TrackState.shared.isPlaying else { return }
            let elapsed = Date().timeIntervalSince(self.lastPollTime)
            self.update(position: self.lastPolledPosition + elapsed)
        }
    }
    
    func onPositionPolled(_ position: TimeInterval) {
        lastPollTime = Date()
        lastPolledPosition = position
        TrackState.shared.updatePosition(position)
        update(position: position)
    }
    
    // MARK: - Position Sync
    
    func update(position: TimeInterval) {
        guard !lines.isEmpty else { return }

        // Song intro: before the first lyric fires, publish empty string so isInGap triggers.
        if let firstLine = lines.first, position < firstLine.timestamp {
            if !currentLine.isEmpty {
                currentLine = ""
                nextLine = lines.first?.text ?? ""
            }
            return
        }

        let newIndex = lines.lastIndex { $0.timestamp <= position } ?? 0

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
            updateCurrentLine()
        } else if currentLine.isEmpty {
            // Intro just ended and index stayed at 0 — publish the first lyric now.
            updateCurrentLine()
        }
    }
    
    private func updateCurrentLine() {
        guard !lines.isEmpty, currentLineIndex < lines.count else {
            currentLine = ""
            nextLine = ""
            return
        }
        
        currentLine = lines[currentLineIndex].text
        
        // Set next line if available
        if currentLineIndex + 1 < lines.count {
            nextLine = lines[currentLineIndex + 1].text
        } else {
            nextLine = ""
        }
    }
    
    func clear() {
        if let id = displayTimerID {
            DisplayTimer.shared.remove(id)
            displayTimerID = nil
        }
        currentLineIndex = 0
        currentLine = ""
        nextLine = ""
        lines = []
    }
    
    // MARK: - Helpers
    
    /// Get the timestamp of the current line
    var currentLineTimestamp: TimeInterval? {
        guard !lines.isEmpty, currentLineIndex < lines.count else {
            return nil
        }
        return lines[currentLineIndex].timestamp
    }
    
    /// Get the timestamp of the next line (for calculating line duration)
    var nextLineTimestamp: TimeInterval? {
        guard !lines.isEmpty, currentLineIndex + 1 < lines.count else {
            return nil
        }
        return lines[currentLineIndex + 1].timestamp
    }
    
    /// Calculate the duration of the current line
    var currentLineDuration: TimeInterval? {
        guard let current = currentLineTimestamp,
              let next = nextLineTimestamp else {
            return nil
        }
        return next - current
    }
}
