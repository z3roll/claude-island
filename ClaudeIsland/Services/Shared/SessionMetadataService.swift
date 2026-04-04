//
//  SessionMetadataService.swift
//  ClaudeIsland
//
//  Reads cached session metadata (model, context window) from statusLine cache files.
//  These files are written by claude-island-statusline.sh and cleaned up on SessionEnd.
//

import Combine
import Foundation
import os.log

/// Metadata for a single session, extracted from statusLine cache files
struct SessionMetadata: Equatable {
    let model: String?
    let contextPercentage: Double?
    let contextWindowSize: Int?
}

@MainActor
final class SessionMetadataService: ObservableObject {
    static let shared = SessionMetadataService()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "SessionMetadata")

    @Published private(set) var metadata: [String: SessionMetadata] = [:]

    private var refreshTimer: Timer?
    private let tmpDir: String

    private init() {
        self.tmpDir = NSTemporaryDirectory()
        // Don't clean up on startup — statusline may have already written valid cache files
        // for active sessions. Files for ended sessions are cleaned by claude-island-state.py.
        startRefreshTimer()
    }

    /// Get metadata for a specific session
    func metadata(for sessionId: String) -> SessionMetadata? {
        metadata[sessionId]
    }

    // MARK: - Private

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        // Also do an initial refresh
        refresh()
    }

    private func refresh() {
        let fm = FileManager.default
        var newMetadata: [String: SessionMetadata] = [:]

        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }

        for filename in contents {
            guard filename.hasPrefix("claude-island-session-"),
                  filename.hasSuffix(".json") else { continue }

            let filePath = (tmpDir as NSString).appendingPathComponent(filename)
            guard let data = fm.contents(atPath: filePath) else { continue }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sessionId = json["session_id"] as? String {
                    let model = json["model"] as? String
                    let ctxPct = json["context_pct"] as? Double ?? json["context_percentage"] as? Double
                    let ctxSize = json["context_size"] as? Int ?? json["context_window_size"] as? Int
                    newMetadata[sessionId] = SessionMetadata(
                        model: (model?.isEmpty ?? true) ? nil : model,
                        contextPercentage: ctxPct,
                        contextWindowSize: ctxSize
                    )
                }
            } catch {
                Self.logger.debug("Failed to parse session metadata file \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if newMetadata != metadata {
            metadata = newMetadata
        }
    }

    /// Clean up stale session metadata files from previous app runs
    private func cleanupStaleFiles() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }

        for filename in contents {
            guard filename.hasPrefix("claude-island-session-"),
                  filename.hasSuffix(".json") else { continue }

            let filePath = (tmpDir as NSString).appendingPathComponent(filename)
            try? fm.removeItem(atPath: filePath)
        }

        Self.logger.info("Cleaned up stale session metadata files")
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
