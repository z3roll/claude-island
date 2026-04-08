//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @StateObject private var companionService = CompanionService.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var previousQuestionIds: Set<String> = []
    @State private var previousEndedIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var isWiggling: Bool = false
    @State private var wiggleAngle: Double = 0
    @State private var notificationSuppressedUntil: [String: Date] = [:]  // per-session suppression

    @Namespace private var activityNamespace

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session has a pending question (AskUserQuestion)
    private var hasPendingQuestion: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForAnswer }
    }

    /// Whether any waiting-for-input session was interrupted (ESC) rather than completing normally
    private var hasInterruptedSession: Bool {
        sessionMonitor.instances.contains { $0.phase == .waitingForInput && $0.wasInterrupted }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 3  // Show checkmark/X for 3 seconds

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height + (viewModel.hasPhysicalNotch ? 0.5 : 0)
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        let indicatorWidth: CGFloat = (hasPendingPermission || hasPendingQuestion) ? 18 : 0
        let baseWidth = 1.5 * max(0, closedNotchSize.height - 12)

        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                return baseWidth + indicatorWidth
            case .none:
                break
            }
        }

        if hasPendingPermission || hasPendingQuestion {
            return baseWidth + indicatorWidth
        }

        if hasWaitingForInput {
            return baseWidth
        }

        // Always-show notch without session activity: same width as processing
        if AppSettings.alwaysShowNotch {
            return baseWidth
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        width: viewModel.status == .opened ? notchSize.width : nil,
                        height: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasPendingQuestion)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .background(panelFrameTracker)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                        // Trigger crab wiggle on hover enter when closed
                        if hovering && viewModel.status != .opened && showClosedActivity {
                            triggerWiggle()
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
            updateClosedActivityWidth()
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
            handleQuestionChange(instances)
            handleSessionEndedChange(instances)
            updateClosedActivityWidth()
        }
        .onChange(of: activityCoordinator.expandingActivity) { _, _ in
            updateClosedActivityWidth()
        }
    }

    private var panelFrameTracker: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    updatePanelFrame(geo)
                }
                .onChange(of: viewModel.status) { _, _ in
                    updatePanelFrame(geo)
                }
                .onChange(of: viewModel.contentType) { _, _ in
                    schedulePanelFrameUpdate(geo)
                }
                .onChange(of: screenSelector.isPickerExpanded) { _, _ in
                    schedulePanelFrameUpdate(geo)
                }
                .onChange(of: soundSelector.expandedEventType) { _, _ in
                    schedulePanelFrameUpdate(geo)
                }
                .onChange(of: soundSelector.customSounds.count) { _, _ in
                    schedulePanelFrameUpdate(geo)
                }
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission/question, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasPendingQuestion || hasWaitingForInput || AppSettings.alwaysShowNotch
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .scale(scale: 0.3, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.easeIn(duration: 0.2))
                        )
                    )

                if showsPageIndicator {
                    pageIndicator
                        .frame(width: notchSize.width - 24)
                        .padding(.bottom, 2)
                        .transition(.opacity.animation(.smooth(duration: 0.2)))
                }
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab + optional permission indicator (visible when processing, pending, or waiting for input)
            if showClosedActivity {
                HStack(spacing: 4) {
                    ClaudeCrabIcon(
                        size: 14,
                        animateLegs: isProcessing,
                        pacing: viewModel.status != .opened
                            && !isProcessing
                            && !hasPendingPermission
                            && !hasPendingQuestion
                            && !hasWaitingForInput,
                        maxPacingOffset: sideWidth + closedNotchSize.width
                    )
                        .rotationEffect(.degrees(viewModel.status != .opened ? wiggleAngle : 0))
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)

                    // Permission/question indicator (amber) - waiting for input shows checkmark on right
                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    } else if hasPendingQuestion {
                        // Question mark indicator for pending questions
                        Text("?")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(TerminalColors.amber)
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
                .frame(width: viewModel.status == .opened ? nil : sideWidth + ((hasPendingPermission || hasPendingQuestion) ? 18 : 0))
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: black spacer (with optional bounce)
                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
            }

            // Right side - spinner when processing/pending, question mark for questions, checkmark when waiting for input
            if showClosedActivity && viewModel.status != .opened {
                if isProcessing || hasPendingPermission {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: sideWidth)
                } else if hasPendingQuestion {
                    Text("?")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(TerminalColors.amber)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: sideWidth)
                } else if hasWaitingForInput {
                    if hasInterruptedSession {
                        InterruptedIndicatorIcon(size: 14)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                            .frame(width: sideWidth)
                    } else {
                        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                            .frame(width: sideWidth)
                    }
                } else {
                    // Invisible spacer to keep the same width as working state
                    Color.clear
                        .frame(width: sideWidth)
                }
            }

        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 2
    }

    private var showsPageIndicator: Bool {
        viewModel.contentType == .instances || viewModel.contentType == .menu
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 8) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                ClaudeCrabIcon(size: 14)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                    .padding(.leading, 8)
            }

            // Token usage display (left side, after crab)
            TokenUsageBadge()
                .padding(.leading, showClosedActivity ? 8 : 0)

            Spacer()
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.contentType {
        case .instances:
            ClaudeInstancesView(
                sessionMonitor: sessionMonitor,
                viewModel: viewModel
            )
        case .menu:
            NotchMenuView(viewModel: viewModel)
        case .chat(let sessionId):
            if let session = sessionMonitor.instances.first(where: { $0.sessionId == sessionId }) {
                ChatView(
                    sessionId: sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            } else {
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        case .question(let sessionId):
            if let session = sessionMonitor.instances.first(where: { $0.sessionId == sessionId }),
               let ctx = session.activeQuestion {
                QuestionView(
                    question: ctx,
                    onAnswer: { answers in
                        sessionMonitor.answerQuestion(
                            sessionId: sessionId,
                            answers: answers
                        )
                        viewModel.exitChat()
                    }
                )
            } else {
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 2) {
            pageIndicatorDot(
                isActive: viewModel.contentType == .instances,
                action: { viewModel.showInstances() }
            )
            pageIndicatorDot(
                isActive: viewModel.contentType == .menu,
                action: {
                    viewModel.showMenu()
                    updateManager.markUpdateSeen()
                }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .contentShape(Rectangle())
        .zIndex(20)
    }

    private func pageIndicatorDot(isActive: Bool, action: @escaping () -> Void) -> some View {
        PageIndicatorDot(isActive: isActive, action: action)
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission || hasPendingQuestion {
            // Show claude activity when processing, waiting for permission, or waiting for answer
            activityCoordinator.showActivity(type: .claude)
            isVisible = true

            // Per-session suppression: when a session enters processing, set a
            // 2s window for THAT session only. This prevents false notifications
            // during context resume / session restoration, without affecting
            // other sessions' completion notifications.
            let suppressionDuration: TimeInterval = 2.0
            let now = Date()
            for session in sessionMonitor.instances where session.phase == .processing || session.phase == .compacting {
                let id = session.stableId
                if notificationSuppressedUntil[id] == nil || notificationSuppressedUntil[id]! < now {
                    notificationSuppressedUntil[id] = now.addingTimeInterval(suppressionDuration)
                }
            }
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Keep visible if alwaysShowNotch is enabled
            if AppSettings.alwaysShowNotch {
                isVisible = true
                return
            }

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed && viewModel.hasPhysicalNotch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasPendingQuestion && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func updatePanelFrame(_ geo: GeometryProxy) {
        // geo.frame(in: .global) is in WINDOW coordinates (origin at window
        // top-left, Y down). We need to convert to macOS global screen
        // coordinates (origin at bottom-left of primary screen, Y up) so
        // hover detection with NSEvent.mouseLocation works on any screen.
        let localFrame = geo.frame(in: .global)
        let sr = viewModel.screenRect
        let wh = viewModel.windowHeight
        // Window is full-width, pinned to the top of the target screen.
        let windowOriginX = sr.origin.x
        let windowOriginY = sr.maxY - wh
        let screenFrame = CGRect(
            x: windowOriginX + localFrame.origin.x,
            y: windowOriginY + (wh - localFrame.origin.y - localFrame.height),
            width: localFrame.width,
            height: localFrame.height
        )
        viewModel.panelScreenFrame = screenFrame
    }

    private func schedulePanelFrameUpdate(_ geo: GeometryProxy) {
        DispatchQueue.main.async {
            updatePanelFrame(geo)
        }
    }

    /// Trigger a short wiggle/shake animation on the crab icon
    private func triggerWiggle() {
        guard !isWiggling else { return }
        isWiggling = true
        // Sequence: 0 -> -5 -> 5 -> -3 -> 3 -> 0
        let steps: [(Double, Double)] = [(-5, 0.06), (5, 0.06), (-3, 0.05), (3, 0.05), (0, 0.05)]
        var delay: Double = 0
        for (angle, duration) in steps {
            delay += duration
            let capturedDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + capturedDelay) {
                withAnimation(.easeInOut(duration: duration)) {
                    wiggleAngle = angle
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.1) {
            isWiggling = false
        }
    }

    /// Keep the ViewModel's closedActivityWidth in sync so hover hit-testing covers the expanded area
    private func updateClosedActivityWidth() {
        viewModel.closedActivityWidth = showClosedActivity ? closedContentWidth : 0
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasPendingQuestion && !hasWaitingForInput && !activityCoordinator.expandingActivity.show && !AppSettings.alwaysShowNotch {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty {
            // Play permission request sound (with per-session suppression + focus check)
            let now = Date()
            let unsuppressedIds = newPendingIds.filter { id in
                guard let until = notificationSuppressedUntil[id] else { return true }
                return now >= until
            }
            if !unsuppressedIds.isEmpty && soundSelector.hasSound(for: .permissionRequest) {
                let newSessions = sessions.filter { unsuppressedIds.contains($0.stableId) }
                Task {
                    let shouldPlay = await shouldPlayNotificationSound(for: newSessions)
                    if shouldPlay {
                        await MainActor.run {
                            soundSelector.playSound(for: .permissionRequest)
                        }
                    }
                }
            }

            if viewModel.status == .closed &&
               !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
                viewModel.notchOpen(reason: .notification)
            }
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Filter out sessions that still have active subagents — their waitingForInput
        // is a transient state caused by SubagentStop, not a real "done" signal.
        // Also filter sessions during notification suppression window (context resume).
        let genuinelyWaitingSessions: [SessionState]
        if !newWaitingIds.isEmpty {
            genuinelyWaitingSessions = waitingForInputSessions.filter { session in
                guard newWaitingIds.contains(session.stableId) else { return false }
                // Subagent stop causes a brief waitingForInput — ignore it
                if session.subagentState.hasActiveSubagent { return false }
                return true
            }
        } else {
            genuinelyWaitingSessions = []
        }

        // Bounce the notch when a session genuinely enters waitingForInput state
        if !genuinelyWaitingSessions.isEmpty {
            // Filter out sessions still in their per-session suppression window
            let unsuppressedSessions = genuinelyWaitingSessions.filter { session in
                guard let suppressedUntil = notificationSuppressedUntil[session.stableId] else {
                    return true  // no suppression for this session
                }
                return now >= suppressedUntil
            }
            // Clean up expired suppression entries
            for session in genuinelyWaitingSessions {
                notificationSuppressedUntil.removeValue(forKey: session.stableId)
            }

            if !unsuppressedSessions.isEmpty {
                // Play task complete notification sound
                if soundSelector.hasSound(for: .taskComplete) {
                    Task {
                        let shouldPlaySound = await shouldPlayNotificationSound(for: unsuppressedSessions)
                        if shouldPlaySound {
                            await MainActor.run {
                                soundSelector.playSound(for: .taskComplete)
                            }
                        }
                    }
                }

                // Trigger bounce animation to get user's attention
                DispatchQueue.main.async {
                    isBouncing = true
                    // Bounce back after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isBouncing = false
                    }
                }
            }

            // Schedule hiding the indicator after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }

    /// Handle sessions entering question-waiting state (AskUserQuestion)
    private func handleQuestionChange(_ instances: [SessionState]) {
        let questionSessions = instances.filter { $0.phase.isWaitingForAnswer }
        let currentIds = Set(questionSessions.map { $0.stableId })
        let newQuestionIds = currentIds.subtracting(previousQuestionIds)

        if !newQuestionIds.isEmpty {
            let now = Date()
            // Filter out sessions with active subagents or in suppression window
            let genuineSessions = questionSessions.filter { session in
                guard newQuestionIds.contains(session.stableId) else { return false }
                if session.subagentState.hasActiveSubagent { return false }
                if let until = notificationSuppressedUntil[session.stableId], now < until { return false }
                return true
            }

            if !genuineSessions.isEmpty && soundSelector.hasSound(for: .questionWaiting) {
                Task {
                    let shouldPlay = await shouldPlayNotificationSound(for: genuineSessions)
                    if shouldPlay {
                        await MainActor.run {
                            soundSelector.playSound(for: .questionWaiting)
                        }
                    }
                }
            }
        }

        previousQuestionIds = currentIds
    }

    /// Handle sessions entering ended state
    private func handleSessionEndedChange(_ instances: [SessionState]) {
        let endedSessions = instances.filter { $0.phase == .ended }
        let currentIds = Set(endedSessions.map { $0.stableId })
        let newEndedIds = currentIds.subtracting(previousEndedIds)

        if !newEndedIds.isEmpty {
            let now = Date()
            let newSessions = endedSessions.filter { session in
                guard newEndedIds.contains(session.stableId) else { return false }
                if let until = notificationSuppressedUntil[session.stableId], now < until { return false }
                return true
            }

            if !newSessions.isEmpty && soundSelector.hasSound(for: .sessionEnded) {
                Task {
                    let shouldPlay = await shouldPlayNotificationSound(for: newSessions)
                    if shouldPlay {
                        await MainActor.run {
                            soundSelector.playSound(for: .sessionEnded)
                        }
                    }
                }
            }
        }

        previousEndedIds = currentIds
    }
}

private struct PageIndicatorDot: View {
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    private let hitWidth: CGFloat = 16
    private let hitHeight: CGFloat = 20

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0))
                    .frame(width: hitWidth, height: hitHeight)

                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(isHovered ? 1.12 : 1)
            }
            .frame(width: hitWidth, height: hitHeight)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isActive)
            .animation(.spring(response: 0.18, dampingFraction: 0.8), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var dotColor: Color {
        if isActive {
            return Color.white.opacity(isHovered ? 1 : 0.92)
        }
        return Color.white.opacity(isHovered ? 0.36 : 0.2)
    }

    private var dotSize: CGFloat {
        if isActive {
            return isHovered ? 8 : 7
        }
        return isHovered ? 7 : 6
    }
}
