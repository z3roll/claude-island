//
//  NotchHeaderView.swift
//  ClaudeIsland
//
//  Header bar for the dynamic island
//

import Combine
import SwiftUI

struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false
    var pacing: Bool = false
    var maxPacingOffset: CGFloat = 30

    @State private var legPhase: Int = 0
    @State private var pacingOffset: CGFloat = 0

    // Timer for leg animation
    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(
        size: CGFloat = 16,
        color: Color = Color(red: 0.85, green: 0.47, blue: 0.34),
        animateLegs: Bool = false,
        pacing: Bool = false,
        maxPacingOffset: CGFloat = 30
    ) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
        self.pacing = pacing
        self.maxPacingOffset = maxPacingOffset
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0  // Original viewBox height is 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            // Left antenna
            let leftAntenna = Path { p in
                p.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            // Right antenna
            let rightAntenna = Path { p in
                p.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            // Animated legs - alternating up/down pattern for walking effect
            // Legs stay attached to body (y=39), only height changes
            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13

            // Height offsets: positive = longer leg (down), negative = shorter leg (up)
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],   // Phase 0: alternating
                [0, 0, 0, 0],     // Phase 1: neutral
                [-3, 3, -3, 3],   // Phase 2: alternating (opposite)
                [0, 0, 0, 0],     // Phase 3: neutral
            ]

            let shouldAnimateLegs = animateLegs || pacing
            let currentHeightOffsets = shouldAnimateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { p in
                    p.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            // Main body
            let body = Path { p in
                p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            // Left eye
            let leftEye = Path { p in
                p.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            // Right eye
            let rightEye = Path { p in
                p.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .offset(x: pacing ? pacingOffset : 0)
        .onReceive(legTimer) { _ in
            if animateLegs || pacing {
                legPhase = (legPhase + 1) % 4
            }
        }
        .onAppear {
            if pacing { stepPacing() }
        }
        .onChange(of: pacing) { _, newValue in
            if newValue {
                stepPacing()
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pacingOffset = 0 }
            }
        }
    }

    private func stepPacing() {
        guard pacing else { return }
        let target: CGFloat = pacingOffset >= 0 ? -5 : 5
        withAnimation(.easeInOut(duration: 1.2)) {
            pacingOffset = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            stepPacing()
        }
    }
}

// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // Visible pixel positions from the SVG (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11),           // Left column
        (11, 3),                    // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15),          // Right of center
        (23, 7), (23, 11)           // Right column
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art "interrupted" indicator icon (X/cross shape)
struct InterruptedIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = Color(red: 0.95, green: 0.3, blue: 0.3)) {
        self.size = size
        self.color = color
    }

    // X shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        // Top-left to bottom-right diagonal
        (5, 5), (9, 9), (13, 13), (17, 17), (21, 21), (25, 25),
        // Top-right to bottom-left diagonal
        (25, 5), (21, 9), (17, 13), (13, 17), (9, 21), (5, 25),
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

