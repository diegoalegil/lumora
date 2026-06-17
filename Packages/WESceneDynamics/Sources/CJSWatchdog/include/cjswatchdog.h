// SPDX-License-Identifier: MIT
// Provenance: clean-room. Thin C shim exposing JavaScriptCore's execution-time-limit watchdog to Swift.
// The public Swift overlay of JavaScriptCore does not surface JSContextGroupSetExecutionTimeLimit (it lives
// in a private framework header), but the symbol IS exported from the system JavaScriptCore dylib. We declare
// it ourselves and call it, so a runaway SceneScript (`while(true){}`) is aborted instead of hanging the host.
#ifndef CJSWATCHDOG_H
#define CJSWATCHDOG_H

#include <JavaScriptCore/JavaScriptCore.h>

// Bound how long any single JS evaluation/call in `ctx`'s group may run before JavaScriptCore aborts it
// (raising a catchable exception). `seconds` is wall-clock; pass e.g. 0.25 for a per-frame script.
void lumora_set_js_execution_time_limit(JSGlobalContextRef ctx, double seconds);

#endif
