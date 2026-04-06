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
    let modelId: String?
    let contextPercentage: Double?
    let contextWindowSize: Int?

    // Token breakdown (current usage)
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?

    // Cost & timing
    let totalCostUSD: Double?
    let totalDurationMs: Int?
    let totalApiDurationMs: Int?

    // Code stats
    let linesAdded: Int?
    let linesRemoved: Int?

    // Rate limits
    let fiveHourPercentage: Double?
    let fiveHourResetsAt: Int?   // unix timestamp
    let sevenDayPercentage: Double?
    let sevenDayResetsAt: Int?   // unix timestamp

    // Git
    let gitBranch: String?
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
                    newMetadata[sessionId] = SessionMetadata(
                        model: (model?.isEmpty ?? true) ? nil : model,
                        modelId: json["model_id"] as? String,
                        contextPercentage: json["context_pct"] as? Double ?? json["context_percentage"] as? Double,
                        contextWindowSize: json["context_size"] as? Int ?? json["context_window_size"] as? Int,
                        inputTokens: json["input_tokens"] as? Int,
                        outputTokens: json["output_tokens"] as? Int,
                        cacheCreationTokens: json["cache_creation_tokens"] as? Int,
                        cacheReadTokens: json["cache_read_tokens"] as? Int,
                        totalCostUSD: json["total_cost_usd"] as? Double,
                        totalDurationMs: json["total_duration_ms"] as? Int,
                        totalApiDurationMs: json["total_api_duration_ms"] as? Int,
                        linesAdded: json["lines_added"] as? Int,
                        linesRemoved: json["lines_removed"] as? Int,
                        fiveHourPercentage: json["five_hour_pct"] as? Double,
                        fiveHourResetsAt: json["five_hour_resets_at"] as? Int,
                        sevenDayPercentage: json["seven_day_pct"] as? Double,
                        sevenDayResetsAt: json["seven_day_resets_at"] as? Int,
                        gitBranch: json["git_branch"] as? String
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
