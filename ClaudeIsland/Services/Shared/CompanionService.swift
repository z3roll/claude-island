//
//  CompanionService.swift
//  ClaudeIsland
//
//  Reads companion pet data from ~/.claude.json and provides animated sprite frames.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Species

enum CompanionSpecies: String, Codable, CaseIterable {
    case duck, goose, blob, cat, dragon, octopus, owl, penguin
    case turtle, snail, ghost, axolotl, capybara, cactus, robot
    case rabbit, mushroom, chonk
}

// MARK: - Hat

enum CompanionHat: String, Codable {
    case none, crown, tophat, propeller, halo, wizard, beanie, tinyduck
}

// MARK: - Rarity

enum CompanionRarity: String, Codable {
    case common, uncommon, rare, epic, legendary

    var color: Color {
        switch self {
        case .common:    return Color.gray
        case .uncommon:  return Color.green
        case .rare:      return Color(red: 0.3, green: 0.5, blue: 1.0)
        case .epic:      return Color.purple
        case .legendary: return Color(red: 1.0, green: 0.7, blue: 0.2)
        }
    }
}

// MARK: - Sprite Data

private let IDLE_SEQUENCE: [Int] = [0, 0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 2, 0, 0, 0]

// Each species has 3 frames, each frame is [String] (5 lines). {E} = eye placeholder.
// Line 0 is the hat slot (blank unless frame uses it for effects).
private let BODIES: [CompanionSpecies: [[String]]] = [
    .duck: [
        ["            ", "    __      ", "  <({E} )___  ", "   (  ._>   ", "    `--´    "],
        ["            ", "    __      ", "  <({E} )___  ", "   (  ._>   ", "    `--´~   "],
        ["            ", "    __      ", "  <({E} )___  ", "   (  .__>  ", "    `--´    "],
    ],
    .goose: [
        ["            ", "     ({E}>    ", "     ||     ", "   _(__)_   ", "    ^^^^    "],
        ["            ", "    ({E}>     ", "     ||     ", "   _(__)_   ", "    ^^^^    "],
        ["            ", "     ({E}>>   ", "     ||     ", "   _(__)_   ", "    ^^^^    "],
    ],
    .blob: [
        ["            ", "   .----.   ", "  ( {E}  {E} )  ", "  (      )  ", "   `----´   "],
        ["            ", "  .------.  ", " (  {E}  {E}  ) ", " (        ) ", "  `------´  "],
        ["            ", "    .--.    ", "   ({E}  {E})   ", "   (    )   ", "    `--´    "],
    ],
    .cat: [
        ["            ", "   /\\_/\\    ", "  ( {E}   {E})  ", "  (  ω  )   ", "  (\")_(\")   "],
        ["            ", "   /\\_/\\    ", "  ( {E}   {E})  ", "  (  ω  )   ", "  (\")_(\")~  "],
        ["            ", "   /\\-/\\    ", "  ( {E}   {E})  ", "  (  ω  )   ", "  (\")_(\")   "],
    ],
    .dragon: [
        ["            ", "  /^\\  /^\\  ", " <  {E}  {E}  > ", " (   ~~   ) ", "  `-vvvv-´  "],
        ["            ", "  /^\\  /^\\  ", " <  {E}  {E}  > ", " (        ) ", "  `-vvvv-´  "],
        ["   ~    ~   ", "  /^\\  /^\\  ", " <  {E}  {E}  > ", " (   ~~   ) ", "  `-vvvv-´  "],
    ],
    .octopus: [
        ["            ", "   .----.   ", "  ( {E}  {E} )  ", "  (______)  ", "  /\\/\\/\\/\\  "],
        ["            ", "   .----.   ", "  ( {E}  {E} )  ", "  (______)  ", "  \\/\\/\\/\\/  "],
        ["     o      ", "   .----.   ", "  ( {E}  {E} )  ", "  (______)  ", "  /\\/\\/\\/\\  "],
    ],
    .owl: [
        ["            ", "   /\\  /\\   ", "  (({E})({E}))  ", "  (  ><  )  ", "   `----´   "],
        ["            ", "   /\\  /\\   ", "  (({E})({E}))  ", "  (  ><  )  ", "   .----.   "],
        ["            ", "   /\\  /\\   ", "  (({E})(-))  ", "  (  ><  )  ", "   `----´   "],
    ],
    .penguin: [
        ["            ", "  .---.     ", "  ({E}>{E})     ", " /(   )\\    ", "  `---´     "],
        ["            ", "  .---.     ", "  ({E}>{E})     ", " |(   )|    ", "  `---´     "],
        ["  .---.     ", "  ({E}>{E})     ", " /(   )\\    ", "  `---´     ", "   ~ ~      "],
    ],
    .turtle: [
        ["            ", "   _,--._   ", "  ( {E}  {E} )  ", " /[______]\\ ", "  ``    ``  "],
        ["            ", "   _,--._   ", "  ( {E}  {E} )  ", " /[______]\\ ", "   ``  ``   "],
        ["            ", "   _,--._   ", "  ( {E}  {E} )  ", " /[======]\\ ", "  ``    ``  "],
    ],
    .snail: [
        ["            ", " {E}    .--.  ", "  \\  ( @ )  ", "   \\_`--´   ", "  ~~~~~~~   "],
        ["            ", "  {E}   .--.  ", "  |  ( @ )  ", "   \\_`--´   ", "  ~~~~~~~   "],
        ["            ", " {E}    .--.  ", "  \\  ( @  ) ", "   \\_`--´   ", "   ~~~~~~   "],
    ],
    .ghost: [
        ["            ", "   .----.   ", "  / {E}  {E} \\  ", "  |      |  ", "  ~`~``~`~  "],
        ["            ", "   .----.   ", "  / {E}  {E} \\  ", "  |      |  ", "  `~`~~`~`  "],
        ["    ~  ~    ", "   .----.   ", "  / {E}  {E} \\  ", "  |      |  ", "  ~~`~~`~~  "],
    ],
    .axolotl: [
        ["            ", "}~(______)~{", "}~({E} .. {E})~{", "  ( .--. )  ", "  (_/  \\_)  "],
        ["            ", "~}(______){~", "~}({E} .. {E}){~", "  ( .--. )  ", "  (_/  \\_)  "],
        ["            ", "}~(______)~{", "}~({E} .. {E})~{", "  (  --  )  ", "  ~_/  \\_~  "],
    ],
    .capybara: [
        ["            ", "  n______n  ", " ( {E}    {E} ) ", " (   oo   ) ", "  `------´  "],
        ["            ", "  n______n  ", " ( {E}    {E} ) ", " (   Oo   ) ", "  `------´  "],
        ["    ~  ~    ", "  u______n  ", " ( {E}    {E} ) ", " (   oo   ) ", "  `------´  "],
    ],
    .cactus: [
        ["            ", " n  ____  n ", " | |{E}  {E}| | ", " |_|    |_| ", "   |    |   "],
        ["            ", "    ____    ", " n |{E}  {E}| n ", " |_|    |_| ", "   |    |   "],
        [" n        n ", " |  ____  | ", " | |{E}  {E}| | ", " |_|    |_| ", "   |    |   "],
    ],
    .robot: [
        ["            ", "   .[||].   ", "  [ {E}  {E} ]  ", "  [ ==== ]  ", "  `------´  "],
        ["            ", "   .[||].   ", "  [ {E}  {E} ]  ", "  [ -==- ]  ", "  `------´  "],
        ["     *      ", "   .[||].   ", "  [ {E}  {E} ]  ", "  [ ==== ]  ", "  `------´  "],
    ],
    .rabbit: [
        ["            ", "   (\\__/)   ", "  ( {E}  {E} )  ", " =(  ..  )= ", "  (\")__(\")  "],
        ["            ", "   (|__/)   ", "  ( {E}  {E} )  ", " =(  ..  )= ", "  (\")__(\")  "],
        ["            ", "   (\\__/)   ", "  ( {E}  {E} )  ", " =( .  . )= ", "  (\")__(\")  "],
    ],
    .mushroom: [
        ["            ", " .-o-OO-o-. ", "(__________)", "   |{E}  {E}|   ", "   |____|   "],
        ["            ", " .-O-oo-O-. ", "(__________)", "   |{E}  {E}|   ", "   |____|   "],
        ["   . o  .   ", " .-o-OO-o-. ", "(__________)", "   |{E}  {E}|   ", "   |____|   "],
    ],
    .chonk: [
        ["            ", "  /\\    /\\  ", " ( {E}    {E} ) ", " (   ..   ) ", "  `------´  "],
        ["            ", "  /\\    /|  ", " ( {E}    {E} ) ", " (   ..   ) ", "  `------´  "],
        ["            ", "  /\\    /\\  ", " ( {E}    {E} ) ", " (   ..   ) ", "  `------´~ "],
    ],
]

