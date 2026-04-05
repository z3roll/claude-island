//
//  ExistingSessionScanner.swift
//  ClaudeIsland
//
//  Scans ~/.claude/sessions/*.json on startup to detect already-running
//  Claude processes and create SessionState entries for them before any
//  hook events arrive.
//

import Foundation
import os.log

actor ExistingSessionScanner {
    static let shared = ExistingSessionScanner()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "SessionScanner")

    struct DiscoveredSession {
        let sessionId: String
        let pid: Int
        let cwd: String
        let tty: String?
        let startedAt: Date
    }

    /// Scan ~/.claude/sessions/*.json for active Claude sessions.
    /// Each file is named {PID}.json and contains sessionId, cwd, etc.
    /// Only returns sessions whose PID is still alive.
    func scan() -> [DiscoveredSession] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else {
            Self.logger.debug("No sessions directory found")
            return []
        }

        var results: [DiscoveredSession] = []

        for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String else { continue }

            // Check if process is still alive
            guard kill(Int32(pid), 0) == 0 else {
                Self.logger.debug("Session \(sessionId.prefix(8), privacy: .public) PID \(pid) is dead, skipping")
                continue
            }

            // Get TTY from ps
            let tty = findTTY(forPid: pid)

            // Parse startedAt (milliseconds since epoch)
            let startedAt: Date
            if let startedAtMs = json["startedAt"] as? Double {
                startedAt = Date(timeIntervalSince1970: startedAtMs / 1000)
            } else {
                startedAt = Date()
            }

            results.append(DiscoveredSession(
                sessionId: sessionId,
                pid: pid,
                cwd: cwd,
                tty: tty,
                startedAt: startedAt
            ))
            Self.logger.info("Discovered session \(sessionId.prefix(8), privacy: .public) PID=\(pid) cwd=\(cwd, privacy: .public)")
        }

        return results
    }

    private func findTTY(forPid pid: Int) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let tty = output, !tty.isEmpty, tty != "??" {
            return tty
        }
        return nil
    }
}
