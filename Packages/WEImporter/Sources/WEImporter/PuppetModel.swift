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

            // Assemble the parts with the skeleton (one connected component per bone). The skin transform
            // `pose ∘ bind⁻¹` moves each component from its flat-atlas spot into the composed figure. If the
            // bone data doesn't decode to a sane result, `assemble` leaves the positions untouched and
            // reports false so the caller keeps the static preview.
            let ok = assemble(&positions, indices: indices, data: raw, count: n)

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
    /// composes them into the character. Each bone has a BIND pose (its rest frame, authored at the part's
    /// atlas position) and a POSE (its assembled frame). A vertex is moved `pose ∘ bind⁻¹` — the bind⁻¹ takes
    /// the part from its atlas spot to the bone's local frame, the pose places it in the assembled figure.
    /// The mesh splits into one connected component per bone; a component is matched to the bone whose bind
    /// translation sits at its atlas centroid. (The stored layout has Y flipped, so it's un/re-flipped here.)
    @discardableResult
    private static func assemble(_ positions: inout [SIMD2<Float>], indices: [UInt32],
                                 data raw: UnsafeRawBufferPointer, count n: Int) -> Bool {
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
        let boneCount = Int(u32(mdls + 13))
        guard boneCount >= 1, boneCount <= 1024 else { return false }
        func finite(_ m: Affine) -> Bool {
            m.a.isFinite && m.b.isFinite && m.c.isFinite && m.d.isFinite && m.tx.isFinite && m.ty.isFinite
        }

        // Bind poses: one 78-byte record per bone (parent at +5, matrix at +13).
        let firstBone = mdls + 17, bindStride = 78
        var parents = [Int](repeating: -1, count: boneCount)
        var bindLocal = [Affine](repeating: Affine(), count: boneCount)
        for k in 0 ..< boneCount {
            let rec = firstBone + k * bindStride
            guard rec + 13 + 64 <= n, let m = affine(rec + 13), finite(m) else { return false }
            parents[k] = Int(i32(rec + 5)); bindLocal[k] = m
        }
        // Pose matrices: a back-to-back array of `boneCount` 64-byte matrices that begins right after the bind
        // records (a few bytes of padding precede the first one — skip to the next clean affine).
        var poseStart = firstBone + boneCount * bindStride
        var scan = poseStart
        while scan + 64 <= n, scan < poseStart + 32 {
            if let m = affine(scan), abs(m.a) > 0.001, abs(m.d) > 0.001,
               f32(scan + 8) == 0, f32(scan + 24) == 0 { poseStart = scan; break }
            scan += 1
        }
        var poseLocal = [Affine](repeating: Affine(), count: boneCount)
        for k in 0 ..< boneCount {
            if let m = affine(poseStart + k * 64) { poseLocal[k] = m }
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

        // Connected components (one per bone).
        var uf = Array(0 ..< positions.count)
        func find(_ x: Int) -> Int { var x = x; while uf[x] != x { uf[x] = uf[uf[x]]; x = uf[x] }; return x }
        var t = 0
        while t + 2 < indices.count { uf[find(Int(indices[t]))] = find(Int(indices[t+1])); uf[find(Int(indices[t+1]))] = find(Int(indices[t+2])); t += 3 }
        var members: [Int: [Int]] = [:]
        for v in 0 ..< positions.count { members[find(v), default: []].append(v) }
        // Match each component to the bone whose bind translation lies nearest its atlas centroid (the bone
        // authored there), as a greedy bijection.
        var free = Set(0 ..< boneCount)
        var boneOf: [Int: Int] = [:]
        for (r, vs) in members.sorted(by: { ($0.value.first ?? 0) < ($1.value.first ?? 0) }) {
            var cx: Float = 0, cy: Float = 0
            for v in vs { cx += positions[v].x; cy += positions[v].y }
            cx /= Float(vs.count); cy /= Float(vs.count)
            var best = -1; var bestD = Float.greatestFiniteMagnitude
            for k in free {
                let dx = bindWorld[k].tx - cx, dy = bindWorld[k].ty - cy   // same Y convention as the stored atlas
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = k }
            }
            if best >= 0 { boneOf[r] = best; free.remove(best) }
        }
        // The mesh must split into exactly one component per bone — otherwise the bone↔part bijection is
        // ambiguous and the result can't be trusted.
        guard members.count == boneCount else { return false }

        // Apply the skin into a scratch copy, then sanity-check the result before committing. A wrong pose
        // matrix (mis-located array, variant layout) sends parts flying; assembling can only ever PACK the
        // flat atlas tighter, never spread it, so the assembled extent must not exceed the atlas extent.
        func extent(_ ps: [SIMD2<Float>]) -> SIMD2<Float> {
            var lo = ps[0], hi = ps[0]
            for p in ps { lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y)); hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y)) }
            return hi - lo
        }
        guard !positions.isEmpty else { return false }
        let atlasExtent = extent(positions)
        var out = positions
        for v in 0 ..< out.count {
            guard let k = boneOf[find(v)], k < skin.count else { continue }
            let p = skin[k].apply(out[v])
            guard p.x.isFinite, p.y.isFinite else { return false }
            out[v] = p
        }
        let asmExtent = extent(out)
        let slack: Float = 1.05
        guard asmExtent.x <= atlasExtent.x * slack, asmExtent.y <= atlasExtent.y * slack else { return false }
        positions = out
        return true
    }
}
