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
    private let soundSelector = SoundSelector.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var previousQuestionIds: Set<String> = []
    @State private var previousEndedIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var notificationSuppressedUntil: Date = Date()  // Suppress notifications during context resume

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

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

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
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission/question indicator adds width on left side only
        let indicatorWidth: CGFloat = (hasPendingPermission || hasPendingQuestion) ? 18 : 0

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
                return baseWidth + indicatorWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions/questions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission || hasPendingQuestion {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + indicatorWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return 2 * max(0, closedNotchSize.height - 12) + 20
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
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
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
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                updatePanelFrame(geo)
                            }
                            .onChange(of: viewModel.status) { _, _ in
                                updatePanelFrame(geo)
                            }
                            .onChange(of: viewModel.contentType) { _, _ in
                                updatePanelFrame(geo)
                            }
                        }
                    )
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
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
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
            handleQuestionChange(instances)
            handleSessionEndedChange(instances)
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission/question, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasPendingQuestion || hasWaitingForInput
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
                    ClaudeCrabIcon(size: 14, animateLegs: isProcessing)
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
            if showClosedActivity {
                if isProcessing || hasPendingPermission {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else if hasPendingQuestion {
                    // Pulsing question mark for pending questions
                    Text("?")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(TerminalColors.amber)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else if hasWaitingForInput {
                    // Checkmark for waiting-for-input on the right side
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                }
            }

        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
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

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .question(let session):
                if let ctx = session.activeQuestion {
                    QuestionView(
                        question: ctx,
                        onAnswer: { answers in
                            sessionMonitor.answerQuestion(
                                sessionId: session.sessionId,
                                answers: answers
                            )
                            // Return to instances list after answering
                            viewModel.exitChat()
                        }
                    )
                } else {
                    // Question was answered externally, show instances
                    ClaudeInstancesView(
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                }
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission || hasPendingQuestion {
            // Show claude activity when processing, waiting for permission, or waiting for answer
            activityCoordinator.showActivity(type: .claude)
            isVisible = true

            // When a session starts processing, set a suppression window.
            // This prevents sound/bounce from firing if the session quickly
            // transitions through processing → waitingForInput during context
            // resume or session restoration.
            let suppressionDuration: TimeInterval = 2.0
            let newSuppressedUntil = Date().addingTimeInterval(suppressionDuration)
            if newSuppressedUntil > notificationSuppressedUntil {
                notificationSuppressedUntil = newSuppressedUntil
            }
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

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
        // Convert the panel's local frame to screen coordinates
        let localFrame = geo.frame(in: .global)
        guard let screen = NSScreen.main else { return }
        let screenHeight = screen.frame.height
        // SwiftUI global coordinates have Y=0 at top, NSScreen has Y=0 at bottom
        let screenFrame = CGRect(
            x: localFrame.origin.x,
            y: screenHeight - localFrame.origin.y - localFrame.height,
            width: localFrame.width,
            height: localFrame.height
        )
        viewModel.panelScreenFrame = screenFrame
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
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasPendingQuestion && !hasWaitingForInput && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty {
            // Play permission request sound (with suppression + focus check)
            let isSuppressed = Date() < notificationSuppressedUntil
            if !isSuppressed && soundSelector.hasSound(for: .permissionRequest) {
                let newSessions = sessions.filter { newPendingIds.contains($0.stableId) }
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
            // Suppress notifications during context resume window
            let isSuppressed = now < notificationSuppressedUntil

            if !isSuppressed {
                // Play task complete notification sound
                if soundSelector.hasSound(for: .taskComplete) {
                    Task {
                        let shouldPlaySound = await shouldPlayNotificationSound(for: genuinelyWaitingSessions)
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

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
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
            let isSuppressed = Date() < notificationSuppressedUntil
            // Filter out sessions with active subagents
            let genuineSessions = questionSessions.filter { session in
                guard newQuestionIds.contains(session.stableId) else { return false }
                return !session.subagentState.hasActiveSubagent
            }

            if !isSuppressed && !genuineSessions.isEmpty && soundSelector.hasSound(for: .questionWaiting) {
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
            let isSuppressed = Date() < notificationSuppressedUntil
            let newSessions = endedSessions.filter { newEndedIds.contains($0.stableId) }

            if !isSuppressed && !newSessions.isEmpty && soundSelector.hasSound(for: .sessionEnded) {
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
