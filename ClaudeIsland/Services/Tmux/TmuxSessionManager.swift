//
//  TmuxSessionManager.swift
//  ClaudeIsland
//
//  Creates and kills tmux sessions for Claude Code
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "TmuxSessionManager")

/// Manages creation and deletion of tmux sessions running Claude Code
actor TmuxSessionManager {
    static let shared = TmuxSessionManager()

    private let sessionPrefix = "claude-"

    private init() {}

    /// List all claude-* tmux sessions, returning their names
    func listClaudeSessions() async -> [String] {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return [] }
        do {
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-sessions", "-F", "#{session_name}"
            ])
            return output
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix(sessionPrefix) }
                .sorted()
        } catch {
            return []
        }
    }

    /// Find the tmux session name for a given Claude PID
    func sessionName(forClaudePid pid: Int) async -> String? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }
        do {
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-panes", "-a", "-F", "#{session_name} #{pane_pid}"
            ])
            let tree = ProcessTreeBuilder.shared.buildTree()
            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let panePid = Int(parts[1]) else { continue }
                let name = String(parts[0])
                if ProcessTreeBuilder.shared.isDescendant(targetPid: pid, ofAncestor: panePid, tree: tree) {
                    return name
                }
            }
        } catch {}
        return nil
    }

    /// Find the smallest available claude-N number and create a new session
    func createSession() async -> String? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            logger.error("tmux not found")
            return nil
        }

        let existing = await listClaudeSessions()
        let usedNumbers = Set(existing.compactMap { name -> Int? in
            guard name.hasPrefix(sessionPrefix) else { return nil }
            return Int(name.dropFirst(sessionPrefix.count))
        })

        // Find smallest available number starting from 1
        var number = 1
        while usedNumbers.contains(number) { number += 1 }
        let sessionName = "\(sessionPrefix)\(number)"

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        do {
            // Create detached tmux session
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "new-session", "-d", "-s", sessionName, "-c", homeDir
            ])

            // Send claude command to the new session
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "send-keys", "-t", sessionName, "claude", "Enter"
            ])

            logger.info("Created tmux session: \(sessionName, privacy: .public)")
            return sessionName
        } catch {
            logger.error("Failed to create session \(sessionName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Kill a tmux session by name
    func killSession(name: String) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "kill-session", "-t", name
            ])
            logger.info("Killed tmux session: \(name, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to kill session \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Kill only the pane where a specific Claude PID is running.
    /// If it's the last pane in the session, tmux auto-closes the session.
    func killPane(forClaudePid pid: Int) async -> Bool {
        guard let target = await TmuxTargetFinder.shared.findTarget(forClaudePid: pid) else {
            logger.error("Could not find tmux pane for PID \(pid)")
            return false
        }
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "kill-pane", "-t", target.targetString
            ])
            logger.info("Killed tmux pane \(target.targetString, privacy: .public) for PID \(pid)")
            return true
        } catch {
            logger.error("Failed to kill pane \(target.targetString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
