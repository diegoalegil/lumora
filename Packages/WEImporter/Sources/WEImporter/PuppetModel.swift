// SPDX-License-Identifier: MIT
// Provenance: clean-room. Parser for Wallpaper Engine's binary puppet model (`_puppet.mdl`) — the skeletal
// mesh a model references through its "puppet" key. The layout (an `MDLV<ver>` header, a material path, a
// vertex block, a triangle-index block, then an `MDLS<ver>` skeleton) was reverse-engineered from the byte
// patterns in the user's OWN .mdl files; no GPL reference renderer was read or translated. Foundation only.
import Foundation

/// A puppet's renderable mesh: per-vertex model-space position and atlas UV plus a triangle index list.
/// The positions are already in assembled model space (the bind pose), so this alone draws the character
/// correctly composed from its sprite-atlas parts — skeletal animation deforms it on top.
public struct PuppetMesh: Sendable, Equatable {
    public let positions: [SIMD2<Float>]   // model-space x, y per vertex
    public let uvs: [SIMD2<Float>]         // atlas texcoord per vertex
    public let indices: [UInt32]           // triangle list

    public init(positions: [SIMD2<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        self.positions = positions
        self.uvs = uvs
        self.indices = indices
    }

    /// Axis-aligned bounds of the model-space positions (for placing the mesh in the scene).
    public var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) {
        guard let first = positions.first else { return (SIMD2(0, 0), SIMD2(0, 0)) }
        var lo = first, hi = first
        for p in positions { lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y)); hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y)) }
        return (lo, hi)
    }
}

