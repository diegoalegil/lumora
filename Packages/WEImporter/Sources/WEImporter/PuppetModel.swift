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
    /// True when the mesh forms a sane, composed figure — either the skeleton skinned the flat atlas into
    /// shape, or the atlas was already its own figure (a pre-assembled / near-rigid rig) and its triangles
    /// don't tear. False means the parts didn't compose into a coherent character — the caller should keep
    /// the static preview rather than draw scattered/exploded parts.
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
    /// Where a vertex's fields sit within one stride (position is always at byte 0/4). Centralising this so
    /// that supporting a new `.mdl` vertex format is one entry in `vertexLayout(…)` rather than a marker test
    /// scattered through the parser.
    private struct VertexLayout { let stride: Int; let uvOff: Int; let boneOff: Int; let weightOff: Int }

    /// The single version→layout table: given the `.mdl`'s `MDLV<version>` field and a candidate vertex-block
    /// marker `<lead> 00 <kind> 01`, the vertex layout, or nil if this build doesn't recognise the format (the
    /// caller then keeps the static preview). Every supported vertex format is exactly one case here and the
    /// rest of the parser is format-agnostic — adding a version means adding a case, nothing else.
    private static func vertexLayout(version: Int, markerLead: UInt8, markerKind: UInt8) -> VertexLayout? {
        switch (markerLead, markerKind) {
        case (0x0f, 0x80):                   // the full 80-byte vertex (carries a normal/tangent block)
            return VertexLayout(stride: 80, uvOff: 72, boneOff: 40, weightOff: 56)
        case (0x09, 0x80), (0x0e, 0x81):     // the compact 52-byte vertex (no normal/tangent block)
            return VertexLayout(stride: 52, uvOff: 44, boneOff: 12, weightOff: 28)
        default:
            return nil
        }
    }

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
            // The MDLV version (the four ASCII digits after the "MDLV" magic) selects the format together with
            // the vertex-block marker that follows the material path.
            let version = Int(String(bytes: (4 ..< 8).map { raw[$0] }, encoding: .ascii) ?? "0") ?? 0
            // Material path is a null-terminated string at 0x15; the vertex section follows it (after some
            // padding), tagged by a `<lead> 00 <kind> 01` marker the version→layout table recognises. Anchor
            // the search past the material so a coincidental match inside the float data isn't picked up.
            var p = 0x15
            while p < n, raw[p] != 0 { p += 1 }
            var marker = -1
            var layout: VertexLayout?
            var s = p
            while s + 4 <= min(n, p + 96) {
                if raw[s + 1] == 0, raw[s + 3] == 0x01,
                   let l = vertexLayout(version: version, markerLead: raw[s], markerKind: raw[s + 2]) {
                    marker = s; layout = l; break
                }
                s += 1
            }
            // marker + 8 <= n so the vertex-block size read below stays in bounds (the search only guaranteed
            // the 4 marker bytes fit; this .mdl is untrusted input).
            guard marker >= 0, marker + 8 <= n, let layout else { return nil }
            let stride = layout.stride, uvOff = layout.uvOff, boneOff = layout.boneOff, weightOff = layout.weightOff
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
                uvs.append(SIMD2(f32(o + uvOff), f32(o + uvOff + 4)))
                boneIdx.append(SIMD4(u32(o + boneOff), u32(o + boneOff + 4), u32(o + boneOff + 8), u32(o + boneOff + 12)))
                weights.append(SIMD4(f32(o + weightOff), f32(o + weightOff + 4), f32(o + weightOff + 8), f32(o + weightOff + 12)))
            }
            // The vertex block is untrusted bytes; a corrupt or variant `.mdl` can carry non-finite floats
            // (NaN/Inf bit patterns) in the position or UV fields. Refuse such a mesh cleanly so the caller
            // keeps the static preview instead of letting a NaN position reach the renderer.
            guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

            var indices = [UInt32](); indices.reserveCapacity(indexCount)
            for i in 0 ..< indexCount {
                let idx = UInt32(raw.loadUnaligned(fromByteOffset: indexBase + i * 2, as: UInt16.self))
                guard idx < UInt32(vertexCount) else { return nil }   // a bad index means we mis-parsed — bail
                indices.append(idx)
            }

            // Skin the flat atlas into the assembled figure where the skeleton decodes; where it doesn't, the
            // positions are left as the flat atlas — a pre-assembled or near-rigid rig is already its own
            // figure. assemble's own result is advisory: the FINAL arbiter is the torn-mesh guard below, run on
            // whatever positions we ended with (skinned or flat). This is what lets a near-rigid rig whose pose
            // array we can't locate still render — its flat atlas already IS the character — while a scatter
            // (parts packed far apart that genuinely needed a skin) is still rejected by the same guard.
            assemble(&positions, boneIdx: boneIdx, weights: weights, data: raw, count: n)
            // Torn-mesh guard (the sole "is this a coherent figure?" test). A correctly composed figure keeps
            // its triangles roughly proportioned; a scatter leaves MANY triangles stretching across the whole
            // bounds. Counting the FRACTION of triangles whose longest edge spans over half the bounds
            // separates the two: a coherent rig has only a stray few (a thin staff, a power line, a balloon
            // string), a scatter has a large share. Reject only when a substantial number AND fraction are
            // stretched — so one thin prop doesn't sink an otherwise-composed character. A rejected mesh → the
            // caller keeps the static preview.
            var ok = positions.count > 2 && indices.count >= 3
            if ok {
                var lo = positions[0], hi = positions[0]
                for p in positions { lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y)); hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y)) }
                let diag = max(1, ((hi.x - lo.x) * (hi.x - lo.x) + (hi.y - lo.y) * (hi.y - lo.y)).squareRoot())
                var longTris = 0, totalTris = 0
                var i = 0
                while i + 2 < indices.count {
                    let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2]); i += 3
                    var triMax: Float = 0
                    func edge(_ u: Int, _ v: Int) { let d = positions[u] - positions[v]; triMax = max(triMax, (d.x * d.x + d.y * d.y).squareRoot()) }
                    edge(a, b); edge(b, c); edge(c, a)
                    totalTris += 1
                    if triMax / diag > 0.5 { longTris += 1 }
                }
                if longTris > 8, Float(longTris) > Float(totalTris) * 0.1 { ok = false }   // many stretched triangles → a scatter
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
    /// (linear-blend skinning). Returns true if it committed a skinned result; false (positions left as the
    /// flat atlas) if the skeleton didn't decode — the caller then judges the flat atlas with the torn guard.
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
            // A flat 2-D-in-4×4 affine: rows 0/1 the linear part (cols 2,3 zero), row 2 the z axis (0,0,1,0),
            // row 3 the planar translation (z and w fixed). Versions that carry a z translation here are a
            // different pose convention whose "pose" is animation, not a rest layout — matching strictly keeps
            // those (e.g. a pre-assembled soft rig) on their clean preview rather than deforming them wrongly.
            guard z(2), z(3), z(6), z(7), z(8), z(9), one(10), z(11), z(14), one(15) else { return nil }
            return m
        }
        let boneCount = Int(u32(mdls + 13))
        guard boneCount >= 1, boneCount <= 1024 else { return false }

        // Wallpaper Engine's newer puppet skeletons (MDLS version ≥ 3 — the MDLV0021/0023 models) store the
        // mesh ALREADY in assembled bind-pose model space; the matrix array that follows is animation
        // keyframes, not a rest layout to fold in. Skinning such a mesh with that array deforms a correct
        // figure into scattered parts (the cause of the long-standing "v3/v4 rigs mis-pose" gap). So draw
        // these positions as-is — the caller's torn-mesh guard still rejects any rig whose vertices aren't
        // actually a composed figure, so a mis-parsed mesh falls back to the preview. (The older MDLS0002
        // form below stores a flat sprite atlas that genuinely needs the bind→pose skin to assemble.)
        let mdlsVersion = Int(String(bytes: (mdls + 4 ..< mdls + 8).map { raw[$0] }, encoding: .ascii) ?? "0") ?? 0
        if mdlsVersion >= 3 {
            return positions.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }

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
