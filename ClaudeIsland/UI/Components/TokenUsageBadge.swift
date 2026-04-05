//
//  TokenUsageBadge.swift
//  ClaudeIsland
//
//  Compact token usage display for the notch header.
//  Format: "5h 23% 2h31m  7d 4% 6d2h"
//

import SwiftUI

struct TokenUsageBadge: View {
    @ObservedObject private var tokenService = TokenUsageService.shared

    var body: some View {
        if tokenService.usage5h != .zero || tokenService.usage7d != .zero {
            HStack(spacing: 5) {
                if tokenService.usage5h != .zero {
                    windowPill(label: "5h", usage: tokenService.usage5h)
                }
                if tokenService.usage7d != .zero {
                    windowPill(label: "7d", usage: tokenService.usage7d)
                }
            }
        }
    }

    private func windowPill(label: String, usage: TokenWindowUsage) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))

            Text(String(format: "%.0f%%", usage.percentage))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(percentageColor(usage.percentage))

            if !usage.recoveryText.isEmpty {
                Text(usage.recoveryText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func percentageColor(_ pct: Double) -> Color {
        if pct >= 90 {
            return Color(red: 0.95, green: 0.3, blue: 0.3)   // Red
        } else if pct >= 70 {
            return Color(red: 0.95, green: 0.55, blue: 0.25)  // Orange
        } else if pct >= 50 {
            return Color(red: 0.95, green: 0.8, blue: 0.3)    // Yellow
        }
        return Color(red: 0.4, green: 0.85, blue: 0.45)       // Green
    }
}
