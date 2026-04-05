//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import AppKit
import Foundation

// MARK: - Sound Event Types

/// Events that can trigger a notification sound
enum SoundEventType: String, CaseIterable, Identifiable {
    case permissionRequest = "Permission Request"
    case taskComplete = "Task Complete"
    case questionWaiting = "Question Waiting"
    case sessionEnded = "Session Ended"

    var id: String { rawValue }

    /// SF Symbol icon name for the event type
    var icon: String {
        switch self {
        case .permissionRequest: return "lock.shield"
        case .taskComplete: return "checkmark.circle"
        case .questionWaiting: return "questionmark.bubble"
        case .sessionEnded: return "stop.circle"
        }
    }

    /// UserDefaults key suffix for this event type
    var settingsKey: String {
        switch self {
        case .permissionRequest: return "permissionRequest"
        case .taskComplete: return "taskComplete"
        case .questionWaiting: return "questionWaiting"
        case .sessionEnded: return "sessionEnded"
        }
    }
}

// MARK: - Sound Source

/// A sound that can be played — either a built-in system sound or a custom file
enum SoundSource: Equatable, Hashable {
    case none
    case system(String)       // System sound name (e.g. "Pop", "Ping")
    case custom(URL, String)  // File URL + display name

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .none: return "None"
        case .system(let name): return name
        case .custom(_, let name): return name
        }
    }

    /// Play this sound
    func play() {
        switch self {
        case .none:
            break
        case .system(let name):
            NSSound(named: name)?.play()
        case .custom(let url, _):
            NSSound(contentsOf: url, byReference: true)?.play()
        }
    }

    /// Whether this source actually produces sound
    var isSilent: Bool {
        self == .none
    }

    // MARK: - Serialization

    /// Encode to a storable string: "none", "system:Pop", "custom:/path/to/file.wav|Display Name"
    var serialized: String {
        switch self {
        case .none: return "none"
        case .system(let name): return "system:\(name)"
        case .custom(let url, let name): return "custom:\(url.path)|\(name)"
        }
    }

    /// Decode from a stored string
    static func from(serialized: String) -> SoundSource {
        if serialized == "none" || serialized.isEmpty {
            return .none
        }
        if serialized.hasPrefix("system:") {
            let name = String(serialized.dropFirst("system:".count))
            return .system(name)
        }
        if serialized.hasPrefix("custom:") {
            let rest = String(serialized.dropFirst("custom:".count))
            let parts = rest.split(separator: "|", maxSplits: 1)
            if parts.count == 2 {
                let url = URL(fileURLWithPath: String(parts[0]))
                let name = String(parts[1])
                // Verify file still exists
                if FileManager.default.fileExists(atPath: url.path) {
                    return .custom(url, name)
                }
            }
            return .none
        }
        // Legacy format: raw sound name like "Pop" — treat as system sound
        if serialized == "None" {
            return .none
        }
        return .system(serialized)
    }
}

// MARK: - System Sounds

/// Built-in system sounds available for selection
enum SystemSound: String, CaseIterable {
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"
}

// MARK: - Legacy Compatibility

/// Available notification sounds — kept for backward compatibility during migration
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

// MARK: - Custom Sounds Directory

enum CustomSoundsManager {
    /// Directory where imported custom sounds are stored
    static let customSoundsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClaudeIsland/CustomSounds")
    }()

    /// Ensure the custom sounds directory exists (called before writes)
    private static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: customSoundsDirectory, withIntermediateDirectories: true)
    }

    /// Import a sound file into the app's sandbox, returns the new URL and display name
    static func importSound(from sourceURL: URL) -> (URL, String)? {
        ensureDirectoryExists()
        let fileName = sourceURL.lastPathComponent
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = customSoundsDirectory.appendingPathComponent(fileName)

        // If file already exists at destination, just return it
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return (destinationURL, displayName)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return (destinationURL, displayName)
        } catch {
            print("Failed to import custom sound: \(error)")
            return nil
        }
    }

    /// List all custom sounds that have been imported
    static func listCustomSounds() -> [(URL, String)] {
        let supportedExtensions: Set<String> = ["wav", "mp3", "aiff", "aif", "m4a", "caf"]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: customSoundsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map { ($0, $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Delete a custom sound file
    static func deleteSound(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - App Settings

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"  // Legacy key
        static func soundForEvent(_ event: SoundEventType) -> String {
            "soundEvent_\(event.settingsKey)"
        }
        static let soundMigrated = "soundSettingsMigrated_v2"
        static let alwaysShowNotch = "alwaysShowNotch"
    }

    // MARK: - Notch Visibility

    static var alwaysShowNotch: Bool {
        get { defaults.bool(forKey: Keys.alwaysShowNotch) }
        set { defaults.set(newValue, forKey: Keys.alwaysShowNotch) }
    }

    // MARK: - Migration

    /// Migrate from single sound setting to per-event-type settings
    static func migrateSoundSettingsIfNeeded() {
        guard !defaults.bool(forKey: Keys.soundMigrated) else { return }

        // Read legacy setting
        let legacySound: SoundSource
        if let rawValue = defaults.string(forKey: Keys.notificationSound) {
            legacySound = SoundSource.from(serialized: rawValue)
        } else {
            legacySound = .system("Pop") // Legacy default
        }

        // Apply to all event types as starting point
        for event in SoundEventType.allCases {
            defaults.set(legacySound.serialized, forKey: Keys.soundForEvent(event))
        }

        defaults.set(true, forKey: Keys.soundMigrated)
    }

    // MARK: - Per-Event Sound Settings

    /// Get the sound configured for a specific event type
    static func sound(for event: SoundEventType) -> SoundSource {
        migrateSoundSettingsIfNeeded()
        guard let serialized = defaults.string(forKey: Keys.soundForEvent(event)) else {
            return defaultSound(for: event)
        }
        return SoundSource.from(serialized: serialized)
    }

    /// Set the sound for a specific event type
    static func setSound(_ sound: SoundSource, for event: SoundEventType) {
        defaults.set(sound.serialized, forKey: Keys.soundForEvent(event))
    }

    /// Default sound for each event type
    private static func defaultSound(for event: SoundEventType) -> SoundSource {
        switch event {
        case .permissionRequest: return .system("Tink")
        case .taskComplete: return .system("Pop")
        case .questionWaiting: return .system("Glass")
        case .sessionEnded: return .system("Blow")
        }
    }

    // MARK: - Legacy (backward compatible)

    /// The sound to play when Claude finishes and is ready for input
    /// Now maps to .taskComplete event type
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }
}
