//
//  PopoverView.swift
//  Lychee
//
//  Root popover container: mini player, lyrics panel with cycling controls,
//  Customise Lychee collapsible section, dev mode easter egg, and bottom action bar.
//

import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var trackState = TrackState.shared
    @ObservedObject var lyricsEngine = LyricsEngine.shared

    // Slide animation state for candidate cycling
    @State private var panelGeneration: Int = 0
    @State private var panelForward: Bool = true
    @State private var shortcutMonitor: Any? = nil
    @State private var pressedFooterAction: FooterAction? = nil

    // Dev mode easter egg
    #if DEBUG
    @State private var devKeyBuffer: String = ""
    @State private var devEnterCount: Int = 0
    @State private var devModeActive: Bool = false
    @State private var eventMonitor: Any? = nil
    @State private var isDevModeExpanded: Bool = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if trackState.trackName.isEmpty {
                emptyStateView
            } else {
                MiniPlayerView()
            }

            let hasLyrics      = trackState.lyricsState == .synced && !trackState.lines.isEmpty
            let hasPlainLyrics = trackState.lyricsState == .plainOnly && !trackState.plainLyrics.isEmpty
            let hasCandidates  = !trackState.allCandidates.isEmpty
            let sessionRejected = trackState.lyricsRejectedForSession

            Divider()
            lyricsContainerView(
                hasLyrics: hasLyrics,
                hasPlainLyrics: hasPlainLyrics,
                hasCandidates: hasCandidates,
                sessionRejected: sessionRejected
            )

            #if DEBUG
            if devModeActive {
                Divider()
                devModeSection
            }
            #endif

            Divider()

            footerView
        }
        .frame(width: 320)
        .contentShape(Rectangle())
        .onTapGesture {}
        .focusable(false)
        .lycheeFocusEffectDisabled()
        .onAppear { startShortcutMonitoring() }
        .onDisappear { stopShortcutMonitoring() }
        #if DEBUG
        .onAppear { startKeyMonitoring() }
        .onDisappear { stopKeyMonitoring() }
        .onChange(of: trackState.isPopoverShown) { isShown in
            if !isShown {
                isDevModeExpanded = false
                devModeActive = false
            }
        }
        #endif
        .onChange(of: trackState.candidateIndex) { _ in
            panelForward = TrackState.shared.lastCycleDirection >= 0
            withAnimation(.easeInOut(duration: 0.22)) {
                panelGeneration += 1
            }
        }
    }

    // MARK: - Lyrics Container

    private func lyricsContainerView(hasLyrics: Bool, hasPlainLyrics: Bool, hasCandidates: Bool, sessionRejected: Bool) -> some View {
        VStack(spacing: 0) {
            if sessionRejected {
                Text("Lyrics hidden")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.35))
                    .frame(width: 320, height: 160)
            } else if hasLyrics {
                LyricsScrollPanel()
                    .id(panelGeneration)
                    .transition(.asymmetric(
                        insertion: .move(edge: panelForward ? .trailing : .leading).combined(with: .opacity),
                        removal:   .move(edge: panelForward ? .leading  : .trailing).combined(with: .opacity)
                    ))
            } else if hasPlainLyrics {
                PlainLyricsView()
                    .transition(.opacity)
            } else {
                lyricsPlaceholder
            }

            // Always reserve space for the cycling row while loading or when
            // candidates exist — prevents the popover from resizing mid-song.
            if hasCandidates || trackState.lyricsState == .loading {
                Color.primary.opacity(0.08)
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                LyricsCyclingControls(sessionRejected: Binding(
                    get: { TrackState.shared.lyricsRejectedForSession },
                    set: { TrackState.shared.lyricsRejectedForSession = $0 }
                ))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    private var lyricsPlaceholder: some View {
        let message: String = {
            if trackState.trackName.isEmpty { return "Play a song to see the lyrics" }
            switch trackState.lyricsState {
            case .notFound: return "No lyrics found for this song"
            default:        return "Loading lyrics..."
            }
        }()
        return Text(message)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(width: 320, height: 160)
    }

    // MARK: - Dev Mode Section (easter egg — type "letmein" + enter twice)

    #if DEBUG
    private var devModeSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDevModeExpanded.toggle()
                }
            }) {
                HStack {
                    Text("Dev Mode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .rotationEffect(.degrees(isDevModeExpanded ? 0 : 180))
                        .animation(.easeInOut(duration: 0.2), value: isDevModeExpanded)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lycheeFocusEffectDisabled()

            if isDevModeExpanded {
                VStack(spacing: 0) {
                    // Algo picker — same layout pattern as Gap Style / Inactivity
                    HStack(spacing: 8) {
                        Text("Algo")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        HStack(spacing: 6) {
                            ForEach(TrackState.AlgorithmVersion.allCases, id: \.self) { v in
                                AlgoButton(version: v, isSelected: trackState.algorithmVersion == v) {
                                    trackState.setAlgorithmVersion(v)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    Button(action: { AlgoDebugWindowController.shared.show() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chart.bar.doc.horizontal")
                                .font(.system(size: 11))
                            Text("Open Algorithm Debug")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.blue.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(Color.blue.opacity(0.07))
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()

                    Button(action: clearCache) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Clear all saved lyrics")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.red.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(Color.red.opacity(0.07))
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()
                    .padding(.top, 1)
                }
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Dev Mode Key Monitoring
    #endif

    #if DEBUG
    private func startKeyMonitoring() {
        devKeyBuffer = ""
        devEnterCount = 0
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 {  // space — play/pause
                MusicPoller.shared.playPause()
                return nil
            }
            self.handleKeyEvent(event)
            return event
        }
    }

    private func stopKeyMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        devKeyBuffer = ""
        devEnterCount = 0
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard !devModeActive else { return }
        let expected    = "letmein"
        let isReturn    = event.keyCode == 36 || event.keyCode == 76
        let isBackspace = event.keyCode == 51

        if isBackspace { devKeyBuffer = ""; devEnterCount = 0; return }

        if devKeyBuffer == expected {
            if isReturn {
                devEnterCount += 1
                if devEnterCount >= 2 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        devModeActive = true
                    }
                }
            } else {
                devKeyBuffer = ""; devEnterCount = 0
                accumulate(event: event, expected: expected)
            }
            return
        }
        if isReturn { devKeyBuffer = ""; devEnterCount = 0; return }
        accumulate(event: event, expected: expected)
    }

    private func accumulate(event: NSEvent, expected: String) {
        guard let raw = event.charactersIgnoringModifiers?.lowercased(),
              raw.count == 1, let c = raw.first, c.isLetter else { devKeyBuffer = ""; return }
        devKeyBuffer += String(c)
        if devKeyBuffer.count > expected.count {
            devKeyBuffer = String(devKeyBuffer.suffix(expected.count))
        }
        if !expected.hasPrefix(devKeyBuffer) {
            devKeyBuffer = String(c)
            if !expected.hasPrefix(devKeyBuffer) { devKeyBuffer = "" }
        }
    }
    #endif

    // MARK: - Empty State

    private var emptyStateView: some View {
        HStack(spacing: 10) {
            AppLaunchButton(
                title: "Spotify",
                icon: "music.note",
                iconColor: .green.opacity(0.85)
            ) {
                NSWorkspace.shared.open(URL(string: "spotify:")!)
            }
            AppLaunchButton(
                title: "Apple Music",
                icon: "music.note.list",
                iconColor: .pink.opacity(0.85)
            ) {
                openAppleMusic()
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func openAppleMusic() {
        if let musicApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music"
        ).first {
            musicApp.activate(options: .activateIgnoringOtherApps)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Actions

    private var footerView: some View {
        HStack(spacing: 0) {
            FooterButton(
                title: "Refresh (⌘R)",
                icon: "arrow.clockwise",
                style: .neutral,
                isShortcutPressed: pressedFooterAction == .refresh,
                action: performRefresh
            )
            footerDivider
            FooterButton(
                title: "Settings (⌘,)",
                icon: "gear",
                style: .neutral,
                isShortcutPressed: pressedFooterAction == .settings
            ) {
                flashFooterAction(.settings)
                AppDelegate.shared?.showSettings()
            }
            footerDivider
            FooterButton(
                title: "Quit (⌘Q)",
                icon: "power",
                style: .destructive,
                isShortcutPressed: pressedFooterAction == .quit
            ) {
                AppDelegate.shared?.quitFromPopover()
            }
        }
        .frame(width: 320, height: 52)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footerDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 52)
    }

    private func performRefresh() {
        flashFooterAction(.refresh)
        restartApp()
    }

    private func restartApp() {
        let ts = TrackState.shared
        if !ts.trackName.isEmpty {
            // Song is known — just cancel any in-flight fetch and retry from scratch.
            // No poller restart, no track-name flash, no 400ms dead time.
            let track = TrackInfo(
                name: ts.trackName,
                artist: ts.artistName,
                album: ts.albumName,
                duration: ts.duration,
                position: ts.position,
                trackID: ts.currentTrackID,
                isPlaying: ts.isPlaying,
                artworkURL: ts.artworkURL
            )
            ts.clearLyrics()
            LRCLibService.shared.refetchLyrics(for: track)
        } else {
            // Nothing detected yet — full poller restart to re-detect the source.
            MusicPoller.shared.stop()
            MediaRemotePoller.shared.stop()
            TrackState.shared.clear()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MusicPoller.shared.start()
                MediaRemotePoller.shared.start()
            }
        }
    }

    private func clearCache() {
        LyricsCache.shared.clearAll()
        TrackState.shared.savedCandidateLRC = nil
    }

    private func flashFooterAction(_ action: FooterAction) {
        pressedFooterAction = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            if self.pressedFooterAction == action {
                self.pressedFooterAction = nil
            }
        }
    }

    private func startShortcutMonitoring() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard TrackState.shared.isPopoverShown else { return event }
            guard event.modifierFlags.contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            switch key {
            case "r":
                self.performRefresh()
                return nil
            case ",":
                self.flashFooterAction(.settings)
                AppDelegate.shared?.showSettings()
                return nil
            case "q":
                self.flashFooterAction(.quit)
                AppDelegate.shared?.quitFromPopover()
                return nil
            default:
                return event
            }
        }
    }

    private func stopShortcutMonitoring() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }
}

private enum FooterAction {
    case refresh, settings, quit
}

// MARK: - Edge Blur (NSViewRepresentable)
// Pure Gaussian blur via CALayer.backgroundFilters — blurs the lyrics content behind the overlay.
// 1% black background, gradient mask fades blur from full at the panel edge to zero toward lyrics.

private final class GradientEffectView: NSView {
    var isTop: Bool { didSet { needsLayout = true } }
    private var gradientLayer: CAGradientLayer?
    private var blurInstalled = false

    init(isTop: Bool) {
        self.isTop = isTop
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let layer = layer, bounds.size != .zero else { return }

        if !blurInstalled {
            layer.backgroundColor = CGColor(gray: 0, alpha: 0.01)
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(16.0, forKey: "inputRadius")
                layer.backgroundFilters = [blur]
                layer.needsDisplayOnBoundsChange = true
            }
            blurInstalled = true
        }

        if gradientLayer == nil {
            let gl = CAGradientLayer()
            gl.colors    = [CGColor(gray: 0, alpha: 1.0),
                            CGColor(gray: 0, alpha: 0.6),
                            CGColor(gray: 0, alpha: 0.0)]
            gl.locations = [0, 0.45, 1]
            layer.mask   = gl
            gradientLayer = gl
        }
        let gl = gradientLayer!
        gl.frame = bounds
        // CA layers on macOS: y=1.0 = physical top, y=0.0 = physical bottom (non-flipped)
        gl.startPoint = isTop ? CGPoint(x: 0.5, y: 1.0) : CGPoint(x: 0.5, y: 0.0)
        gl.endPoint   = isTop ? CGPoint(x: 0.5, y: 0.0) : CGPoint(x: 0.5, y: 1.0)
    }
}

private struct EdgeBlur: NSViewRepresentable {
    let isTop: Bool
    func makeNSView(context: Context) -> GradientEffectView { GradientEffectView(isTop: isTop) }
    func updateNSView(_ nsView: GradientEffectView, context: Context) { nsView.isTop = isTop }
}

// MARK: - Lyrics Animated Panel

private struct LineHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LyricsScrollPanel: View {
    @ObservedObject var trackState = TrackState.shared
    @ObservedObject var lyricsEngine = LyricsEngine.shared

    @State private var lineHeights: [Int: CGFloat] = [:]
    @State private var manualOffset: CGFloat = 0
    @State private var isUserScrolled: Bool = false
    @State private var frozenCurrentIdx: Int = 0
    @State private var scrollMonitor: Any? = nil

    private var gap:    CGFloat { TrackState.shared.lyricsFontSize.lineGap }
    private let center: CGFloat = 80
    private let radius: Int    = 6

    var body: some View {
        let currentIdx = lyricsEngine.currentLineIndex
        let displayIdx = isUserScrolled ? frozenCurrentIdx : currentIdx
        // When scrolling, render all lines so none go missing beyond the radius window.
        // The ZStack's .clipped() still limits what's actually visible to 160px.
        let effectiveRadius = isUserScrolled ? max(trackState.lines.count, radius) : radius

        ZStack {
            Color.clear

            let noteRel = -1 - displayIdx
            if noteRel >= -effectiveRadius {
                let noteBlur: CGFloat = isUserScrolled ? 0 : {
                    switch abs(noteRel) {
                    case 1:  return 0.6
                    case 2:  return 1.8
                    case 3:  return 3.5
                    default: return 5.5
                    }
                }()
                Text("♪")
                    .font(.system(size: trackState.lyricsFontSize.noteSize, weight: .thin, design: .rounded))
                    .foregroundColor(.primary.opacity(0.25))
                    .frame(width: 288, alignment: .leading)
                    .blur(radius: noteBlur)
                    .animation(.spring(response: 0.50, dampingFraction: 0.90), value: noteBlur)
                    .position(x: 160, y: yPos(at: -1, currentIdx: displayIdx) + manualOffset)
                    .animation(positionAnimation(), value: displayIdx)
            }

            ForEach(Array(trackState.lines.enumerated()), id: \.offset) { i, line in
                let rel = i - displayIdx
                if abs(rel) <= effectiveRadius {
                    LyricLineRow(
                        text: line.text,
                        isCurrent: rel == 0,
                        relativeIndex: rel,
                        blurDisabled: isUserScrolled
                    )
                    .frame(width: 288)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: LineHeightKey.self, value: [i: geo.size.height])
                        }
                    )
                    .position(x: 160, y: yPos(at: i, currentIdx: displayIdx) + manualOffset)
                    .animation(positionAnimation(), value: displayIdx)
                    .onTapGesture {
                        guard TrackState.shared.duration > 0 else { return }
                        MusicPoller.shared.seek(to: line.timestamp)
                        if !TrackState.shared.isPlaying {
                            MusicPoller.shared.playPause()
                        }
                        manualOffset = 0
                        isUserScrolled = false
                    }
                }
            }
        }
        .frame(width: 320, height: 160)
        .clipped()
        .overlay(alignment: .top)    { EdgeBlur(isTop: true).frame(height: 36).allowsHitTesting(false) }
        .overlay(alignment: .bottom) { EdgeBlur(isTop: false).frame(height: 36).allowsHitTesting(false) }
        .overlay(alignment: .bottomTrailing) {
            if isUserScrolled {
                Button(action: syncToPlayback) {
                    Text("Sync")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .lycheeFocusEffectDisabled()
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onPreferenceChange(LineHeightKey.self) { heights in
            for (idx, h) in heights where h > 0 { lineHeights[idx] = h }
        }
        .onChange(of: trackState.lines.count) { _ in lineHeights = [:] }
        .onAppear  { startScrollMonitoring() }
        .onDisappear { stopScrollMonitoring() }
    }

    private func startScrollMonitoring() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta = event.scrollingDeltaY
            if abs(delta) > 0.5 {
                DispatchQueue.main.async {
                    if !self.isUserScrolled {
                        self.frozenCurrentIdx = self.lyricsEngine.currentLineIndex
                        self.isUserScrolled = true
                    }
                    let count = TrackState.shared.lines.count
                    guard count > 0 else { return }
                    // Compute exact scroll bounds from actual line positions.
                    // Stops at first line visible at top edge, last line at bottom edge.
                    // Uses measured lineHeights if available (defaults to 20px otherwise).
                    let topY    = self.yPos(at: 0,         currentIdx: self.frozenCurrentIdx)
                    let bottomY = self.yPos(at: count - 1, currentIdx: self.frozenCurrentIdx)
                    let maxUp   = max(0, -topY + 20)      // first line at y≈20 (inside top blur)
                    let maxDown = max(0, bottomY - 140)   // last line at y≈140 (inside bottom blur)
                    self.manualOffset = max(-maxDown, min(maxUp, self.manualOffset + delta))
                }
            }
            return event
        }
    }

    private func stopScrollMonitoring() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func syncToPlayback() {
        manualOffset = 0
        isUserScrolled = false
    }

    private func yPos(at i: Int, currentIdx: Int) -> CGFloat {
        if i == currentIdx { return center }
        let step = i > currentIdx ? 1 : -1
        var y = center
        var j = currentIdx
        while j != i {
            let thisH = lineHeights[j]    ?? 20
            let nextJ = j + step
            let nextH = lineHeights[nextJ] ?? 20
            y += CGFloat(step) * (thisH / 2 + gap + nextH / 2)
            j = nextJ
        }
        return y
    }

    private func positionAnimation() -> Animation {
        .spring(response: 0.70, dampingFraction: 0.98, blendDuration: 0)
    }
}

