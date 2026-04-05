//
//  ChatInputStore.swift
//  ClaudeIsland
//
//  In-memory persistence for chat input drafts keyed by sessionId.
//  Preserves user's typed text across ChatView rebuilds (e.g., panel close/reopen).
//

import Foundation

@MainActor
final class ChatInputStore {
    static let shared = ChatInputStore()

    private var drafts: [String: String] = [:]

    private init() {}

    func draft(for sessionId: String) -> String {
        drafts[sessionId] ?? ""
    }

    func setDraft(_ text: String, for sessionId: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = text
        }
    }

    func clearDraft(for sessionId: String) {
        drafts.removeValue(forKey: sessionId)
    }
}
