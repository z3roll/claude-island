//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses terminal windows using multiple strategies:
//  1. NSWorkspace (works everywhere, app-level)
//  2. AppleScript/JXA (tab/pane level for supported terminals)
//  3. yabai (window-level for tiling WM users)
//

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "WindowFocuser")

/// Focuses windows using multiple strategies
actor WindowFocuser {
    static let shared = WindowFocuser()

    private init() {}

    // MARK: - Primary API

    /// Focus a terminal window by its bundle ID.
    /// This is the main entry point — works without yabai.
    func focusTerminalApp(bundleId: String) async -> Bool {
        return await MainActor.run {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId
            }) else { return false }

            if app.isHidden {
                app.unhide()
            }

            // Use `open -a` to activate and restore minimized windows.
            // AXUIElement deminiaturize causes side effects (e.g., Ghostty tab switching).
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-b", bundleId]
            try? task.run()

            return true
        }
    }

    /// Focus a terminal: just activate the app and restore minimized windows.
    /// Does NOT attempt to switch tabs (unreliable across terminal emulators).
    func focusTerminal(info: TerminalAppInfo, sessionPid: Int?, cachedTTY: String? = nil) async -> Bool {
        for bundleId in info.bundleIds {
            if await focusTerminalApp(bundleId: bundleId) {
                return true
            }
        }
        return false
    }

    // MARK: - yabai (existing)

    /// Focus a window by yabai window ID
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id)
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus the tmux window for a terminal (yabai path)
    func focusTmuxWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: tmuxWindow.id)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: window.id)
        }

        return false
    }



    // MARK: - tmux pane targeting

    /// Switch to the tmux pane containing a Claude process
    private func focusTmuxPane(claudePid: Int) async -> Bool {
        guard let target = await TmuxController.shared.findTmuxTarget(forClaudePid: claudePid) else {
            return false
        }
        return await TmuxController.shared.switchToPane(target: target)
    }

    // MARK: - AppleScript tab targeting

    /// Focus a specific tab in a terminal app using AppleScript
    private func focusTabByAppleScript(
        terminalType: TerminalType,
        bundleId: String,
        claudePid: Int,
        cachedTTY: String? = nil
    ) async -> Bool {
        switch terminalType {
        case .terminalApp:
            return await focusTerminalAppTab(claudePid: claudePid, cachedTTY: cachedTTY)
        case .iterm2:
            return await focusITerm2Tab(claudePid: claudePid, cachedTTY: cachedTTY)
        case .kitty:
            return await focusKittyWindow(claudePid: claudePid)
        default:
            return false
        }
    }

    /// Terminal.app: Find tab containing the Claude process's TTY
    private func focusTerminalAppTab(claudePid: Int, cachedTTY: String? = nil) async -> Bool {
        // Use cached TTY if available, otherwise look it up (rebuilds process tree)
        guard let tty = cachedTTY ?? findTTY(forPid: claudePid) else {
            logger.debug("No TTY found for pid \(claudePid)")
            return false
        }

        let escapedTTY = escapeForAppleScript(tty)

        let script = """
        tell application "Terminal"
            activate
            set targetTTY to "\(escapedTTY)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """

        return await runAppleScript(script)
    }

    /// iTerm2: Find session containing the Claude process via TTY matching
    private func focusITerm2Tab(claudePid: Int, cachedTTY: String? = nil) async -> Bool {
        // Use cached TTY if available, otherwise look it up
        guard let ttyName = cachedTTY ?? findTTY(forPid: claudePid) else {
            logger.debug("No TTY found for iTerm2 tab focus, pid \(claudePid)")
            return false
        }

        let escapedTTY = escapeForAppleScript(ttyName)

        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escapedTTY)" then
                            select t
                            select s
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """

        return await runAppleScript(script)
    }

    /// Kitty: Use remote control protocol for window focus
    private func focusKittyWindow(claudePid: Int) async -> Bool {
        let kittyPaths = ["/opt/homebrew/bin/kitty", "/usr/local/bin/kitty"]
        for kittyPath in kittyPaths {
            guard FileManager.default.isExecutableFile(atPath: kittyPath) else { continue }

            let result = await ProcessExecutor.shared.runWithResult(kittyPath, arguments: [
                "@", "focus-window", "--match", "pid:\(claudePid)"
            ])
            switch result {
            case .success(let output) where output.isSuccess:
                return true
            case .success(let output):
                logger.debug("Kitty remote control exited with code \(output.exitCode)")
            case .failure(let error):
                logger.debug("Kitty remote control failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return false
    }

    // MARK: - Helpers

    /// Escape a string for safe interpolation into AppleScript string literals.
    /// Prevents injection via crafted TTY paths containing `"` or `\`.
    private nonisolated func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Find TTY for a given PID by walking up the process tree (fallback when no cached TTY)
    private nonisolated func findTTY(forPid pid: Int) -> String? {
        let tree = ProcessTreeBuilder.shared.buildTree()
        return ProcessTreeBuilder.shared.findTTY(forPid: pid, tree: tree)
    }

    /// Run an AppleScript and return whether it succeeded
    private func runAppleScript(_ source: String) async -> Bool {
        // Use osascript for AppleScript execution
        do {
            let result = await ProcessExecutor.shared.runWithResult(
                "/usr/bin/osascript",
                arguments: ["-e", source]
            )
            switch result {
            case .success(let output):
                let trimmed = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == "true"
            case .failure(let error):
                logger.debug("AppleScript failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }
}
