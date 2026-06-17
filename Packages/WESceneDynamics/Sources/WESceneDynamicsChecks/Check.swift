// SPDX-License-Identifier: MIT
// Provenance: clean-room. Minimal assertion harness (no XCTest dependency — CLT-only env).
import Foundation

enum Check {
    nonisolated(unsafe) static var total = 0
    nonisolated(unsafe) static var failures = 0

    static func that(_ name: String, _ condition: @autoclosure () -> Bool) {
        total += 1
        if condition() {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)")
        }
    }

    static func throwsError<T>(_ name: String, _ expr: () throws -> T, satisfies verify: (Error) -> Bool = { _ in true }) {
        total += 1
        do {
            _ = try expr()
            failures += 1
            print("  ✗ \(name)  (did not throw)")
        } catch {
            if verify(error) {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print("  ✗ \(name)  (unexpected error: \(error))")
            }
        }
    }

    static func noThrow<T>(_ name: String, _ expr: () throws -> T) -> T? {
        total += 1
        do {
            let v = try expr()
            print("  ✓ \(name)")
            return v
        } catch {
            failures += 1
            print("  ✗ \(name)  (threw: \(error))")
            return nil
        }
    }

    static func section(_ title: String) { print("\n▸ \(title)") }

    static func summarize() -> Never {
        print("\n────────────────────────────────────────")
        if failures == 0 {
            print("ALL \(total) CHECKS PASSED")
            exit(0)
        } else {
            print("\(failures)/\(total) CHECKS FAILED")
            exit(1)
        }
    }
}
