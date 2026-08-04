//
//  MiniPlayerView.swift
//  Lychee
//
//  Compact song header: 90×90 album art, right column with title/artist/open-button,
//  progress bar, and playback controls. Settings moved to Customise Lychee section.
//

import SwiftUI
import AppKit

struct MiniPlayerView: View {
    @ObservedObject var trackState = TrackState.shared

    @State private var isHoveringBar = false
    @State private var hoverX: CGFloat = 0
    @State private var isDragging = false
    @State private var dragProgress: CGFloat = 0
    @State private var isInteracting = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            albumArtView
                .frame(width: 90, height: 90)

            VStack(alignment: .leading, spacing: 0) {
                // Title + artist + open-player button
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(trackState.trackName.isEmpty ? "Nothing playing" : trackState.trackName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(trackState.artistName.isEmpty ? " " : trackState.artistName)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: goToPlayer) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .lycheeFocusEffectDisabled()
                }

                progressBar
                    .padding(.top, 8)

                playbackControlsView
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Album Art

    private var albumArtView: some View {
        Group {
            if let artworkData = trackState.artworkData,
               let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let artworkURL = trackState.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().frame(width: 90, height: 90)
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        fallbackArtwork
                    @unknown default:
                        fallbackArtwork
                    }
                }
            } else {
                fallbackArtwork
            }
        }
        .frame(width: 90, height: 90)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .overlay {
            if !trackState.isPlaying && !trackState.trackName.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.4))
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 5, height: 22)
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 5, height: 22)
                    }
                    .foregroundColor(.white.opacity(0.9))
                }
            }
        }
    }

    private var fallbackArtwork: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: "music.note")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Progress Bar

    private var isActive: Bool { isHoveringBar || isDragging }

    private var progressBar: some View {
        GeometryReader { geo in
            let actualProgress = trackState.duration > 0
                ? max(0, min(1, trackState.position / trackState.duration))
                : 0
            // While isInteracting, ignore the poller and show the cursor-committed
            // position. Prevents rubber-band jump while the backend catches up.
            let displayProgress = isInteracting ? dragProgress : actualProgress
            let w = geo.size.width
            let thumbX: CGFloat = w > 0 ? max(0, min(w - 12, w * displayProgress - 6)) : 0
            let trackH: CGFloat = isActive ? 5 : 3
            // Preview width follows cursor directly — no animation, instant tracking.
            let previewWidth: CGFloat = w > 0 ? max(0, min(w, hoverX)) : 0

            ZStack(alignment: .leading) {

                // ── Layer 1: Background track ──────────────────────────────────
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: w, height: trackH)
                    .animation(.easeOut(duration: 0.1), value: isActive)

                // ── Layer 2: Preview fill (cursor hint) ────────────────────────
                // Neutral gray — shows where the user is about to seek.
                // Width follows hoverX with zero animation (instant cursor tracking).
                // Height and opacity animate together when hover state changes.
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: previewWidth, height: trackH)
                    .opacity(isHoveringBar && !isDragging ? 1.0 : 0.0)
                    .animation(.easeOut(duration: 0.1), value: isHoveringBar && !isDragging)

                // ── Layer 3: Blue progress fill ────────────────────────────────
                // Sits on top of preview — blue always wins over gray.
                // Width is instant during interaction (nil), springs after.
                // Height eases with isActive.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, w * displayProgress), height: trackH)
                    .animation(.easeOut(duration: 0.1), value: isActive)
                    .animation(
                        isInteracting ? nil : .interactiveSpring(response: 0.15, dampingFraction: 0.85),
                        value: displayProgress
                    )

                // ── Layer 4: Thumb at end of blue bar ─────────────────────────
                // Presence: opacity-only (no scaleEffect — scale "inflation" is
                //   visible even at 80ms). Instant pop via easeOut(0.08).
                // Position: interactiveSpring for smooth playhead tracking.
                //   nil during interaction so it's pixel-perfect under cursor.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .opacity(isActive ? 1.0 : 0.0)
                    .animation(.easeOut(duration: 0.08), value: isActive)
                    .offset(x: thumbX)
                    .animation(
                        isInteracting ? nil : .interactiveSpring(response: 0.15, dampingFraction: 0.85),
                        value: thumbX
                    )
            }
            .frame(width: w, height: 14)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHoveringBar = true
                    hoverX = location.x
                case .ended:
                    if !isDragging { isHoveringBar = false }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        isHoveringBar = true
                        isInteracting = true
                        dragProgress = max(0, min(1, value.location.x / w))
                        hoverX = value.location.x
                        if trackState.duration > 0 {
                            MusicPoller.shared.seek(to: dragProgress * trackState.duration)
                        }
                    }
                    .onEnded { value in
                        let p = max(0, min(1, value.location.x / w))
                        dragProgress = p
                        if trackState.duration > 0 {
                            MusicPoller.shared.seek(to: p * trackState.duration)
                        }
                        isDragging = false
                        isHoveringBar = false
                        // Hold isInteracting for 300ms so the poller's updated
                        // position replaces dragProgress before we cut over,
                        // preventing any visible jump.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isInteracting = false
                        }
                    }
            )
        }
        .frame(height: 14)
    }

    // MARK: - Playback Controls

    private var playbackControlsView: some View {
        HStack(spacing: 20) {
            Spacer()
            CircleControlButton(
                icon: "backward.fill",
                size: 28,
                iconSize: 12,
                backgroundOpacity: 0.08,
                action: previousTrack
            )
            CircleControlButton(
                icon: trackState.isPlaying ? "pause.fill" : "play.fill",
                size: 32,
                iconSize: 13,
                backgroundOpacity: 0.15,
                strokeOpacity: 0.2,
                action: playPause
            )
            CircleControlButton(
                icon: "forward.fill",
                size: 28,
                iconSize: 12,
                backgroundOpacity: 0.08,
                action: nextTrack
            )
            Spacer()
        }
    }

    // MARK: - Actions

    private func playPause() {
        MusicPoller.shared.playPause()
    }

    private func nextTrack() {
        MusicPoller.shared.nextTrack()
    }

    private func previousTrack() {
        // If more than 3s in, seek to 0 first so the OS "previous" command
        // goes to the actual previous song rather than restarting the current one.
        if TrackState.shared.position > 3 {
            MusicPoller.shared.seek(to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MusicPoller.shared.previousTrack()
            }
        } else {
            MusicPoller.shared.previousTrack()
        }
    }

    private func goToPlayer() {
        switch trackState.source {
        case .spotifyApp:
            NSWorkspace.shared.open(URL(string: "spotify:")!)
        case .appleMusicApp:
            NSWorkspace.shared.open(URL(string: "music://")!)
        case .none:
            break
        }
    }
}

// MARK: - Circular Control Button

struct CircleControlButton: View {
    let icon: String
    let size: CGFloat
    let iconSize: CGFloat
    let backgroundOpacity: Double
    var strokeOpacity: Double = 0.1
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color.white.opacity(
                            isHovered ? backgroundOpacity + 0.08 : backgroundOpacity
                        ))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.5)
                        )
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
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

// MARK: - Gap Style Button

struct GapStyleButton: View {
    let style: TrackState.GapStyle
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(style.rawValue)
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
                                .stroke(
                                    isSelected ? Color.clear : Color.secondary.opacity(0.3),
                                    lineWidth: 0.5
                                )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Inactivity Button

struct InactivityButton: View {
    let timeout: TrackState.InactivityTimeout
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(timeout.rawValue)
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
                                .stroke(
                                    isSelected ? Color.clear : Color.secondary.opacity(0.3),
                                    lineWidth: 0.5
                                )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}