// MARK: - Lyric Line Row

struct LyricLineRow: View {
    let text: String
    let isCurrent: Bool
    let relativeIndex: Int
    var blurDisabled: Bool = false
    @ObservedObject private var trackState = TrackState.shared

    private var lineBlur: CGFloat {
        guard !blurDisabled else { return 0 }
        switch abs(relativeIndex) {
        case 0:  return 0
        case 1:  return 1.0
        case 2:  return 1.8
        case 3:  return 3.6
        default: return 4.5
        }
    }

    var body: some View {
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: trackState.lyricsFontSize.syncedSize, weight: .semibold, design: .rounded))
            .foregroundColor(isCurrent ? Color.primary : Color.primary.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isCurrent ? 1.0 : 0.95, anchor: .leading)
            .animation(.spring(response: 0.50, dampingFraction: 0.90), value: isCurrent)
            .blur(radius: lineBlur)
            .animation(.spring(response: 0.50, dampingFraction: 0.90), value: lineBlur)
    }
}

// MARK: - Plain Lyrics View

struct PlainLyricsView: View {
    @ObservedObject var trackState = TrackState.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(trackState.plainLyrics)
                .font(.system(size: trackState.lyricsFontSize.plainSize, weight: .regular))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 36)
                .padding(.bottom, 24)
        }
        .frame(height: 160)
        .overlay(alignment: .top)    { EdgeBlur(isTop: true).frame(height: 36).allowsHitTesting(false) }
        .overlay(alignment: .bottom) { EdgeBlur(isTop: false).frame(height: 36).allowsHitTesting(false) }
        .clipped()
    }
}

