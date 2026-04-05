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

    private var cancellable: AnyCancellable?

    private init() {
        refresh()
        // Observe session metadata changes — 5h/7d derive from it directly.
        cancellable = SessionMetadataService.shared.$metadata
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        // Clear immediately on hook uninstall.
        NotificationCenter.default.addObserver(
            forName: .claudeIslandHooksUninstalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.usage5h = .zero
                self?.usage7d = .zero
            }
        }
        // Re-read from newest session file on hook install.
        NotificationCenter.default.addObserver(
            forName: .claudeIslandHooksInstalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        // Read from the MOST RECENTLY UPDATED session cache file.
        // Sessions that have been idle for a long time have stale metadata, so
        // sorting by file mtime gives us the freshest account-level 5h/7d data.
        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory()
        guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else {
            return // Keep previous values
        }
        let candidates = contents.filter {
            $0.hasPrefix("claude-island-session-") && $0.hasSuffix(".json")
        }
        guard !candidates.isEmpty else { return }

        // Find file with the most recent mtime
        var newest: (path: String, mtime: Date)?
        for filename in candidates {
            let path = (tmpDir as NSString).appendingPathComponent(filename)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                if newest == nil || mtime > newest!.mtime {
                    newest = (path, mtime)
                }
            }
        }

        guard let newest,
              let data = fm.contents(atPath: newest.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let pct5h = json["five_hour_pct"] as? Double
        let resets5h = (json["five_hour_resets_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let pct7d = json["seven_day_pct"] as? Double
        let resets7d = (json["seven_day_resets_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        // Only update if newer values are available; keep previous otherwise.
        if let pct = pct5h {
            let new = TokenWindowUsage(utilization: pct, resetsAt: resets5h)
            if usage5h != new { usage5h = new }
        }
        if let pct = pct7d {
            let new = TokenWindowUsage(utilization: pct, resetsAt: resets7d)
            if usage7d != new { usage7d = new }
        }
    }

}
