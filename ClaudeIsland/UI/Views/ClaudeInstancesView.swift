//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @Binding var scrollFraction: CGFloat

    private let rowHeightEstimate: CGFloat = 58
    private let rowSpacing: CGFloat = 2
    private let listVerticalPadding: CGFloat = 8

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
                .onAppear(perform: updateEstimatedHeight)
                .onChange(of: sessionMonitor.instances) { _, _ in
                    updateEstimatedHeight()
                }
                .swipeForward {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        viewModel.showMenu()
                    }
                }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Sort by session start time (oldest first, newest at bottom).
    /// Sessions awaiting user permission are floated to the top until they
    /// are approved/denied.
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let aNeedsAction = a.activePermission != nil
            let bNeedsAction = b.activePermission != nil
            if aNeedsAction != bNeedsAction {
                return aNeedsAction && !bNeedsAction
            }
            return a.createdAt < b.createdAt
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(sortedInstances) { session in
            InstanceRow(
                session: session,
                onFocus: { focusSession(session) },
                onChat: { openChat(session) },
                onArchive: { archiveSession(session) },
                onApprove: { approveSession(session) },
                onReject: { rejectSession(session) },
                onAnswer: { answers in answerQuestion(session, answers: answers) },
                onOpenQuestion: { openQuestion(session) },
                onKillTmux: { killTmuxSession(session) }
            )
            .id(session.stableId)
        }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            contentRows
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            let maxOffset = geo.contentSize.height - geo.containerSize.height
            guard maxOffset > 0 else { return 1 }
            return min(1, max(0, geo.contentOffset.y / maxOffset))
        } action: { _, newValue in
            scrollFraction = newValue
        }
    }

    private var contentRows: some View {
        VStack(spacing: 2) {
            rows
        }
        .padding(.vertical, 4)
    }

    private func updateEstimatedHeight() {
        let count = CGFloat(sortedInstances.count)
        let estimatedHeight = count * rowHeightEstimate
            + max(0, count - 1) * rowSpacing
            + listVerticalPadding
        viewModel.updateMeasuredInstancesContentHeight(estimatedHeight)
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        // Close the notch panel and resign key window so terminal gets focus
        viewModel.notchClose()
        NSApp.keyWindow?.resignKey()

        Task {
            // For tmux sessions, switch to the correct pane first
            if session.isInTmux, let pid = session.pid {
                if let target = await TmuxTargetFinder.shared.findTarget(forClaudePid: pid) {
                    _ = await TmuxController.shared.switchToPane(target: target)
                }
            }

            if let terminal = session.resolvedTerminal {
                _ = await WindowFocuser.shared.focusTerminal(
                    info: terminal.appInfo,
                    sessionPid: session.pid,
                    cachedTTY: terminal.tty
                )
            } else {
                _ = await WindowFocuser.shared.focusTerminalApp(bundleId: "com.apple.Terminal")
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
        // Mark as read: transition waitingForInput → idle
        if session.phase == .waitingForInput {
            Task {
                await SessionStore.shared.markAsRead(sessionId: session.sessionId)
            }
        }
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }

    private func killTmuxSession(_ session: SessionState) {
        guard let pid = session.pid else { return }
        Task {
            // Kill only the pane, not the entire tmux session
            _ = await TmuxSessionManager.shared.killPane(forClaudePid: pid)
            // Session file cleanup is handled by Claude Code itself.
            // Once the process dies, SessionStore will receive a "ended" hook
            // and remove it from the UI automatically.
        }
    }

    private func answerQuestion(_ session: SessionState, answers: [String: String]) {
        sessionMonitor.answerQuestion(sessionId: session.sessionId, answers: answers)
    }

    private func openQuestion(_ session: SessionState) {
        viewModel.showQuestion(for: session)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let onAnswer: ([String: String]) -> Void
    let onOpenQuestion: () -> Void
    let onKillTmux: () -> Void

    @ObservedObject private var metadataService = SessionMetadataService.shared
    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isPreviewExpanded = true

    /// Strip parenthetical suffix like "(1M context)" from model display name
    private static func shortModelName(_ name: String) -> String {
        if let range = name.range(of: " (") {
            return String(name[name.startIndex..<range.lowerBound])
        }
        return name
    }

    private func instanceContextColor(_ pct: Double) -> Color {
        if pct >= 90 { return Color(red: 0.95, green: 0.3, blue: 0.3) }
        if pct >= 70 { return Color(red: 0.95, green: 0.55, blue: 0.25) }
        if pct >= 50 { return Color(red: 0.95, green: 0.8, blue: 0.3) }
        return Color(red: 0.4, green: 0.85, blue: 0.45)
    }

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether we're showing the question UI
    private var isWaitingForAnswer: Bool {
        session.phase.isWaitingForAnswer
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Extract tool preview data from the active permission context
    private var toolPreview: ToolPreviewData? {
        guard isWaitingForApproval,
              let permission = session.activePermission else { return nil }
        return ToolPreviewData.from(permission: permission)
    }

    var body: some View {
        let preview = toolPreview
        VStack(alignment: .leading, spacing: 0) {
            // Main row content
            mainRow(preview: preview)

            // Expandable tool preview (diff/command) below the row
            if isWaitingForApproval, let preview, isPreviewExpanded {
                toolPreviewSection(preview)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .animation(.easeInOut(duration: 0.2), value: isPreviewExpanded)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    // MARK: - Main Row

    private func mainRow(preview: ToolPreviewData?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // Terminal type icon + state indicator on left
            terminalTypeIcon
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Terminal badge
                    if let terminalName = session.terminalDisplayName {
                        Text(terminalName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }

                    // Model + context badges
                    if let meta = metadataService.metadata(for: session.sessionId) {
                        if let model = meta.model {
                            Text(Self.shortModelName(model))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.25))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        if let ctx = meta.contextPercentage {
                            Text("context:\(String(format: "%.0f", ctx))%")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.25))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Capsule())
                        }
                    }
                }

                // Show tool call when waiting for approval/answer, otherwise last activity
                if isWaitingForAnswer, let ctx = session.activeQuestion {
                    // Show question summary in amber
                    HStack(spacing: 4) {
                        Text("Question")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        Text(ctx.questionText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                } else if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if preview != nil {
                            // Show toggle for preview instead of raw input
                            Button {
                                isPreviewExpanded.toggle()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: isPreviewExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8, weight: .medium))
                                    Text(isPreviewExpanded ? "Hide preview" : "Show preview")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(.white.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval/question buttons
            if isWaitingForAnswer {
                // Question - show "Answer" button that opens question view
                HStack(spacing: 8) {
                    Button {
                        onOpenQuestion()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 9, weight: .medium))
                            Text("Answer")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(TerminalColors.amber.opacity(0.9))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show chat + terminal buttons
                HStack(spacing: 8) {
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Go to Terminal button (available when we know the terminal app)
                    if session.canJumpToTerminal {
                        TerminalJumpButton(
                            iconName: session.terminalIconName,
                            terminalName: session.terminalDisplayName,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Terminal jump button (for any session with a resolved terminal)
                    if session.canJumpToTerminal {
                        IconButton(icon: session.terminalIconName) {
                            onFocus()
                        }
                    }

                    // Kill tmux pane / archive button
                    if session.isInTmux, session.pid != nil {
                        IconButton(icon: "trash") {
                            onKillTmux()
                        }
                    } else if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    // MARK: - Tool Preview Section

    @ViewBuilder
    private func toolPreviewSection(_ preview: ToolPreviewData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.06))

            switch preview {
            case .diff(let filePath, let oldString, let newString):
                ApprovalDiffView(
                    filePath: filePath,
                    oldString: oldString,
                    newString: newString
                )
                .padding(.top, 6)
                .padding(.horizontal, 4)

            case .command(let cmd):
                CommandHighlightView(command: cmd)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 4)
    }

    /// Terminal-aware state indicator: shows terminal icon when idle, phase indicator when active
    @ViewBuilder
    private var terminalTypeIcon: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForAnswer:
            Text("?")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
        case .waitingForInput:
            Image(systemName: session.terminalIconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(TerminalColors.green)
        case .idle, .ended:
            Image(systemName: session.terminalIconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.25))
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Jump Button

/// Button to jump to a terminal app, showing the terminal's icon and name
struct TerminalJumpButton: View {
    let iconName: String
    let terminalName: String?
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: iconName)
                    .font(.system(size: 9, weight: .medium))
                Text(terminalName ?? "Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.95))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button (legacy)

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tool Preview Data

/// Extracted preview data for diff/command display in the approval panel
enum ToolPreviewData {
    /// Edit or Write tool — shows a code diff
    case diff(filePath: String, oldString: String?, newString: String?)
    /// Bash tool — shows a highlighted command
    case command(String)

    /// Extract preview data from a permission context.
    /// Returns nil for tools that don't have a meaningful preview.
    static func from(permission: PermissionContext) -> ToolPreviewData? {
        let toolName = permission.toolName
        guard let input = permission.toolInput else { return nil }

        switch toolName {
        case "Edit":
            guard let filePath = stringValue(input["file_path"]),
                  let oldString = stringValue(input["old_string"]),
                  let newString = stringValue(input["new_string"]) else { return nil }
            return .diff(filePath: filePath, oldString: oldString, newString: newString)

        case "Write":
            guard let filePath = stringValue(input["file_path"]),
                  let content = stringValue(input["content"]) else { return nil }
            // Write = all new content, no old string
            return .diff(filePath: filePath, oldString: nil, newString: content)

        case "Bash", "BashOutput":
            guard let cmd = stringValue(input["command"]) else { return nil }
            return .command(cmd)

        default:
            return nil
        }
    }

    /// Extract a String value from an AnyCodable
    private static func stringValue(_ value: AnyCodable?) -> String? {
        guard let v = value else { return nil }
        return v.value as? String
    }
}