public enum PuppetModel {
    /// Parse the common 80-byte-vertex `.mdl` (the `MDLV…` form whose vertex section begins `0f 00 80 01`).
    /// A variant attribute layout (different stride) returns nil, so the caller keeps the static-preview
    /// fallback rather than drawing a garbled mesh. The vertex is 20 float32: position in `[0,1]`, atlas UV
    /// in `[18,19]`; the middle floats are skinning/normal data used later for animation.
    public static func parseMesh(_ data: Data) -> PuppetMesh? {
        let n = data.count
        guard n > 0x20 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PuppetMesh? in
            func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
            func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
            // "MDLV" magic.
            guard u32(0) == 0x564c444d else { return nil }
            // Material path is a null-terminated string at 0x15; the vertex section's `0f 00 80 01` marker
            // follows it (after some padding). Anchor the search past the material so a coincidental match
            // inside the float data isn't picked up.
            var p = 0x15
            while p < n, raw[p] != 0 { p += 1 }
            let markerBytes: UInt32 = 0x0180000f   // bytes 0f 00 80 01, little-endian
            var marker = -1
            var s = p
            while s + 4 <= min(n, p + 96) {
                if u32(s) == markerBytes { marker = s; break }
                s += 1
            }
            guard marker >= 0 else { return nil }

            let stride = 80
            let vertexBytes = Int(u32(marker + 4))
            let vertexBase = marker + 8
            guard vertexBytes > 0, vertexBytes % stride == 0, vertexBase + vertexBytes + 4 <= n else { return nil }
            let vertexCount = vertexBytes / stride

            let indexOffset = vertexBase + vertexBytes
            let indexBytes = Int(u32(indexOffset))
            let indexBase = indexOffset + 4
            guard indexBytes > 0, indexBytes % 2 == 0, indexBase + indexBytes <= n else { return nil }
            let indexCount = indexBytes / 2

            var positions = [SIMD2<Float>](); positions.reserveCapacity(vertexCount)
            var uvs = [SIMD2<Float>](); uvs.reserveCapacity(vertexCount)
            for v in 0 ..< vertexCount {
                let o = vertexBase + v * stride
                positions.append(SIMD2(f32(o), f32(o + 4)))
                uvs.append(SIMD2(f32(o + 72), f32(o + 76)))
            }
            var indices = [UInt32](); indices.reserveCapacity(indexCount)
            for i in 0 ..< indexCount {
                let idx = UInt32(raw.loadUnaligned(fromByteOffset: indexBase + i * 2, as: UInt16.self))
                guard idx < UInt32(vertexCount) else { return nil }   // a bad index means we mis-parsed — bail
                indices.append(idx)
            }

            // Assemble the parts with the skeleton. The mesh is N connected components (one per bone, in
            // order); each bone is a bind transform (rotation + translation, possibly nested via a parent).
            // The stored positions are the flat atlas layout with Y already flipped, so the bone's world
            // transform is applied in that flipped frame: x forward, y inverted.
            assemble(&positions, indices: indices, data: raw, count: n)

            return PuppetMesh(positions: positions, uvs: uvs, indices: indices)
        }
    }

    /// In-place skeletal assembly: move each connected component (a part) by its bone's world bind transform.
    private static func assemble(_ positions: inout [SIMD2<Float>], indices: [UInt32],
                                 data raw: UnsafeRawBufferPointer, count n: Int) {
        // Locate the MDLS skeleton block.
        let needle: [UInt8] = [0x4d, 0x44, 0x4c, 0x53]   // "MDLS"
        var mdls = -1
        for i in stride(from: n - 4, through: 0, by: -1) {
            if raw[i] == needle[0], raw[i+1] == needle[1], raw[i+2] == needle[2], raw[i+3] == needle[3] { mdls = i; break }
        }
        guard mdls >= 0 else { return }
        func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        func i32(_ o: Int) -> Int32 { raw.loadUnaligned(fromByteOffset: o, as: Int32.self) }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        let boneCount = Int(u32(mdls + 13))
        guard boneCount >= 1, boneCount < 4096 else { return }
        // Per-bone bind transform: 2×2 rotation (m0,m1,m4,m5) + translation (m12,m13), and the parent.
        struct Bone { var a, b, c, d, tx, ty: Float; var parent: Int }
        var bones: [Bone] = []
        let firstBone = mdls + 17, stride = 78
        for k in 0 ..< boneCount {
            let bp = firstBone + k * stride, mat = bp + 13
            guard mat + 64 <= n else { return }
            bones.append(Bone(a: f32(mat), b: f32(mat + 4), c: f32(mat + 16), d: f32(mat + 20),
                              tx: f32(mat + 48), ty: f32(mat + 52), parent: Int(i32(bp + 5))))
        }
        // World transform of each bone = parent ∘ local (affine compose). The y translation is negated to
        // match the stored layout's flipped Y.
        func worldOf(_ k: Int) -> (a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
            let me = bones[k]
            let local = (a: me.a, b: me.b, c: me.c, d: me.d, tx: me.tx, ty: -me.ty)
            guard me.parent >= 0, me.parent < bones.count, me.parent != k else { return local }
            let p = worldOf(me.parent)
            // p ∘ local (column-vector affine: out = p.R * local.R, p.R * local.T + p.T)
            return (a: p.a * local.a + p.b * local.c, b: p.a * local.b + p.b * local.d,
                    c: p.c * local.a + p.d * local.c, d: p.c * local.b + p.d * local.d,
                    tx: p.a * local.tx + p.b * local.ty + p.tx, ty: p.c * local.tx + p.d * local.ty + p.ty)
        }
        let worlds = (0 ..< boneCount).map(worldOf)
        // Connected components of the triangle graph → contiguous vertex ranges → component i = bone i.
        var parentUF = Array(0 ..< positions.count)
        func find(_ x: Int) -> Int { var x = x; while parentUF[x] != x { parentUF[x] = parentUF[parentUF[x]]; x = parentUF[x] }; return x }
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t+1]), c = Int(indices[t+2])
            parentUF[find(a)] = find(b); parentUF[find(b)] = find(c); t += 3
        }
        // Order the component roots by their lowest vertex index, so component i lines up with bone i.
        var rootOrder: [Int] = [], seen = Set<Int>()
        for v in 0 ..< positions.count { let r = find(v); if !seen.contains(r) { seen.insert(r); rootOrder.append(r) } }
        var boneOfRoot: [Int: Int] = [:]
        for (i, r) in rootOrder.enumerated() { boneOfRoot[r] = min(i, boneCount - 1) }
        for v in 0 ..< positions.count {
            guard let k = boneOfRoot[find(v)] else { continue }
            let w = worlds[k]; let p = positions[v]
            positions[v] = SIMD2(w.a * p.x + w.b * p.y + w.tx, w.c * p.x + w.d * p.y + w.ty)
        }
    }
}
