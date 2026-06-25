// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room regression check that a self-referential particle `children` graph in an untrusted
// scene can't amplify into a hang/OOM (the breadth + total caps in collectParticleSystems).
import Foundation
import WEImporter

func runParticleDoSChecks() {
    Check.section("SceneDocument particle amplification guard")

    // A particle file whose `children` all point back at itself. Without a breadth/total cap, depth-4 recursion
    // would re-resolve + re-parse ~20^4 ≈ 168k particle files (a hang / OOM). The caps bound the collected
    // systems to a few dozen and return promptly.
    let child = "{\"name\":\"p.json\"}"
    let children = Array(repeating: child, count: 20).joined(separator: ",")
    let particle = "{\"emitter\":[{\"name\":\"box\",\"distancemax\":\"100 100 0\"}],\"children\":[\(children)]}"
    let scene = "{\"general\":{\"orthogonalprojection\":{\"width\":1920,\"height\":1080}},"
        + "\"objects\":[{\"id\":1,\"visible\":true,\"particle\":\"p.json\",\"origin\":\"0 0 0\"}]}"

    let package = ScenePackage(version: "1", entries: [
        ScenePackageEntry(path: "scene.json", data: Data(scene.utf8)),
        ScenePackageEntry(path: "p.json", data: Data(particle.utf8)),
    ])

    // The decisive property is that this RETURNS at all: with the breadth (prefix 8) + total (out.count < 64)
    // caps the recursion visits at most a few hundred nodes, so load completes and yields a bounded scene.
    // Without the caps it would re-resolve + re-parse ~20^4 ≈ 168k particle files and never return.
    let renderable = try? SceneGraph.load(from: package)
    Check.that("a self-referential particle graph loads without breadth^depth amplification",
               renderable != nil && (renderable?.particleSystems.count ?? .max) <= 200)
}
