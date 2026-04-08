//
//  ChatView.swift
//  ClaudeIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var inputText: String
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @ObservedObject private var metadataService = SessionMetadataService.shared
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @State private var localInterrupted: Bool = false
    @State private var currentSpinnerVerb: String = ""
    @State private var loadedItemCount: Int = 0
    @State private var hasMoreHistory: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var pendingUserMessage: String? = nil
    @State private var pastedTextStore: [String: String] = [:]
    @State private var pasteCounter: Int = 0
    @State private var pasteMonitor: Any? = nil
    @FocusState private var isInputFocused: Bool

    private static let initialLoadSize = 5

    static var initStartTime: CFAbsoluteTime = 0

    init(sessionId: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)
        self._inputText = State(initialValue: ChatInputStore.shared.draft(for: sessionId))

        // Initialize from cache: only load the last few items for instant display
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        let initialItems: [ChatHistoryItem]
        if cachedHistory.count > Self.initialLoadSize {
            initialItems = Array(cachedHistory.suffix(Self.initialLoadSize))
        } else {
            initialItems = cachedHistory
        }
        self._history = State(initialValue: initialItems)
        self._loadedItemCount = State(initialValue: initialItems.count)
        self._hasMoreHistory = State(initialValue: cachedHistory.count > initialItems.count)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    
    @StateObject private var companionService = CompanionService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Messages
            Group {
                if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                }
            }
            .clipShape(
                .rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    topTrailingRadius: 0
                )
            )
            .padding(.bottom, 8)

            // Approval bar, interactive prompt, or Input bar
            if let tool = approvalTool {
                if tool == "AskUserQuestion" {
                    interactivePromptBar
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                } else {
                    approvalBar(tool: tool)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                }
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    inputBar
                    CompanionSpriteView(companion: companionService, fontSize: 15)
                        .padding(.bottom, 6)
                }
                .transition(.opacity)
            }
        }
        .onKeyPress(.escape) {
            if isProcessing {
                interruptSession()
                return .handled
            }
            return .ignored
        }
        .swipeBack {
            viewModel.exitChat()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.status)
        .task {
            // Pick spinner verb if already processing when chat opens
            if isProcessing && currentSpinnerVerb.isEmpty {
                currentSpinnerVerb = ProcessingIndicatorView.randomVerb()
            }

            // Git branch load + polling is handled in a separate .task(id: session.cwd)

            // Show cached items immediately (if any) for instant paint
            if !hasLoadedOnce {
                hasLoadedOnce = true
                if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                    let cached = ChatHistoryManager.shared.history(for: sessionId)
                    if !cached.isEmpty, history.isEmpty {
                        let tail = Array(cached.suffix(Self.initialLoadSize))
                        history = tail
                        loadedItemCount = tail.count
                    }
                    if !cached.isEmpty { isLoading = false }
                }
            }

            // ALWAYS re-sync from JSONL on view enter so newly arrived assistant
            // messages / tool results from the live session show up even when
            // hook-driven updates didn't reach us.
            await ChatHistoryManager.shared.syncFromFile(sessionId: sessionId, cwd: session.cwd)
            let full = ChatHistoryManager.shared.history(for: sessionId)
            history = full
            loadedItemCount = full.count
            hasMoreHistory = false

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                if countChanged || lastItemChanged || newHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory
                    loadedItemCount = newHistory.count

                    // Clear pending when a NEWER message exists in history after the
                    // matching user message (i.e., assistant has replied). Until then,
                    // pending stays visible and the matching history item is filtered
                    // out in the render path to avoid visual swap.
                    if let pending = pendingUserMessage,
                       let matchIdx = newHistory.lastIndex(where: {
                           if case .user(let text) = $0.type { return text == pending }
                           return false
                       }),
                       matchIdx < newHistory.count - 1 {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            pendingUserMessage = nil
                        }
                    }

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Refresh git branch if cwd changed
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                // Pick a spinner verb if processing and no verb set yet
                if isNowProcessing && currentSpinnerVerb.isEmpty {
                    currentSpinnerVerb = ProcessingIndicatorView.randomVerb()
                }

                // Reset spinner verb when processing ends
                if !isNowProcessing && !currentSpinnerVerb.isEmpty {
                    currentSpinnerVerb = ""
                }

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available.
            // Skip if there's already text to avoid select-all-on-focus.
            if canSend && !isInputFocused && inputText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: isInputFocused) { _, focused in
            if focused {
                companionService.setEffect(.typing)
                installPasteMonitor()
            } else {
                companionService.clearEffect(.typing)
                removePasteMonitor()
            }
        }
        .onChange(of: session.phase) { _, phase in
            companionService.markActive()
            if phase == .processing {
                companionService.setEffect(.thinking)
            } else {
                companionService.clearEffect(.thinking)
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available.
            // But don't auto-focus if there's already text, to avoid AppKit's
            // default "select all on focus" behavior stomping the user's draft.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages && inputText.isEmpty {
                    isInputFocused = true
                }
            }
            // Sync thinking effect with current phase
            if session.phase == .processing {
                companionService.setEffect(.thinking)
            } else {
                companionService.clearEffect(.thinking)
            }
        }
        .onDisappear {
            companionService.clearEffect(.typing)
            companionService.clearEffect(.thinking)
            removePasteMonitor()
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private func contextColor(_ pct: Double) -> Color {
        if pct >= 90 { return Color(red: 0.95, green: 0.3, blue: 0.3) }
        if pct >= 70 { return Color(red: 0.95, green: 0.55, blue: 0.25) }
        if pct >= 50 { return Color(red: 0.95, green: 0.8, blue: 0.3) }
        return Color(red: 0.4, green: 0.85, blue: 0.45)
    }

    private func shortModelName(_ name: String) -> String {
        if let range = name.range(of: " (") {
            return String(name[name.startIndex..<range.lowerBound])
        }
        return name
    }

    private var chatHeader: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.exitChat()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))

                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                        .lineLimit(1)

                    // Tmux session name badge
                    if let tmuxName = session.tmuxSessionName {
                        Text("tmux: \(tmuxName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.4, green: 0.8, blue: 0.85).opacity(0.5))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.4, green: 0.8, blue: 0.85).opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing && !localInterrupted {
                        ProcessingIndicatorView(verb: currentSpinnerVerb)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    // Pending user message (visible until JSONL sync includes it)
                    if let pending = pendingUserMessage {
                        UserMessageView(text: pending)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.identity)
                    }

                    ForEach(filteredHistoryForRender.reversed()) { item in
                        MessageItemView(item: item, sessionId: sessionId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(
                                isAutoscrollPaused
                                    ? .identity
                                    : .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                        removal: .opacity
                                    )
                            )
                    }

                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(isAutoscrollPaused ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(isAutoscrollPaused ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .simultaneousGesture(
                TapGesture().onEnded { isInputFocused = false }
            )
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - CWD Bar

    private func cwdContextColor(_ pct: Double) -> Color {
        if pct >= 90 { return Color(red: 0.95, green: 0.3, blue: 0.3) }
        if pct >= 70 { return Color(red: 0.95, green: 0.55, blue: 0.25) }
        if pct >= 50 { return Color(red: 0.95, green: 0.8, blue: 0.3) }
        return Color(red: 0.4, green: 0.85, blue: 0.45)
    }

    private var cwdBar: some View {
        HStack(spacing: 6) {
            // Model (blue)
            if let meta = SessionMetadataService.shared.metadata(for: sessionId),
               let model = meta.model {
                Text(shortModelName(model))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.4, green: 0.6, blue: 0.95))
                    .lineLimit(1)
            }

            // Context (label gray, percentage colored)
            if let meta = SessionMetadataService.shared.metadata(for: sessionId),
               let ctx = meta.contextPercentage {
                HStack(spacing: 2) {
                    Text("context:")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                    Text("\(String(format: "%.0f", ctx))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(cwdContextColor(ctx))
                }
            }

            // Folder + directory name (cyan, clickable to open in Finder)
            CwdButton(cwd: session.cwd) {
                viewModel.notchClose()
            }

            // Git branch (purple) — read from statusLine cache, updated on every hook event
            let gitBranch = metadataService.metadata[sessionId]?.gitBranch ?? ""
            if !gitBranch.isEmpty {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundColor(Color(red: 0.7, green: 0.5, blue: 0.9).opacity(0.6))
                Text(gitBranch)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.7, green: 0.5, blue: 0.9).opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, 6)
        .padding(.top, 0)
        .padding(.bottom, 2)
    }

    // MARK: - Input Bar

    /// Can send messages only if session is in tmux
    private var canSendMessages: Bool {
        session.isInTmux && session.tty != nil
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            cwdBar
            HStack(spacing: 10) {
            TextField(canSendMessages ? "Message Claude..." : "Open Claude Code in tmux to enable messaging", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessages ? .white : .white.opacity(0.4))
                .focused($isInputFocused)
                .disabled(!canSendMessages)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(
                                    isInputFocused ? Color.white.opacity(0.22) : Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: isInputFocused ? Color.white.opacity(0.08) : .clear, radius: 4)
                        .animation(.easeInOut(duration: 0.18), value: isInputFocused)
                )
                .contentShape(RoundedRectangle(cornerRadius: 20))
                .pointerStyle(canSendMessages ? .horizontalText : .default)
                .onTapGesture {
                    if canSendMessages { isInputFocused = true }
                }
                .onChange(of: inputText) { _, newValue in
                    ChatInputStore.shared.setDraft(newValue, for: sessionId)
                    companionService.markActive()
                }
                .onSubmit {
                    sendMessage()
                }

            SendButton(
                enabled: canSendMessages && !inputText.isEmpty,
                action: sendMessage
            )
        }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            onApprove: { approvePermission() },
            onDeny: { denyPermission() }
        )
    }

    // MARK: - Interactive Prompt Bar

    /// Bar for interactive tools like AskUserQuestion that need terminal input
    private var interactivePromptBar: some View {
        ChatInteractivePromptBar(
            isInTmux: session.isInTmux,
            onGoToTerminal: { focusTerminal() }
        )
    }

    /// History with the pending user message's duplicate filtered out.
    /// Keeps the pending message visually stable (no swap) while the real one
    /// is present in history.
    private var filteredHistoryForRender: [ChatHistoryItem] {
        guard let pending = pendingUserMessage else { return history }
        var result = history
        if let idx = result.lastIndex(where: { item in
            if case .user(let text) = item.type { return text == pending }
            return false
        }) {
            result.remove(at: idx)
        }
        return result
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func focusTerminal() {
        Task {
            // Use the same path as ClaudeInstancesView for consistency
            if let terminal = session.resolvedTerminal {
                _ = await WindowFocuser.shared.focusTerminal(
                    info: terminal.appInfo,
                    sessionPid: session.pid,
                    cachedTTY: terminal.tty
                )
            } else if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    /// Install NSEvent local monitor to intercept Cmd+V while input is focused.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+V: keyCode 9, or use charactersIgnoringModifiers
            let isCmdV = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "v"
                && !event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.control)
            guard isCmdV else { return event }
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                return event
            }
            insertPaste(text)
            return nil // swallow the event so default paste doesn't fire
        }
    }

    private func removePasteMonitor() {
        if let m = pasteMonitor {
            NSEvent.removeMonitor(m)
            pasteMonitor = nil
        }
    }

    private func insertPaste(_ text: String) {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let longEnough = lineCount > 3 || text.count > 200
        if longEnough {
            pasteCounter += 1
            let placeholder = "[Pasted text #\(pasteCounter) +\(lineCount) lines]"
            pastedTextStore[placeholder] = text
            inputText += placeholder
        } else {
            inputText += text
        }
    }

    /// Expand any paste placeholders in `text` back to their original content.
    private func expandPastePlaceholders(_ text: String) -> String {
        var expanded = text
        for (placeholder, original) in pastedTextStore {
            expanded = expanded.replacingOccurrences(of: placeholder, with: original)
        }
        return expanded
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Expand placeholders to original pasted text before sending.
        let expandedText = expandPastePlaceholders(text)

        localInterrupted = false
        currentSpinnerVerb = ProcessingIndicatorView.randomVerb()
        pendingUserMessage = expandedText
        inputText = ""
        pastedTextStore.removeAll()
        pasteCounter = 0
        ChatInputStore.shared.clearDraft(for: sessionId)

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
        Task { [expandedText] in
            await sendToSession(expandedText)
        }
    }

    private func sendToSession(_ text: String) async {
        guard session.isInTmux else { return }
        guard let tty = session.tty else { return }

        if let target = await findTmuxTarget(tty: tty) {
            guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return }
            // Clear existing input line (Ctrl+U) before sending new text
            _ = try? await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["send-keys", "-t", target.targetString, "C-u"]
            )

            let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let shouldUsePaste = lineCount > 1 || text.count > 200
            if shouldUsePaste {
                let pasted = await sendViaBracketedPaste(
                    tmuxPath: tmuxPath,
                    target: target.targetString,
                    text: text
                )
                if pasted { return }
                // Fallback to normal send if paste failed
            }
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        }
    }

    /// Write `text` to a temp file, load it into a tmux buffer, and paste with
    /// bracketed paste so Claude CLI collapses it to "[Pasted text ...]".
    /// Returns true on success.
    private func sendViaBracketedPaste(tmuxPath: String, target: String, text: String) async -> Bool {
        let bufferName = "claude-island-\(UUID().uuidString.prefix(8))"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ci-paste-\(UUID().uuidString.prefix(8)).txt")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            // load-buffer -b <name> <file>
            _ = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["load-buffer", "-b", bufferName, tempURL.path]
            )
            // paste-buffer -p (bracketed paste) -d (delete buffer) -b <name> -t <target>
            _ = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", target]
            )
            // Give Claude CLI a beat to finish processing the bracketed paste
            // before we send Enter to submit.
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            _ = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["send-keys", "-t", target, "Enter"]
            )
            return true
        } catch {
            return false
        }
    }

    /// Send ESC key to the tmux pane to interrupt the current request
    private func interruptSession() {
        guard isProcessing else { return }

        // Immediately hide processing indicator
        localInterrupted = true

        // Copy last user message to input box
        if let lastUserItem = history.last(where: { item in
            if case .user = item.type { return true }
            return false
        }), case .user(let text) = lastUserItem.type {
            inputText = text
        }

        // Mark session as user-interrupted (red X indicator)
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        // Send ESC to tmux
        guard let tty = session.tty else { return }
        Task {
            if let target = await findTmuxTarget(tty: tty) {
                guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return }
                _ = try? await ProcessExecutor.shared.run(
                    tmuxPath,
                    arguments: ["send-keys", "-t", target.targetString, "Escape"]
                )
            }
        }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(red: 32/255, green: 32/255, blue: 32/255))
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 6) {
                // White dot indicator
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    // Spinner verbs from Claude Code (src/constants/spinnerVerbs.ts)
    static let verbs = [
        "Accomplishing", "Architecting", "Baking", "Beaming", "Brewing",
        "Calculating", "Cascading", "Cerebrating", "Churning", "Clauding",
        "Coalescing", "Cogitating", "Composing", "Computing", "Concocting",
        "Contemplating", "Cooking", "Crafting", "Creating", "Crunching",
        "Crystallizing", "Cultivating", "Deciphering", "Deliberating",
        "Enchanting", "Envisioning", "Fermenting", "Forging", "Generating",
        "Harmonizing", "Hatching", "Ideating", "Imagining", "Improvising",
        "Incubating", "Inferring", "Manifesting", "Marinating", "Mulling",
        "Musing", "Noodling", "Orchestrating", "Percolating", "Pondering",
        "Processing", "Puzzling", "Ruminating", "Simmering", "Sketching",
        "Spinning", "Synthesizing", "Tempering", "Thinking", "Tinkering",
        "Transmuting", "Vibing", "Wandering", "Weaving", "Working",
    ]
    private let baseColor = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
    private let shimmerColor = Color(red: 1.0, green: 0.75, blue: 0.55) // Bright shimmer
    private let baseText: String

    @State private var dotCount: Int = 1
    @State private var shimmerOffset: Int = 0
    private let dotTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private let shimmerTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    static func randomVerb() -> String {
        verbs.randomElement() ?? "Working"
    }

    init(verb: String) {
        baseText = verb
    }

    private var displayText: String {
        baseText + String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner()
                .frame(width: 6)

            shimmerText

            Spacer()
        }
        .onReceive(dotTimer) { _ in
            dotCount = (dotCount % 3) + 1
        }
        .onReceive(shimmerTimer) { _ in
            let textLen = displayText.count
            let cycleLen = textLen + 10
            shimmerOffset = (shimmerOffset + 1) % cycleLen
        }
    }

    /// Text with a shimmer highlight sweeping right-to-left
    private var shimmerText: some View {
        let text = displayText
        let chars = Array(text)
        let glimmerPos = shimmerOffset

        return HStack(spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { index, char in
                let dist = abs(index - glimmerPos)
                let color: Color = dist <= 1 ? shimmerColor : baseColor
                Text(String(char))
                    .font(.system(size: 13))
                    .foregroundColor(color)
            }
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String

    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return tool.isAgentTool ? Color.orange : Color.white.opacity(0.45)
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .white.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded
    private var canExpand: Bool {
        if tool.isAgentTool { return !tool.subagentTools.isEmpty }
        return hasResult || tool.name == "Edit"
    }

    private var showContent: Bool {
        isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                ToolStatusDot(
                    color: tool.isAgentRunning ? .orange : statusColor,
                    isAnimating: tool.isAgentRunning || tool.status == .running || tool.status == .waitingForApproval
                )
                .padding(.top, 5)

                // Unified format: ToolName(primary_arg) — matches Claude CLI style
                let header = toolHeaderDisplay(expanded: isExpanded)
                HStack(alignment: .top, spacing: 0) {
                    Text(header.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor)
                        .fixedSize()
                    if let arg = header.arg, !arg.isEmpty {
                        Text("(\(arg))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.75))
                            .lineLimit(isExpanded ? nil : 1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Supplemental inline text (agent desc)
                if tool.isAgentTool && !tool.subagentTools.isEmpty {
                    let done = tool.subagentTools.filter { $0.status == .success || $0.status == .error }.count
                    Text("(\(done)/\(tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator. Edit/Task show even while running.
                if canExpand && (tool.status != .running || tool.name == "Edit" || tool.isAgentTool) && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Agent subagent tools list (shown when expanded)
            if tool.isAgentTool && !tool.subagentTools.isEmpty && isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(tool.subagentTools) { subTool in
                        AgentToolDetailRow(tool: subTool)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 4)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && !tool.isAgentTool && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input while running (only when expanded)
            if tool.name == "Edit" && tool.status == .running && isExpanded {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(canExpand && isHovering ? Color.white.opacity(0.04) : Color.clear)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .pointerStyle(canExpand ? .link : .default)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }


    /// Build the "ToolName(arg)" header display.
    /// When expanded=true, the arg is shown in full (no truncation).
    private func toolHeaderDisplay(expanded: Bool = false) -> (name: String, arg: String?) {
        let name = MCPToolFormatter.formatToolName(tool.name)
        switch tool.name {
        case "Bash":
            if let cmd = tool.input["command"], !cmd.isEmpty {
                if expanded { return ("Bash", cmd) }
                let first = cmd.components(separatedBy: "\n").first ?? cmd
                return ("Bash", first)
            }
        case "Read", "Edit", "Write":
            if let path = tool.input["file_path"], !path.isEmpty {
                return (tool.name, Self.shortenPath(path))
            }
        case "Grep":
            if let pattern = tool.input["pattern"], !pattern.isEmpty {
                return ("Grep", pattern)
            }
        case "Glob":
            if let pattern = tool.input["pattern"], !pattern.isEmpty {
                return ("Glob", pattern)
            }
        case "WebSearch":
            if let query = tool.input["query"], !query.isEmpty {
                return ("WebSearch", query)
            }
        case "WebFetch":
            if let url = tool.input["url"], !url.isEmpty {
                return ("WebFetch", url)
            }
        case "Task", "Agent":
            if let desc = tool.input["description"] ?? tool.input["prompt"], !desc.isEmpty {
                return (name, String(desc.prefix(60)))
            }
        case "TodoWrite":
            return ("TodoWrite", nil)
        default:
            if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                return (name, MCPToolFormatter.formatArgs(tool.input))
            }
        }
        return (name, nil)
    }

    /// Shorten a file path: last 2 segments.
    private static func shortenPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count <= 2 { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    /// Single-line summary of the tool's result (shown below with └ prefix).
    private func toolSummary() -> String? {
        let status = tool.statusDisplay.text
        switch tool.name {
        case "Bash":
            // Show first non-empty output line as compact summary
            if case .bash(let r) = tool.structuredResult, r.hasOutput {
                let firstLine = r.displayOutput
                    .components(separatedBy: "\n")
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return firstLine
            }
            if let raw = tool.result, !raw.isEmpty {
                return raw.components(separatedBy: "\n")
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            return nil
        case "Read", "Edit", "Write", "Grep", "Glob", "WebSearch", "WebFetch":
            if status.isEmpty || status == "Completed" { return nil }
            return status
        default:
            return status.isEmpty ? nil : status
        }
    }

}

// MARK: - Agent Activity Views

/// Categorizes subagent tool calls by activity type
/// Pulsing status dot that survives parent view re-renders.
/// Uses TimelineView instead of withAnimation(.repeatForever) which breaks
/// when the parent chatItem is updated by file sync.
struct ToolStatusDot: View {
    let color: Color
    let isAnimating: Bool

    var body: some View {
        if isAnimating {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let opacity = 0.35 + 0.35 * sin(t * 4.0) // ~0.6s period
                Circle()
                    .fill(color.opacity(opacity))
                    .frame(width: 6, height: 6)
            }
        } else {
            Circle()
                .fill(color.opacity(0.6))
                .frame(width: 6, height: 6)
        }
    }
}

enum AgentActivityCategory: String, CaseIterable {
    case reading = "Reading code"
    case searching = "Searching code"
    case editing = "Editing code"
    case commands = "Running commands"
    case web = "Browsing web"
    case other = "Other"

    var icon: String {
        switch self {
        case .reading: return "doc.text"
        case .searching: return "magnifyingglass"
        case .editing: return "pencil"
        case .commands: return "terminal"
        case .web: return "globe"
        case .other: return "ellipsis.circle"
        }
    }

    static func category(for toolName: String) -> AgentActivityCategory {
        switch toolName {
        case "Read": return .reading
        case "Grep", "Glob": return .searching
        case "Edit", "Write": return .editing
        case "Bash": return .commands
        case "WebSearch", "WebFetch": return .web
        default: return .other
        }
    }

}

/// Individual tool detail within an expanded category
struct AgentToolDetailRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    private var label: String {
        if let path = tool.input["file_path"] ?? tool.input["path"] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let pattern = tool.input["pattern"] { return "grep: \(pattern)" }
        if let cmd = tool.input["command"] {
            let first = cmd.components(separatedBy: "\n").first ?? cmd
            return String(first.prefix(50))
        }
        if let query = tool.input["query"] { return query }
        if let url = tool.input["url"] { return String(url.prefix(40)) }
        return tool.name
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 1)
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    var body: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .italic()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let isInTmux: Bool
    let onGoToTerminal: () -> Void

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text("Claude Code needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isInTmux ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                onDeny()
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            // Allow button
            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.95))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(count == 1 ? "1 new message" : "\(count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Send Button

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(foreground)
                .scaleEffect(scale)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointerStyle(enabled ? .link : .default)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if enabled, !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isPressed = false }
                }
        )
    }

    private var foreground: Color {
        if !enabled { return .white.opacity(0.2) }
        return isHovered ? .white : .white.opacity(0.9)
    }

    private var scale: CGFloat {
        if !enabled { return 1.0 }
        if isPressed { return 0.88 }
        return isHovered ? 1.08 : 1.0
    }
}

// MARK: - CWD Button

/// Clickable working directory that opens in Finder on click.
private struct CwdButton: View {
    let cwd: String
    let onOpen: () -> Void
    @State private var isHovered = false

    private let cwdColor = Color(red: 0.4, green: 0.8, blue: 0.85)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundColor(cwdColor.opacity(isHovered ? 0.9 : 0.6))
            Text(URL(fileURLWithPath: cwd).lastPathComponent)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(cwdColor.opacity(isHovered ? 1.0 : 0.7))
                .underline(isHovered)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(cwdColor.opacity(isHovered ? 0.1 : 0))
        )
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            onOpen()
        }
    }
}