private let HAT_LINES: [CompanionHat: String] = [
    .none:      "",
    .crown:     "   \\^^^/    ",
    .tophat:    "   [___]    ",
    .propeller: "    -+-     ",
    .halo:      "   (   )    ",
    .wizard:    "    /^\\     ",
    .beanie:    "   (___)    ",
    .tinyduck:  "    ,>      ",
]

// MARK: - CompanionService

@MainActor
final class CompanionService: ObservableObject {
    static let shared = CompanionService()

    @Published private(set) var species: CompanionSpecies = .cat
    @Published private(set) var eye: String = "·"
    @Published private(set) var hat: CompanionHat = .none
    @Published private(set) var shiny: Bool = false
    @Published private(set) var rarity: CompanionRarity = .common
    @Published private(set) var name: String = ""
    @Published private(set) var personality: String = ""
    @Published private(set) var isLoaded: Bool = false

    @Published private(set) var currentFrameLines: [String] = []

    private var tickIndex: Int = 0
    private var timer: Timer?

    private init() {
        loadCompanion()
        startAnimation()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Loading

    private func loadCompanion() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configURL = homeDir.appendingPathComponent(".claude.json")

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let companion = json["companion"] as? [String: Any]
        else { return }

        // Soul from companion
        name = companion["name"] as? String ?? ""
        personality = companion["personality"] as? String ?? ""

        // Bones: use companionOverride if present, else companion
        let bones: [String: Any]
        if let override = json["companionOverride"] as? [String: Any] {
            bones = override
        } else {
            bones = companion
        }

        if let speciesStr = bones["species"] as? String,
           let s = CompanionSpecies(rawValue: speciesStr) {
            species = s
        }
        if let e = bones["eye"] as? String {
            eye = e
        }
        if let hatStr = bones["hat"] as? String,
           let h = CompanionHat(rawValue: hatStr) {
            hat = h
        }
        if let s = bones["shiny"] as? Bool {
            shiny = s
        }
        if let rarityStr = bones["rarity"] as? String,
           let r = CompanionRarity(rawValue: rarityStr) {
            rarity = r
        }

        isLoaded = true
        updateFrame()
    }

