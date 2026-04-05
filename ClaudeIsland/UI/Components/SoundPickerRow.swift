//
//  SoundPickerRow.swift
//  ClaudeIsland
//
//  Per-event-type notification sound configuration
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sound Settings Section

/// Top-level sound settings section shown in the menu
struct SoundSettingsSection: View {
    @ObservedObject var soundSelector: SoundSelector

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SoundEventType.allCases) { eventType in
                EventSoundRow(
                    eventType: eventType,
                    soundSelector: soundSelector
                )
            }
        }
    }
}

// MARK: - Event Sound Row

/// A single event type's sound configuration row with expandable picker
struct EventSoundRow: View {
    let eventType: SoundEventType
    @ObservedObject var soundSelector: SoundSelector
    @State private var isHovered = false

    private var isExpanded: Bool {
        soundSelector.expandedEventType == eventType
    }

    private var currentSound: SoundSource {
        soundSelector.sound(for: eventType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row — shows event type + current sound
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    soundSelector.toggleExpanded(for: eventType)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: eventType.icon)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(eventType.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(currentSound.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded sound picker
            if isExpanded {
                SoundOptionsList(
                    eventType: eventType,
                    soundSelector: soundSelector,
                    currentSound: currentSound
                )
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Sound Options List

/// Scrollable list of sound options: None + system sounds + custom sounds + import button
private struct SoundOptionsList: View {
    let eventType: SoundEventType
    @ObservedObject var soundSelector: SoundSelector
    let currentSound: SoundSource

    private let maxVisibleRows = 6
    private let rowHeight: CGFloat = 32

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                // "None" option
                SoundOptionRowInline(
                    label: "None",
                    isSelected: currentSound == .none,
                    icon: "speaker.slash"
                ) {
                    soundSelector.setSound(.none, for: eventType)
                }

                // System sounds
                ForEach(SystemSound.allCases, id: \.self) { sound in
                    SoundOptionRowInline(
                        label: sound.rawValue,
                        isSelected: currentSound == .system(sound.rawValue)
                    ) {
                        let source = SoundSource.system(sound.rawValue)
                        source.play()
                        soundSelector.setSound(source, for: eventType)
                    }
                }

                // Custom sounds divider (only show if there are custom sounds)
                if !soundSelector.customSounds.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.vertical, 2)

                    ForEach(soundSelector.customSounds, id: \.0) { url, name in
                        SoundOptionRowInline(
                            label: name,
                            isSelected: currentSound == .custom(url, name),
                            icon: "waveform",
                            isDeletable: true
                        ) {
                            let source = SoundSource.custom(url, name)
                            source.play()
                            soundSelector.setSound(source, for: eventType)
                        } onDelete: {
                            soundSelector.deleteCustomSound(at: url)
                        }
                    }
                }

                // Import button
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 2)

                ImportSoundButton(soundSelector: soundSelector, eventType: eventType)
            }
        }
        .frame(maxHeight: CGFloat(min(allOptionsCount, maxVisibleRows)) * rowHeight)
    }

    private var allOptionsCount: Int {
        1 + SystemSound.allCases.count + soundSelector.customSounds.count + 1
    }
}

// MARK: - Sound Option Row

private struct SoundOptionRowInline: View {
    let label: String
    let isSelected: Bool
    var icon: String? = nil
    var isDeletable: Bool = false
    let action: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? TerminalColors.green : .white.opacity(0.4))
                            .frame(width: 12)
                    } else {
                        Circle()
                            .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                            .frame(width: 6, height: 6)
                            .frame(width: 12)
                    }

                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(TerminalColors.green)
                    }
                }
            }
            .buttonStyle(.plain)

            // Delete button for custom sounds
            if isDeletable && isHovered {
                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Import Sound Button

private struct ImportSoundButton: View {
    @ObservedObject var soundSelector: SoundSelector
    let eventType: SoundEventType
    @State private var isHovered = false

    var body: some View {
        Button {
            openFilePicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.5))
                    .frame(width: 12)

                Text("Import Custom Sound...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.5))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Sound File"
        panel.allowedContentTypes = [
            UTType.wav,
            UTType.mp3,
            UTType.aiff,
            UTType(filenameExtension: "m4a") ?? UTType.audio,
            UTType(filenameExtension: "caf") ?? UTType.audio,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            if let source = soundSelector.importCustomSound(from: url) {
                source.play()
                soundSelector.setSound(source, for: eventType)
            }
        }
    }
}
