//
//  CompanionSpriteView.swift
//  ClaudeIsland
//
//  ASCII art companion pet rendered as monospaced text.
//

import SwiftUI

struct CompanionSpriteView: View {
    @ObservedObject var companion: CompanionService
    var fontSize: CGFloat = 7.0

    @State private var shimmerPhase: Double = 0.0

    var body: some View {
        if companion.isLoaded {
            VStack(spacing: 0) {
                ForEach(Array(companion.currentFrameLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(companion.rarity.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .opacity(companion.shiny ? shimmerOpacity : 1.0)
            .onAppear {
                if companion.shiny {
                    withAnimation(
                        .easeInOut(duration: 1.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        shimmerPhase = 1.0
                    }
                }
            }
        }
    }

    private var shimmerOpacity: Double {
        0.75 + 0.25 * shimmerPhase
    }
}
