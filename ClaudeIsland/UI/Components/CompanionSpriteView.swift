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
            .overlay(alignment: .topLeading) {
                effectBadge
                    .offset(x: -fontSize * effectOffsetMultiplier, y: 0)
            }
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

    @ViewBuilder
    private var effectBadge: some View {
        let text = companion.effect.display(phase: companion.effectPhase)
        if !text.isEmpty {
            Text(text)
                .font(.system(size: fontSize * effectSizeMultiplier, weight: .medium, design: .monospaced))
                .kerning(-1)
                .foregroundColor(companion.rarity.color)
                .fixedSize(horizontal: true, vertical: true)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                .id(companion.effect) // re-transition when effect changes
                .animation(.easeOut(duration: 0.15), value: companion.effectPhase)
        }
    }

    private var effectSizeMultiplier: CGFloat {
        switch companion.effect {
        case .thinking: return 0.8
        default: return 1.1
        }
    }

    private var effectOffsetMultiplier: CGFloat {
        switch companion.effect {
        case .thinking: return 0.8
        default: return 1.2
        }
    }

    private var shimmerOpacity: Double {
        0.75 + 0.25 * shimmerPhase
    }
}
