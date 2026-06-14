// SPDX-License-Identifier: MIT
// Provenance: clean-room. Minimal scene.json surface; the full scene graph lands in WEScene.
// This is intentionally thin in Phase 0 — just enough structure (and the Animatable usage) to
// freeze the polymorphic-field decoding contract early.
import Foundation
import simd

/// A minimal decode of `scene.json`. Phase 3+ expands `objects`/materials/effects into the
/// real render graph (in WEScene); here we capture top-level shape and prove polymorphic fields.
public struct SceneDocument: Sendable, Equatable, Decodable {
    public let camera: SceneCamera?
    public let general: SceneGeneral?
    public let objects: [SceneObject]

    enum CodingKeys: String, CodingKey { case camera, general, objects }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.camera = try c.decodeIfPresent(SceneCamera.self, forKey: .camera)
        self.general = try c.decodeIfPresent(SceneGeneral.self, forKey: .general)
        self.objects = try c.decodeIfPresent([SceneObject].self, forKey: .objects) ?? []
    }

    public static func decode(from data: Data) throws -> SceneDocument {
        try JSONDecoder().decode(SceneDocument.self, from: data)
    }
}

public struct SceneCamera: Sendable, Equatable, Decodable {
    public let center: String?
    public let eye: String?
}

public struct SceneGeneral: Sendable, Equatable, Decodable {
    public let ambientcolor: String?
    public let bloom: Bool?
}

/// One scene object. Many fields are `Animatable` (plain value OR `{script,value}`); `origin`,
/// `scale`, `angles` are the classic scripted transform fields.
public struct SceneObject: Sendable, Equatable, Decodable {
    public let name: String?
    public let visible: Animatable<Bool>?
    public let origin: Animatable<String>?
    public let scale: Animatable<String>?
    public let angles: Animatable<String>?
    public let image: String?
    public let particle: String?
}
