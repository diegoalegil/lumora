// SPDX-License-Identifier: MIT
// Provenance: clean-room. project.json shape from docs.wallpaperengine.io + observed files.
import Foundation

/// The `project.json` manifest — the app's entry point for every wallpaper. The `type`
/// drives the router; `file` is the main asset interpreted per type (scene.json/scene.pkg,
/// *.mp4, index.html).
public struct ProjectManifest: Sendable, Equatable, Decodable {
    public let title: String?
    public let description: String?
    /// Raw `type` string as written in the file (e.g. "scene"). Use ``type`` for the parsed,
    /// scope-checked value (which rejects "application").
    public let rawType: String
    public let file: String
    public let preview: String?
    public let tags: [String]
    public let visibility: String?
    public let workshopID: String?
    public let contentRating: String?
    public let general: GeneralSection?

    /// Parsed, scope-checked type. `nil` when the raw type is unsupported (e.g. application).
    public var type: WallpaperType? { try? WallpaperType.parse(rawType) }

    enum CodingKeys: String, CodingKey {
        case title, description, type, file, preview, tags, visibility
        case workshopID = "workshopid"
        case contentRating = "contentrating"
        case general
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.rawType = try c.decode(String.self, forKey: .type)
        self.file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        self.preview = try c.decodeIfPresent(String.self, forKey: .preview)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        self.contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        self.general = try c.decodeIfPresent(GeneralSection.self, forKey: .general)
        // workshopid appears as an integer in most files but occasionally a string.
        if let i = try? c.decodeIfPresent(Int.self, forKey: .workshopID) {
            self.workshopID = String(i)
        } else {
            self.workshopID = try c.decodeIfPresent(String.self, forKey: .workshopID)
        }
    }

    public init(title: String?, description: String? = nil, rawType: String, file: String,
                preview: String? = nil, tags: [String] = [], visibility: String? = nil,
                workshopID: String? = nil, contentRating: String? = nil,
                general: GeneralSection? = nil) {
        self.title = title; self.description = description; self.rawType = rawType
        self.file = file; self.preview = preview; self.tags = tags
        self.visibility = visibility; self.workshopID = workshopID
        self.contentRating = contentRating; self.general = general
    }

    /// Parse a manifest from raw `project.json` bytes.
    public static func decode(from data: Data) throws -> ProjectManifest {
        try JSONDecoder().decode(ProjectManifest.self, from: data)
    }
}

/// The `general` section, carrying the user-customization schema.
public struct GeneralSection: Sendable, Equatable, Decodable {
    public let properties: [String: WEProperty]

    enum CodingKeys: String, CodingKey { case properties }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.properties = try c.decodeIfPresent([String: WEProperty].self, forKey: .properties) ?? [:]
    }

    public init(properties: [String: WEProperty]) { self.properties = properties }

    /// Properties sorted by their `order` field (then by key) — the display order WE uses.
    public var orderedProperties: [(key: String, property: WEProperty)] {
        properties.sorted {
            ($0.value.order ?? .max, $0.key) < ($1.value.order ?? .max, $1.key)
        }.map { (key: $0.key, property: $0.value) }
    }
}
