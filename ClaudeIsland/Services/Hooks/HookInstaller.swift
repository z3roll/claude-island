//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "HookInstaller")

struct HookInstaller {

    // MARK: - Required hook events

    /// All hook events that must be registered for full session detection.
    /// If any of these are missing, `isInstalled()` returns false and
    /// `installIfNeeded()` will re-register them.
    private static let requiredEvents: Set<String> = [
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Notification",
        "Stop",
        "SubagentStop",
        "SessionStart",
        "SessionEnd",
        "PreCompact",
    ]

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        // Create hooks directory
        do {
            try FileManager.default.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create hooks directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Copy bundled Python hook script
        if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            do {
                if FileManager.default.fileExists(atPath: pythonScript.path) {
                    try FileManager.default.removeItem(at: pythonScript)
                }
                try FileManager.default.copyItem(at: bundled, to: pythonScript)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: pythonScript.path
                )
                logger.info("Hook script installed at \(pythonScript.path, privacy: .public)")
            } catch {
                logger.error("Failed to install hook script: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            logger.error("Bundled claude-island-state.py not found in app bundle")
            return
        }

        // Copy bundled statusLine shell script (only if not already patched)
        let statusLineScript = hooksDir.appendingPathComponent("claude-island-statusline.sh")
        let alreadyPatched: Bool
        if let existing = try? String(contentsOf: statusLineScript, encoding: .utf8) {
            alreadyPatched = existing.contains("_CI_HAS_ORIGINAL=1")
        } else {
            alreadyPatched = false
        }

        if !alreadyPatched {
            if let bundledSL = Bundle.main.url(forResource: "claude-island-statusline", withExtension: "sh") {
                do {
                    if FileManager.default.fileExists(atPath: statusLineScript.path) {
                        try FileManager.default.removeItem(at: statusLineScript)
                    }
                    try FileManager.default.copyItem(at: bundledSL, to: statusLineScript)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: statusLineScript.path
                    )
                    logger.info("StatusLine script installed at \(statusLineScript.path, privacy: .public)")
                } catch {
                    logger.error("Failed to install statusLine script: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                logger.warning("Bundled claude-island-statusline.sh not found in app bundle")
            }
        } else {
            logger.info("StatusLine script already patched, skipping copy")
        }

        updateSettings(at: settings)

        // Post-install verification
        if isInstalled() {
            logger.info("Hook installation verified — all \(requiredEvents.count) events registered")
        } else {
            logger.error("Hook installation verification FAILED — some events may be missing")
        }
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) ~/.claude/hooks/claude-island-state.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcherAndTimeout),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                // Remove stale entries first (e.g. pointing to wrong python path)
                existingEvent.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains("claude-island-state.py")
                        }
                    }
                    return false
                }
                // Add fresh config
                existingEvent.append(contentsOf: config)
                hooks[event] = existingEvent
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        // Configure statusLine wrapper for session metadata caching
        configureStatusLine(in: &json)

        do {
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: settingsURL)
            logger.info("Settings updated at \(settingsURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to write settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Configure statusLine to use our wrapper that caches session metadata.
    /// The wrapper script writes {model, context_pct} to $TMPDIR per session,
    /// then passes stdin through to the user's original statusLine command.
    private static func configureStatusLine(in json: inout [String: Any]) {
        let wrapperCommand = "bash ~/.claude/hooks/claude-island-statusline.sh"

        // Read the user's current statusLine command (if not already ours)
        var originalCommand: String?
        if let existing = json["statusLine"] as? [String: Any],
           let cmd = existing["command"] as? String,
           !cmd.contains("claude-island-statusline") {
            originalCommand = cmd
        }

        // Patch the wrapper script to call the original command
        if let original = originalCommand {
            let scriptPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/hooks/claude-island-statusline.sh")
            if var content = try? String(contentsOf: scriptPath, encoding: .utf8) {
                content = content.replacingOccurrences(of: "_CI_HAS_ORIGINAL=0", with: "_CI_HAS_ORIGINAL=1")
                content = content.replacingOccurrences(of: "_CI_ORIGINAL_CMD=\"\"", with: "_CI_ORIGINAL_CMD=\"\(original)\"")
                try? content.write(to: scriptPath, atomically: true, encoding: .utf8)
                logger.info("Patched statusLine wrapper to call: \(original, privacy: .public)")
            }
        }

        // Set our wrapper as the statusLine command
        var statusLineConfig: [String: Any] = ["command": wrapperCommand]
        // Preserve existing refreshInterval or other fields
        if let existing = json["statusLine"] as? [String: Any] {
            for (key, value) in existing where key != "command" {
                statusLineConfig[key] = value
            }
        }
        json["statusLine"] = statusLineConfig
    }

    /// Check if hooks are currently installed (all required events present)
    static func isInstalled() -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")

        // Also check the script file itself
        let pythonScript = claudeDir
            .appendingPathComponent("hooks")
            .appendingPathComponent("claude-island-state.py")
        guard FileManager.default.fileExists(atPath: pythonScript.path) else {
            logger.debug("isInstalled: hook script not found at \(pythonScript.path, privacy: .public)")
            return false
        }

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        // Check that ALL required events have our hook registered
        var registeredEvents = Set<String>()
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("claude-island-state.py") {
                                registeredEvents.insert(event)
                            }
                        }
                    }
                }
            }
        }

        let missing = requiredEvents.subtracting(registeredEvents)
        if !missing.isEmpty {
            logger.debug("isInstalled: missing hook events: \(missing.sorted().joined(separator: ", "), privacy: .public)")
            return false
        }
        return true
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let statusLineScript = hooksDir.appendingPathComponent("claude-island-statusline.sh")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)
        try? FileManager.default.removeItem(at: statusLineScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("claude-island-state.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        // Remove statusLine if it's ours
        if let statusLine = json["statusLine"] as? [String: Any],
           let cmd = statusLine["command"] as? String,
           cmd.contains("claude-island-statusline") {
            json.removeValue(forKey: "statusLine")
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }

        logger.info("Hooks uninstalled")
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
