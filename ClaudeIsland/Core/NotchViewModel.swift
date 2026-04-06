//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(String)      // sessionId only
    case question(String)  // sessionId only

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let sessionId): return "chat-\(sessionId)"
        case .question(let sessionId): return "question-\(sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    private enum OpenedPageLayout {
        static let pageIndicatorHeight: CGFloat = 18
        static let pageIndicatorSpacing: CGFloat = 8
    }

    private enum HoverBehavior {
        static let closeDelay: TimeInterval = 0.18
        static let clickOpenCloseDelay: TimeInterval = 0.6
        static let openedHitPaddingX: CGFloat = 10
        static let openedHitPaddingY: CGFloat = 10
        static let menuHitPaddingY: CGFloat = 40
        static let menuShrinkDelay: TimeInterval = 0.18
        static let contentSwitchCloseGrace: TimeInterval = 0.35
    }

    private enum MenuLayout {
        static let fallbackHeight: CGFloat = 600
        static let chromeHeight: CGFloat = 52
    }

    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published private(set) var measuredMenuContentHeight: CGFloat = 0
    @Published private(set) var measuredInstancesContentHeight: CGFloat = 0

    /// The current total width of the closed notch (set by NotchView when showing activity)
    @Published var closedActivityWidth: CGFloat = 0

    /// Actual rendered panel frame in screen coordinates (set by GeometryReader in NotchView)
    var panelScreenFrame: CGRect = .zero

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    private var panelWidth: CGFloat {
        min(screenRect.width * 0.53, 680)
    }

    var openedSize: CGSize {
        switch contentType {
        case .chat:
            return CGSize(width: panelWidth, height: 580)
        case .question:
            return CGSize(width: panelWidth, height: 380)
        case .menu:
            return CGSize(width: panelWidth, height: menuHeight)
        case .instances:
            return CGSize(width: panelWidth, height: instancesHeight)
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?
    private var menuHeightWorkItem: DispatchWorkItem?
    private var hoverCloseSuppressedUntil: Date = .distantPast
    private var ignoresVerticalHoverBoundsUntilNextClick = false

    private var menuHeight: CGFloat {
        let maxHeight: CGFloat = windowHeight - 20
        let chromeHeight = max(24, deviceNotchRect.height) + 12
        let baseHeight = MenuLayout.fallbackHeight + screenSelector.expandedPickerHeight + soundSelector.expandedPickerHeight
        let measuredHeight = measuredMenuContentHeight + chromeHeight + pageIndicatorChromeHeight
        let targetHeight = max(baseHeight, measuredHeight)
        return min(maxHeight, targetHeight)
    }

    private var instancesHeight: CGFloat {
        let minHeight: CGFloat = 120
        let maxHeight: CGFloat = 360
        let chromeHeight = max(24, deviceNotchRect.height) + 12
        guard measuredInstancesContentHeight > 0 else { return maxHeight }
        return min(maxHeight, max(minHeight, measuredInstancesContentHeight + chromeHeight + pageIndicatorChromeHeight))
    }

    var openedHoverHitPaddingY: CGFloat {
        contentType == .menu ? HoverBehavior.menuHitPaddingY : HoverBehavior.openedHitPaddingY
    }

    private var pageIndicatorChromeHeight: CGFloat {
        OpenedPageLayout.pageIndicatorHeight + OpenedPageLayout.pageIndicatorSpacing
    }

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$expandedEventType
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$customSounds
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat or question mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        if case .question = contentType { return true }
        return false
    }

    /// The chat session ID we're viewing (persists across close/open)
    private var currentChatSessionId: String?

    private func handleMouseMove(_ location: CGPoint) {
        // When closed notch is expanded (activity visible), use the wider hit area
        let inNotch: Bool
        if closedActivityWidth > 0 && status != .opened {
            inNotch = geometry.isPointInClosedActivity(location, closedWidth: closedActivityWidth)
        } else {
            inNotch = geometry.isPointInNotch(location)
        }
        // Use the actual rendered panel frame for hit testing
        let inOpened: Bool
        if status == .opened && panelScreenFrame != .zero {
            let expandedFrame = panelScreenFrame.insetBy(
                dx: -HoverBehavior.openedHitPaddingX,
                dy: -openedHoverHitPaddingY
            )
            if ignoresVerticalHoverBoundsUntilNextClick {
                // If cursor has entered the real panel bounds, drop the grace and
                // resume normal hover gating from now on.
                if expandedFrame.contains(location) {
                    ignoresVerticalHoverBoundsUntilNextClick = false
                    inOpened = true
                } else {
                    let horizontalFrame = CGRect(
                        x: expandedFrame.minX,
                        y: screenRect.minY - windowHeight,
                        width: expandedFrame.width,
                        height: windowHeight * 3
                    )
                    inOpened = horizontalFrame.contains(location)
                }
            } else {
                inOpened = expandedFrame.contains(location)
            }
        } else {
            inOpened = false
        }

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        if isHovering {
            // Auto-expand immediately on hover
            if status == .closed || status == .popping {
                notchOpen(reason: .hover)
            }
        } else {
            // Auto-close when mouse leaves.
            // For hover-opened: short delay (avoids flicker from hit-test gaps).
            // For click/notification/unknown: longer delay as safety net — if the
            // user moves the mouse away without clicking outside, the panel should
            // still eventually close rather than freeze the screen.
            if status == .opened {
                guard Date() >= hoverCloseSuppressedUntil else { return }
                let delay = openReason == .hover
                    ? HoverBehavior.closeDelay
                    : HoverBehavior.clickOpenCloseDelay
                let closeWorkItem = DispatchWorkItem { [weak self] in
                    guard let self, !self.isHovering, self.status == .opened else { return }
                    self.notchClose()
                }
                hoverTimer = closeWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: closeWorkItem)
            }
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            // Global monitor only fires for clicks OUTSIDE our app. Any such click
            // while the panel is open should close the panel.
            notchClose()
        case .closed, .popping:
            let inNotchArea: Bool
            if closedActivityWidth > 0 {
                inNotchArea = geometry.isPointInClosedActivity(location, closedWidth: closedActivityWidth)
            } else {
                inNotchArea = geometry.isPointInNotch(location)
            }
            if inNotchArea {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSessionId = nil
            return
        }

        // Restore chat session if we had one open before
        if let sessionId = currentChatSessionId {
            if case .chat(let id) = contentType, id == sessionId {
                return
            }
            contentType = .chat(sessionId)
        }
    }

    func updateMeasuredMenuContentHeight(_ height: CGFloat) {
        let clampedHeight = max(0, ceil(height))
        guard clampedHeight > 0 else { return }

        menuHeightWorkItem?.cancel()
        menuHeightWorkItem = nil

        if clampedHeight >= measuredMenuContentHeight {
            measuredMenuContentHeight = clampedHeight
            return
        }

        let shrinkWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.measuredMenuContentHeight = clampedHeight
        }
        menuHeightWorkItem = shrinkWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + HoverBehavior.menuShrinkDelay,
            execute: shrinkWorkItem
        )
    }

    func updateMeasuredInstancesContentHeight(_ height: CGFloat) {
        let clampedHeight = max(0, ceil(height))
        guard clampedHeight > 0 else { return }
        measuredInstancesContentHeight = clampedHeight
    }


    func notchClose() {
        // Save chat session ID before closing if in chat mode
        if case .chat(let sessionId) = contentType {
            currentChatSessionId = sessionId
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        if contentType == .menu {
            showInstances()
        } else {
            suppressHoverCloseAfterContentSwitch()
            contentType = .menu
        }
    }

    func showMenu() {
        suppressHoverCloseAfterContentSwitch()
        contentType = .menu
    }

    func showInstances() {
        // Any transition *into* .instances from another page can shrink the
        // panel out from under the cursor. Disable vertical hover bounds
        // until the cursor next enters the new (smaller) panel.
        if contentType != .instances {
            ignoresVerticalHoverBoundsUntilNextClick = true
        }
        suppressHoverCloseAfterContentSwitch()
        contentType = .instances
    }

    func showChat(for session: SessionState) {
        if case .chat(let id) = contentType, id == session.sessionId {
            return
        }
        currentChatSessionId = session.sessionId
        contentType = .chat(session.sessionId)
    }

    /// Show question panel for a session
    func showQuestion(for session: SessionState) {
        if case .question(let id) = contentType, id == session.sessionId {
            return
        }
        contentType = .question(session.sessionId)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSessionId = nil
        showInstances()
    }

    private func suppressHoverCloseAfterContentSwitch() {
        hoverTimer?.cancel()
        hoverTimer = nil
        hoverCloseSuppressedUntil = Date().addingTimeInterval(HoverBehavior.contentSwitchCloseGrace)
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
