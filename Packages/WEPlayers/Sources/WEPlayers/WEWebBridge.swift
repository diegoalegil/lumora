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
}