// MARK: - Lyrics Cycling Controls

struct LyricsCyclingControls: View {
    @Binding var sessionRejected: Bool
    @ObservedObject var trackState = TrackState.shared

    @State private var prevHovered = false
    @State private var prevPressed = false
    @State private var nextHovered = false
    @State private var nextPressed = false
    @State private var noneRightHovered = false
    // Tracks which candidate indices the user has visited in the current session
    @State private var visitedIndices: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            if sessionRejected {
                // Restore bar — same height as cycling row so popover doesn't resize
                HStack {
                    Text("Lyrics hidden for now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                    Button("Restore") { sessionRejected = false }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .buttonStyle(.plain)
                        .lycheeFocusEffectDisabled()
                }
                .frame(height: 30)
                .frame(maxWidth: .infinity)
            } else if trackState.allCandidates.isEmpty {
                // Loading placeholder — keeps height stable while network requests run
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                    Text("Finding lyrics...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.45))
                    Spacer()
                }
                .frame(height: 30)
            } else {
                let count      = trackState.allCandidates.count
                let candidate  = trackState.allCandidates[trackState.candidateIndex]
                let isSaved    = candidate.lrc == trackState.savedCandidateLRC
                let canCycle   = count > 1
                let hasSeenAll = visitedIndices.count >= count

                // Cycling controls row
                HStack(spacing: 8) {
                    Text("Change Lyrics")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()

                    // Prev button
                    Button(action: { LRCLibService.shared.stepCandidate(by: -1) }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(canCycle ? .accentColor : .secondary.opacity(0.28))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(prevPressed
                                          ? Color.primary.opacity(0.14)
                                          : prevHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()
                    .disabled(!canCycle)
                    .onHover { prevHovered = $0 }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in prevPressed = true }
                            .onEnded   { _ in prevPressed = false }
                    )

                    // Counter pill — spinner only when hydrating (avoids cramped count+loader layout)
                    VStack(spacing: 1) {
                        if trackState.isHydrating {
                            ProgressView()
                                .scaleEffect(0.42)
                        } else {
                            Text("\(trackState.candidateIndex + 1) / \(count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                            if !candidate.isSynced {
                                Text("no sync")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.orange.opacity(0.75))
                            }
                        }
                    }
                    .frame(width: 60, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    )

                    // Next button
                    Button(action: { LRCLibService.shared.stepCandidate(by: +1) }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(canCycle ? .accentColor : .secondary.opacity(0.28))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(nextPressed
                                          ? Color.primary.opacity(0.14)
                                          : nextHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()
                    .disabled(!canCycle)
                    .onHover { nextHovered = $0 }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in nextPressed = true }
                            .onEnded   { _ in nextPressed = false }
                    )

                    // Save button — expands to fill remaining row space
                    Button(action: { LRCLibService.shared.saveCurrentCandidate() }) {
                        Text(isSaved ? "Saved" : "Save")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isSaved ? .secondary : .accentColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSaved ? Color.primary.opacity(0.04) : Color.accentColor.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                isSaved ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.35),
                                                lineWidth: 0.5
                                            )
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()
                    .disabled(isSaved)
                }
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Full-width "None right" button — revealed only after the user has
                // seen every available option AND all candidates have loaded.
                // Session-only: no cache write, fully reversible.
                if hasSeenAll && !trackState.isHydrating {
                    Button(action: { sessionRejected = true }) {
                        Text("None of these are correct")
                            .font(.system(size: 11))
                            .foregroundColor(noneRightHovered ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(noneRightHovered ? 0.07 : 0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()
                    .onHover { noneRightHovered = $0 }
                    .padding(.top, 6)
                    .transition(.opacity.animation(.easeIn(duration: 0.18)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { visitedIndices.insert(trackState.candidateIndex) }
        .onChange(of: trackState.candidateIndex) { idx in visitedIndices.insert(idx) }
        // Reset visited list when fresh candidates arrive (new song or post-loading)
        .onChange(of: trackState.allCandidates.count) { newCount in
            if newCount > 0 { visitedIndices = [trackState.candidateIndex] }
        }
    }
}

// MARK: - Algo Button

#if DEBUG
struct AlgoButton: View {
    let version: TrackState.AlgorithmVersion
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(version.rawValue)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .foregroundColor(isSelected ? .white : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}
#endif

// MARK: - Footer Button (3-up footer: Refresh | Settings | Quit)

private struct FooterButton: View {
    enum Style { case neutral, destructive }

    let title: String
    let icon: String
    let style: Style
    let isShortcutPressed: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        title: String,
        icon: String,
        style: Style,
        isShortcutPressed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.isShortcutPressed = isShortcutPressed
        self.action = action
    }

    private var fgColor: Color {
        switch style {
        case .neutral:
            return (isHovered || isShortcutPressed) ? Color.primary.opacity(0.85) : Color.primary.opacity(0.55)
        case .destructive:
            return (isHovered || isShortcutPressed) ? .red : Color.primary.opacity(0.55)
        }
    }

    private var bgColor: Color {
        switch style {
        case .neutral:
            return (isPressed || isShortcutPressed)
                ? Color.primary.opacity(0.15)
                : isHovered ? Color.primary.opacity(0.08) : Color.clear
        case .destructive:
            return (isPressed || isShortcutPressed)
                ? Color.red.opacity(0.18)
                : isHovered ? Color.red.opacity(0.10) : Color.clear
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(fgColor)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(bgColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .frame(height: 52)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

// MARK: - App Launch Button (empty state)

struct AppLaunchButton: View {
    let title: String
    let icon: String
    let iconColor: Color
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPressed
                          ? Color.primary.opacity(0.12)
                          : isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}
