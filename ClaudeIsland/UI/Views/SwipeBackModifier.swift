//
//  SwipeBackModifier.swift
//  ClaudeIsland
//
//  Two-finger trackpad horizontal swipe to trigger a navigation action.
//

import AppKit
import SwiftUI

enum SwipeDirection {
    case left
    case right
}

struct SwipeBackModifier: ViewModifier {
    let direction: SwipeDirection
    let action: () -> Void

    @State private var monitor: Any?
    @State private var accumX: CGFloat = 0
    @State private var accumY: CGFloat = 0
    @State private var triggered: Bool = false

    private let threshold: CGFloat = 50

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    handle(event)
                    return event
                }
            }
            .onDisappear {
                if let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
                reset()
            }
    }

    private func handle(_ event: NSEvent) {
        switch event.phase {
        case .began:
            reset()
        case .changed:
            accumX += event.scrollingDeltaX
            accumY += event.scrollingDeltaY
            let didReachThreshold: Bool
            switch direction {
            case .left:
                didReachThreshold = accumX < -threshold
            case .right:
                didReachThreshold = accumX > threshold
            }

            if !triggered,
               didReachThreshold,
               abs(accumX) > abs(accumY) * 1.5 {
                triggered = true
                action()
            }
        case .ended, .cancelled:
            reset()
        default:
            break
        }
    }

    private func reset() {
        accumX = 0
        accumY = 0
        triggered = false
    }
}

extension View {
    func swipeBack(action: @escaping () -> Void) -> some View {
        modifier(SwipeBackModifier(direction: .right, action: action))
    }

    func swipeForward(action: @escaping () -> Void) -> some View {
        modifier(SwipeBackModifier(direction: .left, action: action))
    }
}
