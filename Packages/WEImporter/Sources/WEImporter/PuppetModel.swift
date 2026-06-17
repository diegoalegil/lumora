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
    /// True when the skeleton assembled the flat atlas parts into a sane, composed figure (matrices finite,
    /// bounds didn't blow up). False means the bone data didn't decode cleanly — the caller should keep the
    /// static preview rather than draw scattered/exploded parts. Only verified-good puppets set this.
    public let assembled: Bool

    public init(positions: [SIMD2<Float>], uvs: [SIMD2<Float>], indices: [UInt32], assembled: Bool) {
        self.positions = positions
        self.uvs = uvs
        self.indices = indices
        self.assembled = assembled
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
    /// fallback rather than drawing a garbled mesh. The 80-byte vertex is: position float32 at byte 0/4,
    /// four bone indices uint32 at byte 40/44/48/52, four blend weights float32 at 56/60/64/68, atlas UV
    /// float32 at 72/76. (The remaining floats are normal/tangent data we don't need to deform the sprite.)
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
            var boneIdx = [SIMD4<UInt32>](); boneIdx.reserveCapacity(vertexCount)
            var weights = [SIMD4<Float>](); weights.reserveCapacity(vertexCount)
            for v in 0 ..< vertexCount {
                let o = vertexBase + v * stride
                positions.append(SIMD2(f32(o), f32(o + 4)))
                uvs.append(SIMD2(f32(o + 72), f32(o + 76)))
                boneIdx.append(SIMD4(u32(o + 40), u32(o + 44), u32(o + 48), u32(o + 52)))
                weights.append(SIMD4(f32(o + 56), f32(o + 60), f32(o + 64), f32(o + 68)))
            }
            var indices = [UInt32](); indices.reserveCapacity(indexCount)
            for i in 0 ..< indexCount {
                let idx = UInt32(raw.loadUnaligned(fromByteOffset: indexBase + i * 2, as: UInt16.self))
                guard idx < UInt32(vertexCount) else { return nil }   // a bad index means we mis-parsed — bail
                indices.append(idx)
            }

            // Deform the flat atlas into the assembled figure with linear-blend skinning: each vertex is
            // moved by its bones' `pose ∘ bind⁻¹` transforms, weighted. If the skeleton doesn't decode to a
            // sane result, `assemble` leaves the positions untouched and reports false so the caller keeps
            // the static preview.
            var ok = assemble(&positions, boneIdx: boneIdx, weights: weights, data: raw, count: n)
            // Torn-mesh guard. A correct skin keeps each triangle roughly atlas-proportioned; a mis-parsed
            // skeleton (wrong stride for this .mdl version) leaves parts at their flat-atlas spots so the
            // triangles bridging them stretch across the whole figure. Reject when the longest edge spans a
            // large fraction of the assembled bounds — that's a scatter, not a character.
            if ok, positions.count > 2 {
                var lo = positions[0], hi = positions[0]
                for p in positions { lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y)); hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y)) }
                let diag = max(1, ((hi.x - lo.x) * (hi.x - lo.x) + (hi.y - lo.y) * (hi.y - lo.y)).squareRoot())
                var maxEdge: Float = 0
                var i = 0
                while i + 2 < indices.count {
                    let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2]); i += 3
                    func edge(_ u: Int, _ v: Int) { let d = positions[u] - positions[v]; maxEdge = max(maxEdge, (d.x * d.x + d.y * d.y).squareRoot()) }
                    edge(a, b); edge(b, c); edge(c, a)
                }
                if maxEdge / diag > 0.5 { ok = false }   // longest edge spans half the figure → a scatter
            }

            return PuppetMesh(positions: positions, uvs: uvs, indices: indices, assembled: ok)
        }
    }

    /// A 2-D affine transform (2×2 linear part + translation), row-vector convention `out = M·p + t`.
    private struct Affine {
        var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, tx: Float = 0, ty: Float = 0
        func apply(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(a * p.x + b * p.y + tx, c * p.x + d * p.y + ty) }
        /// self ∘ rhs (apply rhs first, then self).
        func concat(_ r: Affine) -> Affine {
            Affine(a: a * r.a + b * r.c, b: a * r.b + b * r.d, c: c * r.a + d * r.c, d: c * r.b + d * r.d,
                   tx: a * r.tx + b * r.ty + tx, ty: c * r.tx + d * r.ty + ty)
        }
        var inverse: Affine {
            let det = a * d - b * c
            guard abs(det) > 1e-12 else { return Affine() }
            let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
            return Affine(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ib * ty), ty: -(ic * tx + id * ty))
        }
    }

    /// In-place skeletal assembly: a WE puppet stores its vertices as the FLAT sprite atlas; the skeleton
    /// deforms them into the character. Each bone has a BIND pose (its rest frame, authored at the part's
    /// atlas position) and a POSE (its assembled frame); a vertex's skin transform is `pose ∘ bind⁻¹` — the
    /// bind⁻¹ takes the part from its atlas spot to the bone's local frame, the pose places it in the figure.
    /// Each vertex carries up to four (bone, weight) pairs, so the assembled position is the weighted blend
    /// (linear-blend skinning). Rigid puppets like Toga simply weight every vertex 100% to one bone; soft
    /// rigs blend across bones. (The stored layout shares the bind/pose Y convention, so no flip is needed.)
    @discardableResult
    private static func assemble(_ positions: inout [SIMD2<Float>], boneIdx: [SIMD4<UInt32>],
                                 weights: [SIMD4<Float>], data raw: UnsafeRawBufferPointer, count n: Int) -> Bool {
        let needle: [UInt8] = [0x4d, 0x44, 0x4c, 0x53]   // "MDLS"
        var mdls = -1
        for i in stride(from: n - 4, through: 0, by: -1) {
            if raw[i] == needle[0], raw[i+1] == needle[1], raw[i+2] == needle[2], raw[i+3] == needle[3] { mdls = i; break }
        }
        guard mdls >= 0, mdls + 17 <= n else { return false }
        func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        func i32(_ o: Int) -> Int32 { raw.loadUnaligned(fromByteOffset: o, as: Int32.self) }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        // Read a 4×4 row-major matrix as a 2-D affine (rotation m0,m1,m4,m5; translation m12,m13).
        func affine(_ mat: Int) -> Affine? {
            guard mat >= 0, mat + 64 <= n else { return nil }
            return Affine(a: f32(mat), b: f32(mat + 4), c: f32(mat + 16), d: f32(mat + 20), tx: f32(mat + 48), ty: f32(mat + 52))
        }
        func finite(_ m: Affine) -> Bool {
            m.a.isFinite && m.b.isFinite && m.c.isFinite && m.d.isFinite && m.tx.isFinite && m.ty.isFinite
        }
        // A 4×4 row-major 2-D affine has a rigid z-axis: the off-axis terms are 0 and the z/w diagonal is 1.
        // Used to find matrices in the byte stream past variable-length records, allowing any rotation.
        func structuralMatrix(_ o: Int) -> Affine? {
            guard o >= 0, o + 64 <= n, let m = affine(o), finite(m) else { return nil }
            func z(_ i: Int) -> Bool { abs(f32(o + i * 4)) < 1e-3 }
            func one(_ i: Int) -> Bool { abs(f32(o + i * 4) - 1) < 1e-3 }
            guard z(2), z(3), z(6), z(7), z(8), z(9), one(10), z(11), z(14), one(15) else { return nil }
            return m
        }
        let boneCount = Int(u32(mdls + 13))
        guard boneCount >= 1, boneCount <= 1024 else { return false }

        // Bind poses: one record per bone, `[u8 flag][u32=1][i32 parent@+5][u32 matsize=64@+9][64-B matrix@+13]`
        // then a variable trailer (empty in some versions, a null-terminated JSON metadata blob in others), so
        // the record stride isn't fixed — read the fixed head + matrix, then skip to the trailer's null.
        let firstBone = mdls + 17
        var parents = [Int](repeating: -1, count: boneCount)
        var bindLocal = [Affine](repeating: Affine(), count: boneCount)
        var rec = firstBone
        for k in 0 ..< boneCount {
            guard rec + 13 + 64 <= n, let m = affine(rec + 13), finite(m) else { return false }
            parents[k] = Int(i32(rec + 5)); bindLocal[k] = m
            var o = rec + 13 + 64
            while o < n, raw[o] != 0 { o += 1 }   // skip the null-terminated trailer
            rec = o + 1
        }
        // Pose matrices: a back-to-back array of `boneCount` matrices after the bind records. A few header
        // bytes precede the first one, and the per-matrix stride varies by version (64 with no gap, ~76 with a
        // small per-entry header) — locate the first matrix, then measure the stride from the second. Require
        // the WHOLE array to be present (every slot a clean matrix at the same stride): a partial hit means we
        // mis-parsed this version's layout, and assembling on it would scatter the parts, so bail to false.
        var poseLocal = bindLocal
        var poseStart = -1
        var scan = rec
        while scan + 64 <= n, scan < rec + 64 {
            if structuralMatrix(scan) != nil { poseStart = scan; break }
            scan += 1
        }
        guard poseStart >= 0 else { return false }
        var poseStride = 64
        var t = poseStart + 56
        while t + 64 <= n, t < poseStart + 160 {
            if structuralMatrix(t) != nil { poseStride = t - poseStart; break }
            t += 1
        }
        for k in 0 ..< boneCount {
            if let m = structuralMatrix(poseStart + k * poseStride) { poseLocal[k] = m }
        }
        // Accumulate local transforms up the parent chain into world transforms.
        func world(_ locals: [Affine], _ k: Int, _ depth: Int) -> Affine {
            guard depth < boneCount, k >= 0, k < boneCount else { return Affine() }
            let p = parents[k]
            return (p >= 0 && p < boneCount && p != k) ? world(locals, p, depth + 1).concat(locals[k]) : locals[k]
        }
        let bindWorld = (0 ..< boneCount).map { world(bindLocal, $0, 0) }
        let poseWorld = (0 ..< boneCount).map { world(poseLocal, $0, 0) }
        // skin transform for bone k: pose ∘ bind⁻¹. The stored atlas Y and the bind/pose Y share the same
        // (already-flipped) convention, so no extra flip is needed here.
        let skin = (0 ..< boneCount).map { poseWorld[$0].concat(bindWorld[$0].inverse) }

        // Linear-blend skin into a scratch copy, then sanity-check before committing. A mis-located/variant
        // pose array would send parts flying; assembling can only ever PACK the flat atlas tighter, never
        // spread it, so the assembled extent must not exceed the atlas extent (and every result stays finite).
        func extent(_ ps: [SIMD2<Float>]) -> SIMD2<Float> {
            var lo = ps[0], hi = ps[0]
            for p in ps { lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y)); hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y)) }
            return hi - lo
        }
        guard positions.count == boneIdx.count, positions.count == weights.count, !positions.isEmpty else { return false }
        let atlasExtent = extent(positions)
        var out = positions
        var moved = 0
        for v in 0 ..< out.count {
            let p0 = out[v], idx = boneIdx[v], w = weights[v]
            var acc = SIMD2<Float>(0, 0), wsum: Float = 0
            for j in 0 ..< 4 {
                let wj = w[j], k = Int(idx[j])
                guard wj > 0, k >= 0, k < skin.count else { continue }
                acc += wj * skin[k].apply(p0); wsum += wj
            }
            guard wsum > 1e-4 else { continue }   // unweighted vertex — leave it at the atlas position
            let p = acc / wsum
            guard p.x.isFinite, p.y.isFinite else { return false }
            out[v] = p; moved += 1
        }
        // If almost nothing was skinned, the weights didn't decode — don't claim a (non-)assembly.
        guard moved > out.count / 2 else { return false }
        let asmExtent = extent(out)
        let slack: Float = 1.05
        guard asmExtent.x <= atlasExtent.x * slack, asmExtent.y <= atlasExtent.y * slack else { return false }
        positions = out
        return true
    }
}
