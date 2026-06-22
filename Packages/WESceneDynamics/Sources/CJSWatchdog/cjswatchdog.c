// SPDX-License-Identifier: MIT
// Provenance: clean-room. See cjswatchdog.h — declares the private-header JavaScriptCore watchdog symbol and
// wraps it. No GPL; the only external reference is Apple's JavaScriptCore framework.
#include "cjswatchdog.h"

// Declared in <JavaScriptCore/JSContextRefPrivate.h> (not in the public modular header). The callback returns
// true to terminate the offending execution; passing the limit raises a JS exception the caller already
// swallows, so the script simply yields no result (graceful degradation), never a frozen render thread.
typedef bool (*Lumora_ShouldTerminate)(JSContextRef ctx, void *context);
extern void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit,
                                                Lumora_ShouldTerminate callback, void *context);

static bool lumora_always_terminate(JSContextRef ctx, void *context) {
    (void)ctx; (void)context;
    return true;
}

void lumora_set_js_execution_time_limit(JSGlobalContextRef ctx, double seconds) {
    if (ctx == 0) { return; }
    JSContextGroupRef group = JSContextGetGroup(ctx);
    JSContextGroupSetExecutionTimeLimit(group, seconds, lumora_always_terminate, 0);
}
