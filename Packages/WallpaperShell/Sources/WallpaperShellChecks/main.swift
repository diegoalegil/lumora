// SPDX-License-Identifier: MIT
// Provenance: clean-room verification of the PlaybackPolicyEngine state machine.
import Foundation
import CoreGraphics
import WECore
import WallpaperShell

let engine = PlaybackPolicyEngine(policy: PlaybackPolicy(activeFPS: 60, batteryFPS: 30))

Check.section("PlaybackPolicyEngine")

// Nominal: visible, on AC -> render at full rate.
let nominal = engine.directive(for: PlaybackInputs())
Check.that("nominal renders", nominal.renderingEnabled)
Check.that("nominal full fps", nominal.targetFPS == 60)

// Occluded -> paused.
let occluded = engine.directive(for: PlaybackInputs(isOccluded: true))
Check.that("occluded paused", !occluded.renderingEnabled)
Check.that("occluded fps 0", occluded.targetFPS == 0)

// Fullscreen app covering desktop -> paused.
let covered = engine.directive(for: PlaybackInputs(desktopCoveredByFullscreenApp: true))
Check.that("fullscreen-cover paused", !covered.renderingEnabled)

// On battery (visible) -> throttled, still rendering.
let battery = engine.directive(for: PlaybackInputs(onBattery: true))
Check.that("battery still renders", battery.renderingEnabled)
Check.that("battery throttled fps", battery.targetFPS == 30)

// Low power mode -> throttled.
let lowPower = engine.directive(for: PlaybackInputs(lowPowerMode: true))
Check.that("low-power throttled fps", lowPower.targetFPS == 30)

// User paused -> paused regardless of everything else.
let userPaused = engine.directive(for: PlaybackInputs(onBattery: true, userPaused: true))
Check.that("user-paused paused", !userPaused.renderingEnabled)

// Display asleep -> paused.
let asleep = engine.directive(for: PlaybackInputs(displayAsleep: true))
Check.that("display-asleep paused", !asleep.renderingEnabled)

// Screen locked / screensaver running -> paused (nothing is visible).
let locked = engine.directive(for: PlaybackInputs(screenLocked: true))
Check.that("screen-locked paused", !locked.renderingEnabled)
Check.that("screen-locked fps 0", locked.targetFPS == 0)

// Thermal pressure (serious/critical) -> throttled but still rendering (throttle, don't freeze).
let thermal = engine.directive(for: PlaybackInputs(thermallyThrottled: true))
Check.that("thermal still renders", thermal.renderingEnabled)
Check.that("thermal throttled fps", thermal.targetFPS == 30)

// Pause precedence: a "not visible" signal beats a throttle signal.
let lockedAndThermal = engine.directive(for: PlaybackInputs(screenLocked: true, thermallyThrottled: true))
Check.that("lock beats thermal -> paused", !lockedAndThermal.renderingEnabled)

// Pause precedence: an occlusion + battery combo still pauses (no render at battery fps).
let combo = engine.directive(for: PlaybackInputs(isOccluded: true, onBattery: true))
Check.that("occlusion beats battery -> paused", !combo.renderingEnabled)

// PlaybackDirective clamps negative fps to 0.
Check.that("directive clamps negative fps", PlaybackDirective(renderingEnabled: true, targetFPS: -5).targetFPS == 0)

// MARK: DesktopCoverDetector (fullscreen-app / maximized-window cover -> treated as occluded -> paused)
Check.section("DesktopCoverDetector")
let display = CGRect(x: 0, y: 0, width: 2000, height: 1000)
typealias WinRect = DesktopCoverDetector.WindowRect
Check.that("a fullscreen window covers the display",
           DesktopCoverDetector.isCovered(displayFrame: display, windows: [WinRect(layer: 0, bounds: display)]))
Check.that("a maximized window (menu-bar margin) still counts as covered",
           DesktopCoverDetector.isCovered(displayFrame: display,
                                          windows: [WinRect(layer: 0, bounds: CGRect(x: 0, y: 20, width: 2000, height: 980))]))
Check.that("a half-screen window does not cover",
           !DesktopCoverDetector.isCovered(displayFrame: display,
                                           windows: [WinRect(layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))]))
Check.that("a fullscreen rect on a non-normal layer is ignored (e.g. the wallpaper window itself)",
           !DesktopCoverDetector.isCovered(displayFrame: display, windows: [WinRect(layer: -1, bounds: display)]))
Check.that("no windows means not covered",
           !DesktopCoverDetector.isCovered(displayFrame: display, windows: []))
Check.that("two partial windows do not add up to covered",
           !DesktopCoverDetector.isCovered(displayFrame: display,
                                           windows: [WinRect(layer: 0, bounds: CGRect(x: 0, y: 0, width: 2000, height: 400)),
                                                     WinRect(layer: 0, bounds: CGRect(x: 0, y: 600, width: 2000, height: 400))]))

// MARK: PlaybackCoordinator (per-display aggregation, via a mock signal source)
Check.section("PlaybackCoordinator")
let mock = MockSignalSource()
let displays: [CGDirectDisplayID] = [1, 2]
var results: [CGDirectDisplayID: PlaybackDirective] = [:]
let coordinator = PlaybackCoordinator(engine: PlaybackPolicyEngine(), source: mock, displays: { displays })
coordinator.onDirective = { id, directive in results[id] = directive }

mock.base = PlaybackInputs(onBattery: true)  // visible, on battery
mock.occluded = [1]                          // display 1 occluded, display 2 visible
coordinator.start()
Check.that("occluded display 1 paused", results[1]?.renderingEnabled == false)
Check.that("visible display 2 renders", results[2]?.renderingEnabled == true)
Check.that("visible display 2 throttled on battery", results[2]?.targetFPS == 30)

mock.occluded = []                           // un-occlude display 1
mock.fire()
Check.that("display 1 resumes after un-occlude", results[1]?.renderingEnabled == true)

mock.base = PlaybackInputs(userPaused: true) // global user pause
mock.fire()
Check.that("user pause stops display 1", results[1]?.renderingEnabled == false)
Check.that("user pause stops display 2", results[2]?.renderingEnabled == false)

Check.summarize()
