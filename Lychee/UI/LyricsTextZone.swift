//
//  LyricsTextZone.swift
//  Lychee
//
//  Fixed-width lyrics text display with 2-line wrapping
//

import SwiftUI
import Combine
import AppKit

struct LyricsTextZone: View {
    @ObservedObject var trackState = TrackState.shared
    @ObservedObject var lyricsEngine = LyricsEngine.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Dark text on a light menu bar reads thinner than white on dark, so light
    /// mode uses weight 450 (halfway between Regular 400 and Medium 500) via
    /// SF Pro's variable 'wght' axis. Shared with MenuBarContentView.measureTextWidth
    /// so layout measurement stays in sync with rendering.
    private static let regularFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let lightModeFont: NSFont = {
        let wghtAxis = NSNumber(value: 0x77676874) // 'wght'
        let descriptor = regularFont.fontDescriptor.addingAttributes([.variation: [wghtAxis: 450]])
        return NSFont(descriptor: descriptor, size: 11) ?? regularFont
    }()

    static func menuBarFont(for scheme: ColorScheme) -> NSFont {
        scheme == .light ? lightModeFont : regularFont
    }

    @State private var lineID = UUID()
    @State private var dotCount: Int = 1
    @State private var welcomeFinished = false

    private let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var dots: String { String(repeating: ".", count: dotCount) }

    /// The stable part of the message — changes to this trigger AS1.
    private var baseText: String {
        if trackState.trackName.isEmpty {
            return welcomeFinished ? "♪  Play a song to get started" : "♪  Welcome to Lychee"
        }

        if trackState.lyricsRejectedForSession {
            let artist = trackState.artistName
            return artist.isEmpty ? trackState.trackName : "\(trackState.trackName) · \(artist)"
        }

        switch trackState.lyricsState {
        case .synced:
            if !trackState.isPlaying { return trackState.trackName }
            return lyricsEngine.isInGap ? "♪ music" : lyricsEngine.currentLine
        case .loading:
            switch trackState.loadingPhase {
            case .initial:      return "\(trackState.trackName) — loading lyrics"
            case .takingLonger: return "Taking a bit longer than usual"
            case .nicheChoice:  return "\"\(trackState.trackName)\" very niche choice hm"
            case .lastTry:      return "Alright one last try"
            }
        case .notFound:
            return trackState.trackName
        case .plainOnly:
            return "\(trackState.trackName) — No synced lyrics"
        case .idle:
            return trackState.trackName
        }
    }

    /// Whether the current state should show animated dots.
    private var showDots: Bool {
        trackState.lyricsState == .loading
    }

    /// If `text` would wrap to 2 lines within `maxWidth`, returns it with a `\n`
    /// inserted at the word boundary that most evenly balances the two line widths.
    /// Returns `text` unchanged if it fits on one line.
    private func balancedText(_ text: String, maxWidth: CGFloat = 260) -> String {
        let font = Self.menuBarFont(for: colorScheme)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attrs).width > maxWidth else { return text }
        let words = text.components(separatedBy: " ")
        guard words.count > 1 else { return text }
        var bestSplit = 1
        var bestDiff = CGFloat.infinity
        for i in 1..<words.count {
            let w1 = (words[0..<i].joined(separator: " ") as NSString).size(withAttributes: attrs).width
            let w2 = (words[i...].joined(separator: " ") as NSString).size(withAttributes: attrs).width
            let diff = abs(w1 - w2)
            if diff < bestDiff { bestDiff = diff; bestSplit = i }
        }
        return words[0..<bestSplit].joined(separator: " ") + "\n" + words[bestSplit...].joined(separator: " ")
    }

    var body: some View {
        Text(balancedText(baseText) + (showDots ? dots : ""))
            .font(Font(Self.menuBarFont(for: colorScheme) as CTFont))
            .foregroundColor(textColor)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)
            .id(lineID)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            // AS1 fires only when the base message changes, not on dot ticks
            .onChange(of: baseText) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    lineID = UUID()
                }
            }
            // Dot timer — only cycles count, never touches lineID
            .onReceive(dotTimer) { _ in
                guard showDots else { return }
                dotCount = dotCount % 3 + 1
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    welcomeFinished = true
                }
            }
    }

    /// Uses `.primary` so the text follows the menu bar's effective appearance
    /// (which macOS derives from the wallpaper, not the system theme):
    /// white on a dark menu bar, black on a light one.
    private var textColor: Color {
        if trackState.trackName.isEmpty {
            // "Welcome to Lychee" → full strength; "Play a song to get started" → visible but softer
            return welcomeFinished ? .primary.opacity(0.75) : .primary
        }

        if trackState.lyricsState == .synced && trackState.isPlaying {
            return .primary.opacity(0.9)
        } else {
            return .primary.opacity(0.6)
        }
    }
}
