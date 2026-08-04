//
//  AlbumThumb.swift
//  Lychee
//
//  20x20 circular rotating album art thumbnail for menu bar
//

import SwiftUI

struct AlbumThumb: View {
    @ObservedObject var trackState = TrackState.shared

    @State private var rotation: Double = 0
    @State private var timerID: UUID? = nil

    var body: some View {
        Group {
            if trackState.trackName.isEmpty {
                // No song: app logo placeholder (will be replaced with real logo later)
                logoPlaceholder
            } else if let artworkData = trackState.artworkData,
                      let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let artworkURL = trackState.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .empty, .failure:
                        fallbackView
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    @unknown default:
                        fallbackView
                    }
                }
            } else {
                fallbackView
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(Circle())
        .rotationEffect(.degrees(rotation))
        .overlay {
            // Pause indicator only when a song is known but currently paused
            if !trackState.isPlaying && !trackState.trackName.isEmpty {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.4))
                    HStack(spacing: 2.5) {
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 2.5, height: 8)
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 2.5, height: 8)
                    }
                    .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .onAppear {
            if trackState.isPlaying {
                startRotation()
            }
        }
        .onDisappear {
            stopRotation()
        }
        .onChange(of: trackState.isPlaying) { isPlaying in
            if isPlaying {
                startRotation()
            } else {
                stopRotation()
            }
        }
    }

    private var logoPlaceholder: some View {
        Image("lycheeicon")
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    private var fallbackView: some View {
        Image("lycheeicon")
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    private func startRotation() {
        guard timerID == nil else { return }
        timerID = DisplayTimer.shared.add {
            rotation += 360.0 / (4.0 * 60.0)
            if rotation >= 360 { rotation -= 360 }
        }
    }

    private func stopRotation() {
        if let id = timerID {
            DisplayTimer.shared.remove(id)
            timerID = nil
        }
    }
}
