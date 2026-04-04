//
//  TokenUsageService.swift
//  ClaudeIsland
//
//  Reads token usage from the Claude Code statusline cache file
//  (populated by the statusline hook via the Anthropic OAuth usage API).
//  Zero network calls — just reads a local JSON cache.
//

import Combine
import Foundation

struct TokenWindowUsage: Equatable {
    let utilization: Double  // 0–100 percentage
    let resetsAt: Date?

    var percentage: Double { utilization }

    var recoveryText: String {
        guard let resets = resetsAt else { return "" }
        let remaining = max(0, Int(resets.timeIntervalSinceNow))
        if remaining <= 0 { return "" }
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let minutes = (remaining % 3600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    static let zero = TokenWindowUsage(utilization: 0, resetsAt: nil)
}

@MainActor
class TokenUsageService: ObservableObject {
    static let shared = TokenUsageService()

    @Published private(set) var usage5h = TokenWindowUsage.zero
    @Published private(set) var usage7d = TokenWindowUsage.zero

    private var timer: Timer?
    private let cachePath: String

    private init() {
        cachePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-usage-cache.json")
        refresh()
        // Re-read the cache file every 30 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let fiveHour = json["five_hour"] as? [String: Any] {
            usage5h = parseWindow(fiveHour)
        }
        if let sevenDay = json["seven_day"] as? [String: Any] {
            usage7d = parseWindow(sevenDay)
        }
    }

    private func parseWindow(_ dict: [String: Any]) -> TokenWindowUsage {
        let utilization = dict["utilization"] as? Double ?? 0
        var resetsAt: Date?
        if let resetsStr = dict["resets_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = formatter.date(from: resetsStr)
            // Try without fractional seconds if that fails
            if resetsAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                resetsAt = formatter.date(from: resetsStr)
            }
        }
        return TokenWindowUsage(utilization: utilization, resetsAt: resetsAt)
    }
}
