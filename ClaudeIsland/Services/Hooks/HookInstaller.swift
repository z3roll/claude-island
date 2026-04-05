//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

extension Notification.Name {
    static let claudeIslandHooksInstalled = Notification.Name("claudeIslandHooksInstalled")
    static let claudeIslandHooksUninstalled = Notification.Name("claudeIslandHooksUninstalled")
}

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


    /// Backup file for the user's original statusLine command (persists across
    /// install/uninstall cycles so we can restore or re-wrap after external tools
    /// like claude-hud overwrite settings.json).
    private static var statusLineBackupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.claude-island-statusline-backup.json")
    }

    /// Read the persisted original statusLine command.
    private static func readStatusLineBackup() -> [String: Any]? {
        guard let data = try? Data(contentsOf: statusLineBackupURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Persist the user's original statusLine config for later restoration.
    private static func writeStatusLineBackup(_ config: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: statusLineBackupURL)
    }

    /// Configure statusLine to use our wrapper that caches session metadata.
    /// The wrapper always outputs a status line for the CLI HUD:
    /// - If the user has a custom statusLine command, it wraps it (pass-through)
    /// - If not, it outputs a built-in default (model, context, 5h, 7d usage)
    private static func configureStatusLine(in json: inout [String: Any]) {
        let wrapperCommand = "bash ~/.claude/hooks/claude-island-statusline.sh"
        let existingStatusLine = json["statusLine"] as? [String: Any]
        let existingCommand = existingStatusLine?["command"] as? String
        let isOurWrapper = existingCommand?.contains("claude-island-statusline") ?? false

        // Determine the "original" command to wrap:
        //   - If settings has a NON-wrapper command → that's a new external HUD
        //     (e.g., user just ran /claude-hud:setup). Capture it, update backup.
        //   - If settings already has OUR wrapper → use backup's command (if any).
        var originalCommand: String?
        if !isOurWrapper, let cmd = existingCommand, !cmd.isEmpty {
            originalCommand = cmd
            // Save non-wrapper command to backup (also preserve other keys)
            var backup: [String: Any] = ["command": cmd]
            if let existing = existingStatusLine {
                for (key, value) in existing where key != "command" {
                    backup[key] = value
                }
            }
            writeStatusLineBackup(backup)
            logger.info("Captured statusLine command to backup: \(cmd, privacy: .public)")
        } else if let backup = readStatusLineBackup(),
                  let cmd = backup["command"] as? String,
                  !cmd.isEmpty {
            originalCommand = cmd
        }

        // Write the original command to a sidecar shell script. The wrapper
        // executes this script via bash (no eval), which preserves all quoting.
        let sidecarPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/.claude-island-original-statusline.sh")
        if let original = originalCommand {
            let content = "#!/bin/bash\n\(original)\n"
            try? content.write(to: sidecarPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: sidecarPath.path
            )
            logger.info("Wrote statusLine sidecar to call: \(original, privacy: .public)")
        } else {
            // Remove sidecar if no original (wrapper falls back to built-in default)
            try? FileManager.default.removeItem(at: sidecarPath)
            logger.info("No original statusLine — wrapper will use built-in default")
        }

        // Always set our wrapper as the statusLine command
        var statusLineConfig: [String: Any] = [
            "type": "command",
            "command": wrapperCommand
        ]
        // Preserve any extra keys from backup (e.g., padding) when restoring.
        if let backup = readStatusLineBackup() {
            for (key, value) in backup where key != "command" && key != "type" {
                statusLineConfig[key] = value
            }
        }
        json["statusLine"] = statusLineConfig
    }

    /// Reset wrapper script's _CI_HAS_ORIGINAL / _CI_ORIGINAL_CMD lines back to
    /// the default blank state before re-patching.
    private static func resetWrapperPatch(_ content: String) -> String {
        var out = content
        // Match any line "_CI_HAS_ORIGINAL=<x>" → reset to 0
        out = out.replacingOccurrences(
            of: #"_CI_HAS_ORIGINAL=\d+"#,
            with: "_CI_HAS_ORIGINAL=0",
            options: .regularExpression
        )
        // Match any line '_CI_ORIGINAL_CMD="..."' (greedy match until end of line)
        out = out.replacingOccurrences(
            of: #"_CI_ORIGINAL_CMD=\"[^\"]*\""#,
            with: "_CI_ORIGINAL_CMD=\"\"",
            options: .regularExpression
        )
        return out
    }

    /// Called on app launch to self-heal if an external tool overwrote our
    /// statusLine configuration. Only runs when hooks are already installed.
    static func ensureStatusLineSelfHeal() {
        guard isInstalled() else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let existingCommand = (json["statusLine"] as? [String: Any])?["command"] as? String
        let isOurWrapper = existingCommand?.contains("claude-island-statusline") ?? false
        if isOurWrapper { return } // Nothing to heal
        logger.info("StatusLine was overwritten externally — re-wrapping")
        configureStatusLine(in: &json)
        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
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
        let sidecarPath = hooksDir.appendingPathComponent(".claude-island-original-statusline.sh")
        try? FileManager.default.removeItem(at: sidecarPath)

        // Clean up cached session metadata files so SessionMetadataService
        // stops displaying stale model/context/token info.
        let tmpDir = NSTemporaryDirectory()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for filename in contents {
                if filename.hasPrefix("claude-island-session-") && filename.hasSuffix(".json") {
                    let path = (tmpDir as NSString).appendingPathComponent(filename)
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
        let usageCache = (tmpDir as NSString).appendingPathComponent("claude-usage-cache.json")
        try? FileManager.default.removeItem(atPath: usageCache)

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

        // Restore original statusLine from backup if we are replacing our wrapper
        if let statusLine = json["statusLine"] as? [String: Any],
           let cmd = statusLine["command"] as? String,
           cmd.contains("claude-island-statusline") {
            if let backup = readStatusLineBackup(),
               let original = backup["command"] as? String,
               !original.isEmpty {
                var restored: [String: Any] = [
                    "type": "command",
                    "command": original
                ]
                for (key, value) in backup where key != "command" && key != "type" {
                    restored[key] = value
                }
                json["statusLine"] = restored
                logger.info("Restored original statusLine: \(original, privacy: .public)")
            } else {
                json.removeValue(forKey: "statusLine")
            }
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
