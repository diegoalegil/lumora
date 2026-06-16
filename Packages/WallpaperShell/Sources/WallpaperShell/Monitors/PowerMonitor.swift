// SPDX-License-Identifier: MIT
// Provenance: clean-room from Apple docs (IOKit IOPowerSources). AC-vs-battery via IOKit is the
// dependable signal on macOS; Low Power Mode is read on demand (its change notification is
// unreliable on macOS, and LPM is absent on desktop Macs before macOS 14).
import Foundation
import IOKit.ps

@MainActor
public final class PowerMonitor {
    public var onChange: (() -> Void)?
    // Touched only on the main thread, but also read by `deinit` (which is nonisolated). The
    // CFRunLoop APIs used on it are thread-safe, so `nonisolated(unsafe)` is sound here.
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    // Thermal-change observer; removed by the nonisolated deinit (removeObserver is thread-safe).
    private nonisolated(unsafe) var thermalToken: (any NSObjectProtocol)?

    public init() {}

    deinit {
        // Cleanup must not depend on callers pairing start()/stop(): CFRunLoopAddSource retains
        // the source, so without this the source would outlive `self`, leaving the IOKit callback
        // pointed at freed memory (use-after-free on the next power change). CFRunLoopRemoveSource
        // is thread-safe, so it is safe from a nonisolated deinit.
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        if let token = thermalToken { NotificationCenter.default.removeObserver(token) }
    }

    /// True when the providing power source is the internal battery (i.e. not on AC).
    public var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (providing as String) == kIOPSBatteryPowerValue
    }

    /// True when macOS Low Power Mode is enabled (read on demand).
    public var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// True under serious/critical thermal pressure — the OS is already shedding performance, so a
    /// background wallpaper should throttle to stop adding sustained load. `.fair` is left alone (it is
    /// common and benign); only the two pressured states count.
    public var isThermallyThrottled: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    public func start() {
        // Thermal state changes (e.g. the Mac heating up under load) re-evaluate the policy.
        thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            // Fires on the run loop we registered it with (main) -> main-actor isolation holds.
            MainActor.assumeIsolated { monitor.onChange?() }
        }, context)?.takeRetainedValue()

        if let source {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if let token = thermalToken {
            NotificationCenter.default.removeObserver(token)
            thermalToken = nil
        }
    }
}
