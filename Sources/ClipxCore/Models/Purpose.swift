import Foundation

/// A single user-facing "purpose" label — the intent or destination a clip is
/// marked for (Publish, Coach, Highlight, …). This is Clipx's primary tagging
/// axis on the fast path, replacing the film-school mood/shot/camera taxonomy.
///
/// Clipx is general-purpose: the label set is user-configurable with starter
/// presets per content type, so it fits gameplay, streams, interviews, sports,
/// and vlogs equally — not one niche.
struct PurposeLabel: Identifiable, Codable, Hashable {
    /// Stable, lowercased key stored in `clips.purpose` (CSV). Never shown.
    var key: String
    /// Shown on chips in the capture panel + Light Table.
    var title: String
    /// SF Symbol name for the chip.
    var symbol: String

    var id: String { key }
}

/// A named starter set of purpose labels.
struct PurposePreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var labels: [PurposeLabel]
}

/// Built-in presets plus the active label set (persisted in `UserDefaults`).
/// Defaults to the general "Creator" set so a new user is never shown a
/// niche vocabulary out of the box.
enum Purposes {
    static let creator = PurposePreset(id: "creator", name: "Creator", labels: [
        PurposeLabel(key: "publish", title: "Publish", symbol: "paperplane"),
        PurposeLabel(key: "broll",   title: "B-roll",  symbol: "film"),
        PurposeLabel(key: "short",   title: "Short",   symbol: "rectangle.portrait"),
        PurposeLabel(key: "keep",    title: "Keep",    symbol: "archivebox"),
    ])

    static let coaching = PurposePreset(id: "coaching", name: "Coaching / Sports", labels: [
        PurposeLabel(key: "coach",   title: "Coach",   symbol: "person.wave.2"),
        PurposeLabel(key: "keep",    title: "Keep",    symbol: "star"),
        PurposeLabel(key: "reel",    title: "Reel",    symbol: "film"),
        PurposeLabel(key: "mistake", title: "Mistake", symbol: "exclamationmark.triangle"),
    ])

    static let streamer = PurposePreset(id: "streamer", name: "Streamer", labels: [
        PurposeLabel(key: "clip",      title: "Clip it",   symbol: "scissors"),
        PurposeLabel(key: "highlight", title: "Highlight", symbol: "sparkles"),
        PurposeLabel(key: "fail",      title: "Fail",      symbol: "face.dashed"),
    ])

    static let podcast = PurposePreset(id: "podcast", name: "Podcast / Interview", labels: [
        PurposeLabel(key: "pullquote", title: "Pull-quote", symbol: "quote.bubble"),
        PurposeLabel(key: "short",     title: "Short",      symbol: "rectangle.portrait"),
        PurposeLabel(key: "chapter",   title: "Chapter",    symbol: "bookmark"),
        PurposeLabel(key: "cut",       title: "Cut",        symbol: "scissors"),
    ])

    /// All built-in presets, in picker order.
    static let all: [PurposePreset] = [creator, coaching, streamer, podcast]

    private static let presetKey = "purposeActivePresetID"
    private static let customKey = "purposeCustomLabelsJSON"

    /// The active label set used by the capture panel and the Light Table.
    /// A saved custom set wins; otherwise the chosen preset; otherwise Creator.
    static var active: [PurposeLabel] {
        if let data = UserDefaults.standard.data(forKey: customKey),
           let labels = try? JSONDecoder().decode([PurposeLabel].self, from: data),
           !labels.isEmpty {
            return labels
        }
        let id = UserDefaults.standard.string(forKey: presetKey) ?? creator.id
        return (all.first { $0.id == id } ?? creator).labels
    }

    /// The id of the active built-in preset. Setting it clears any custom set.
    static var activePresetID: String {
        get { UserDefaults.standard.string(forKey: presetKey) ?? creator.id }
        set {
            UserDefaults.standard.set(newValue, forKey: presetKey)
            UserDefaults.standard.removeObject(forKey: customKey)
        }
    }

    /// Display title for a stored key, falling back to a capitalized key for
    /// labels that have since been removed from the active set.
    static func title(forKey key: String) -> String {
        active.first { $0.key == key }?.title ?? key.capitalized
    }

    /// SF Symbol for a stored key, with a neutral fallback.
    static func symbol(forKey key: String) -> String {
        active.first { $0.key == key }?.symbol ?? "tag"
    }
}
