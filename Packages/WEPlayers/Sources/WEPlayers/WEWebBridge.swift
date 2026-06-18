// SPDX-License-Identifier: MIT
// Provenance: clean-room. The host side of Wallpaper Engine's web API (public surface at
// docs.wallpaperengine.io/en/web/). Defined as a forgiving shim so web wallpapers that call these
// hooks initialise instead of throwing ReferenceError; the audio/property feeds arrive with the full
// bridge.
import Foundation

public enum WEWebBridge {
    /// JavaScript injected before a web wallpaper's own scripts run. It defines the functions WE's
    /// host normally provides (the ones a wallpaper *calls*), as no-ops that capture their callbacks.
    /// It deliberately does NOT define `window.wallpaperPropertyListener` — that object is owned by
    /// the wallpaper, which the host later calls into.
    public static let bootstrapScript: String = """
    (function () {
      "use strict";
      var noop = function () {};
      // The wallpaper registers a callback here; the full bridge will drive it with 128 audio bands.
      window.wallpaperRegisterAudioListener = function (callback) { window.__lumoraAudioListener = callback; };
      // Now-playing / media integration — captured but not yet driven.
      window.wallpaperRegisterMediaStatusListener = noop;
      window.wallpaperRegisterMediaPropertiesListener = noop;
      window.wallpaperRegisterMediaThumbnailListener = noop;
      window.wallpaperRegisterMediaTimelineListener = noop;
      window.wallpaperRegisterMediaPlaybackListener = noop;
      // Random-file picker for file properties — no user files yet.
      window.wallpaperRequestRandomFileForProperty = noop;
    })();
    """

    /// Injected before the wallpaper's own scripts (document-start) to make its animation loop pausable.
    /// It wraps `requestAnimationFrame` so that while paused — i.e. when the wallpaper is occluded/asleep —
    /// callbacks are queued instead of scheduled, which stops the page's rAF-driven canvas/WebGL/JS loop
    /// (just as browsers throttle rAF for a hidden tab). The host toggles it through
    /// `window.__lumoraSetAnimationPaused(bool)`; on resume the queued callbacks are flushed to the real
    /// `requestAnimationFrame`, restarting each loop exactly where it left off. When not paused, calls pass
    /// straight through, so visible playback is byte-for-byte unchanged.
    public static let animationSuspendScript: String = """
    (function () {
      "use strict";
      var realRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : null;
      if (!realRAF) { window.__lumoraSetAnimationPaused = function () {}; return; }
      var paused = false;
      var pending = [];
      window.requestAnimationFrame = function (cb) {
        if (paused) { pending.push(cb); return 0; }
        return realRAF(cb);
      };
      window.__lumoraSetAnimationPaused = function (p) {
        p = !!p;
        if (p === paused) { return; }
        paused = p;
        if (!paused && pending.length) {
          var queued = pending;
          pending = [];
          for (var i = 0; i < queued.length; i++) { realRAF(queued[i]); }
        }
      };
    })();
    """
}
