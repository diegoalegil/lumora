// SPDX-License-Identifier: Apache-2.0
// Provenance: clean-room. A small MSL prelude prepended to every transpiled WE shader, supplying the
// names WE's GLSL dialect assumes from its (unshipped) common headers: the POSIX math.h constants Metal
// spells differently, and the standard geometric helpers WE shaders call. Each definition is written
// from its universal mathematical meaning (a rotation matrix is a rotation matrix), not from any GPL
// reference renderer's source. Grows as more built-ins are needed.
import Foundation

public enum WEShaderPrelude {
    /// File-scope MSL definitions inserted after `using namespace metal;`, before the shader's structs.
    public static let msl = """
    // math.h constants WE uses (Metal only predefines the *_F spellings).
    constant float M_PI = 3.14159265358979323846;
    constant float M_PI_2 = 1.57079632679489661923;
    constant float M_PI_4 = 0.78539816339744830962;
    constant float M_1_PI = 0.31830988618379067154;
    constant float M_2_PI = 0.63661977236758134308;
    constant float M_SQRT2 = 1.41421356237309504880;
    constant float M_SQRT1_2 = 0.70710678118654752440;

    // Rotate a 2D vector by `angle` radians about the origin (callers re-centre as needed).
    inline float2 rotateVec2(float2 v, float angle) {
        float s = sin(angle);
        float c = cos(angle);
        return float2(c * v.x - s * v.y, s * v.x + c * v.y);
    }

    """
}
