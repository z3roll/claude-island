//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    /// Scan active Claude sessions and reload their chat history from JSONL.
    /// Safe to call repeatedly.
    func rescanSessions() {
        Task {
            let discovered = await ExistingSessionScanner.shared.scan()
            for session in discovered {
                let event = HookEvent(
                    sessionId: session.sessionId,
                    cwd: session.cwd,
                    event: "Notification",
                    status: "waiting_for_input",
                    pid: session.pid,
                    tty: session.tty,
                    tool: nil,
                    toolInput: nil,
                    toolUseId: nil,
                    notificationType: "idle_prompt",
                    message: nil
                )
                await SessionStore.shared.process(.hookReceived(event))

                InterruptWatcherManager.shared.startWatching(
                    sessionId: session.sessionId,
                    cwd: session.cwd
                )
            }
            for session in discovered {
                Task { @MainActor in
                    // Full re-sync from JSONL (forces reload even if already loaded)
                    await ChatHistoryManager.shared.syncFromFile(sessionId: session.sessionId, cwd: session.cwd)
                }
            }
        }
    }

    func startMonitoring() {
        rescanSessions()
        // Refresh whenever hooks are toggled on.
        NotificationCenter.default.addObserver(
            forName: .claudeIslandHooksInstalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rescanSessions()
        }

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.status != "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                    HookSocketServer.shared.cancelPendingQuestions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                    HookSocketServer.shared.cancelPendingQuestion(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            },
            onQuestionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .questionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - Question Handling

    /// Answer a question from AskUserQuestion tool
    func answerQuestion(sessionId: String, answers: [String: String]) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let question = session.activeQuestion else {
                return
            }

            HookSocketServer.shared.respondToQuestion(
                toolUseId: question.toolUseId,
                answers: answers
            )

            await SessionStore.shared.process(
                .questionAnswered(sessionId: sessionId, toolUseId: question.toolUseId, answers: answers)
            )
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }
        // Do NOT stop watching — user may resume and ESC again.
        // Watcher is stopped only on session end.
    }
}
