//
//  GapFillView.swift
//  Lychee
//
//  Fills the gap between lyrics text and waveform icon
//

import SwiftUI

struct GapFillView: View {
    @ObservedObject var trackState = TrackState.shared
    let width: CGFloat
    
    var body: some View {
        Group {
            if width < 20 {
                Color.clear
            } else {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    
                    // Only render gap style if there's meaningful space (20px or more)
                    if width >= 20 {
                        switch trackState.gapStyle {
                        case .none:
                            Spacer()
                                .frame(maxWidth: .infinity)
                            
                        case .dots:
                            HStack(spacing: 4) {
                                ForEach(0..<Int(width / 8), id: \.self) { _ in
                                    Text("·")
                                        .font(.system(size: 8))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            
                        case .fade:
                            let opacity = min(0.4, (width - 20) / 100 * 0.4)
                            LinearGradient(
                                colors: [.clear, .white.opacity(opacity)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(height: 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            
                        case .wave:
                            WavePath(width: width)
                                .stroke(Color.white, lineWidth: 0.75)
                                .mask(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.1), Color.white],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                    }
                }
            }
        }
        .frame(width: width)
    }
    
    struct WavePath: Shape {
        let width: CGFloat
        
        func path(in rect: CGRect) -> Path {
            var path = Path()
            
            let amplitude: CGFloat = 3
            let wavelength: CGFloat = 20
            let midY = rect.midY
            
            path.move(to: CGPoint(x: 0, y: midY))
            
            for x in stride(from: 0, through: width, by: 1) {
                let relativeX = x / wavelength
                let y = midY + sin(relativeX * 2 * .pi) * amplitude
                path.addLine(to: CGPoint(x: x, y: y))
            }
            
            return path
        }
    }
}