    // MARK: - Animation

    private func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        tickIndex = (tickIndex + 1) % IDLE_SEQUENCE.count
        updateFrame()
    }

    private func updateFrame() {
        guard let frames = BODIES[species] else { return }

        let seqValue = IDLE_SEQUENCE[tickIndex]
        let isBlink = seqValue == -1
        let frameIndex = isBlink ? 0 : seqValue

        let body = frames[frameIndex % frames.count]
        var lines = body.map { line -> String in
            if isBlink {
                return line.replacingOccurrences(of: "{E}", with: "-")
            } else {
                return line.replacingOccurrences(of: "{E}", with: eye)
            }
        }

        // Apply hat on line 0 if blank
        if hat != .none, !lines[0].trimmingCharacters(in: .whitespaces).isEmpty == false {
            if let hatLine = HAT_LINES[hat], !hatLine.isEmpty {
                lines[0] = hatLine
            }
        }

        // Drop blank hat slot if ALL frames have blank line 0
        let allFramesBlankLine0 = frames.allSatisfy { $0[0].trimmingCharacters(in: .whitespaces).isEmpty }
        if lines[0].trimmingCharacters(in: .whitespaces).isEmpty && allFramesBlankLine0 {
            lines.removeFirst()
        }

        currentFrameLines = lines
    }
}
