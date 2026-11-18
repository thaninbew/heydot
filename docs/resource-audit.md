# Resource audit, 2026-11-15

Local-only branch `heydot-perf-resources`, based on `main` at `7a750c0`.
No signing, installation, permission changes, live microphone access, authenticated ChatGPT access,
push, or deployment. Machine: Apple silicon test Mac (Apple M1 Pro, 32 GiB RAM, macOS 26.7.2).

## Findings

| Severity | Finding and evidence | Change |
| --- | --- | --- |
| High | A retained popover keeps its 10 Hz TimelineView subtree after close. The baseline fixture consumed 72.1% of one core over the 35-second closed settle period after 100 opens/closes; a separate run without WebKit still consumed 59.3%. | AppDelegate drives explicit popover visibility; the entire subtree, including meter and usage readout, is removed on close. The status glyph remains change-driven and cached. |
| Medium | The hidden web page and 1100×800 transparent panel had no idle lifetime. Hang-up reloaded ChatGPT and retained the page; process crashes immediately reloaded it too. | Unload after 30 idle seconds. In-flight reads and active calls pin the view. Hang-up, capture end and call failure detach the view, invalidate observation and close/release the panel. A crashed idle renderer is recreated only on demand. No automatic wake reload or retained wake observer. |
| High | Capture.stop did not reject its eight queued decode blocks. A replacement capture has a new serial queue but shares the old LiveSession/native stream, permitting concurrent native decoding. | Skip queued receives after stop; serialize LiveSession state/decode across replacement capture queues. Move bounded admission before conversion/allocation. Meter peaks only at the existing 10 Hz delivery interval, using a reduction instead of an allocated mapped array. Hardware stress remains unverified. |
| Medium | Append-only logging allowed unlimited disk growth, and an oversized message was copied in full. | Current log plus one archive, each at most 1 MiB; messages bounded to 16 KiB of UTF-8. Same-inode rotation with a nonblocking cross-process flock avoids interleaved app/host rotation and never waits for another writer. Busy/failed writes are dropped. |
| Low | ListenerUsage's timer targeted the singleton even on another instance, and had no deinit invalidation. | Weak instance capture, last-viewer cancellation, deinit invalidation and a queued-callback viewer guard. Existing history remains capped at 40 values. |
| Medium | Canceled WebKit polling ignored cancellation and could repeatedly resume immediately until its deadline; queued capture-state observations could apply to a replacement view. | Check cancellation in press/page-load loops; reject capture-state callbacks whose view is no longer current. |

The audio queue was already limited to eight blocks and ONNX to one thread. Supervisor already coalesces
recovery requests and backs off to 30 seconds. Its correctness belongs to the parallel lifecycle branch;
this branch does not edit Supervisor. No indefinite CPU busy loop was observed in native decode on fixtures.
The finite native stream readiness loop is bounded by available audio under the library contract; a faulty
native library or stalled hardware is outside these fixture measurements.

## Method and limitations

Builds use the existing pinned Vendor directory through an ignored symlink. The measured binary is the SwiftPM test helper loading production HeyDotKit, with injectable/fake dependencies, rather than an installed signed app. `swift build` and `swift test`
run from `apps/HeyDot`. The opt-in `resourceProbe` test uses a nonpersistent WKWebsiteDataStore and local
HTML containing a 10 ms timer, requestAnimationFrame loop and CSS rotation. Its navigation delegate
rejects backend reloads after the HTML navigation, so corrected fixture calls never fetch ChatGPT.
Visibility is simulated only in WebKit's isolated client world. The real press, call timeout creation,
hang-up, panel teardown and SwiftUI popover are exercised, but no media capture starts.

Run: `HEYDOT_RESOURCE_PROBE=1 /usr/bin/time -l swift test --filter resourceProbe`.
`HEYDOT_RESOURCE_IDLE_SAMPLES=0` skips only the ten 30-second idle samples for the separate baseline cycle run.
The baseline uses production sources archived from `7a750c0` plus the same fixture, without the new
PopoverActivity binding or the new regression tests. The patched fixture supplies the live visibility binding.

Mach task_info measures RSS and task_threads counts/deallocates its returned ports. getrusage CPU deltas
measure percent of one core over each phase (100% = one saturated core). top separately samples the test
process and its WebKit GPU/WebContent processes every 30 seconds. GPU-process CPU is not GPU utilization.
`powermetrics -n 1 -i 100` returned `powermetrics must be invoked as the superuser`; no sudo was used.
The machine had concurrent builds and substantial system load. These debug-fixture numbers are not
release-binary energy benchmarks. `/usr/bin/time` includes SwiftPM/build children, so its peak RSS is not
HeyDot's RSS; use the per-process Mach measurements below.

The original idle probe completed all five idle minutes, then was terminated because real WebKit
occlusion prevented the fixture's simulated presses from completing promptly. Those five-minute idle
samples remain valid. Its incomplete call cycle data is excluded. The corrected baseline cycle run
completed all 50 presses. An early patched probe was likewise stopped to correct the fixture.

Twenty workspace wake/configuration notifications are included in the process probe. The separate
`twentyWakeDeviceCyclesKeepOneCaptureAndRemoveObservers` regression drives a fake capture, real
ListenerSupervisor, default-input callback and matching configuration notifications through twenty
coalesced restarts, verifying one live capture and observer removal on stop. This is not a hardware
sleep/wake, default-device switch or microphone benchmark.

## Measurements

All memory figures below are native test-process RSS, in MiB (1,048,576 bytes).
The first snapshot CPU is excluded because it includes process startup over a short interval.

| Phase | Before: CPU / RSS / threads | After: CPU / RSS / threads |
| --- | --- | --- |
| Five-minute idle end | top 0.0% sampled / 83.8 / 7 | 0.0012% last 30 s / 85.5 / 6 |
| Ten calls | 8.06% / 85.7 / 16 | 26.69% / 93.0 / 16 |
| Fifty calls | 7.06% / 86.0 / 15 | 33.05% / 94.6 / 17 |
| 100 popover opens/closes | 65.72% / 125.4 / 15 | 59.14% / 128.6 / 13 |
| Twenty wake notifications | 76.31% / 125.7 / 15 | 10.90% / 128.6 / 13 |
| Closed settle, 35 s | **72.07% / 124.9 / 8** | **0.156% / 127.2 / 7** |

The native process starts at about 84 MiB for both cycle runs. Baseline idle top samples were 0% until
the cycle phase; the 11-sample trace includes one initial cycle sample (0.5% native / 0.4% WebContent).
Patched idle top samples show 0% native CPU and eventual disappearance of its fixture WebContent/GPU
processes. WebKit may retain shared processes in other configurations; this code releases the views,
not private WebKit processes. A separate baseline with no WKWebView still measured **59.33% CPU** in
the closed settle period (105.3 MiB, four threads), supporting the TimelineView finding independently.
Patched top during the cycle settle sampled 0.0% native CPU, while the more precise getrusage phase
average above includes brief cleanup work.

There is **no measured native memory saving**: settled RSS is 2.3 MiB higher after the patch. Fifty view
recreations also cost more transient CPU than retaining one warm page (about 27–34% versus 7–8% during
these rapid synthetic call batches). That is the explicit teardown/cold-start tradeoff. These short
runs do not prove a native leak or establish a long-run memory bound; RSS includes framework caches
and first-use SwiftUI allocation. They do demonstrate the closed-state CPU regression is removed in
this fixture. All fifty corrected presses succeeded on both versions.

Raw compact task snapshots and top rows, base SHA, probe hash and units are preserved in
[`resource-measurements.json`](resource-measurements.json). Compile output, temporary baseline source
copies and intermediate builds are reproducible and removed after validation.

## Validation and integration

`swift build` passed; `swift test` passed all 61 tests (10 WakeEngine, 51 HeyDot). The corrected opt-in cycle probe passed separately.

Regression checks cover log size (including an oversized existing file), last-viewer timer cancellation,
usage owner release, idle expiry, fifty detach/recreate cycles and twenty supervisor event cycles.
The opt-in probe asserts fifty successful simulated presses and performs one hundred real NSPopover opens/closes.

Potential overlap: functional branch may touch AppDelegate, PopoverView, WebCallBackend and uninstall;
lifecycle branch also touches AppDelegate and Uninstall. Integrate by behavior, preserving the
resource idle policy, source-view identity guard, frame/capture grant rules, and both branches' changes.
The resource lane changes no microphone grant, sign-in, entitlement, sandbox, origin or network policy.
Uninstall removes the new archive alongside the current log unless --keep-logs is set; this is a separate-line overlap with the lifecycle uninstall guard.

Flagged, unchanged security-adjacent issues: microphonePermission synchronously waits for a permission
answer with no timeout; URL intake checks host without requiring HTTPS; the capture grant helper checks
frame origin host but does not explicitly require frame.isMainFrame. These need a separate security/UX
review rather than an incidental resource-policy change.

Unverified: actual signed-in ChatGPT animation/video/timer load, real call/media shutdown and mute,
transparent-window GPU watts/compositor cost, microphone conversion/decode cost on live hardware,
physical sleep/wake and device changes, power consumption, and model lifetime under prolonged native inference.
No actual leak-free or battery-life claim is made from fake calls. Cold calls after the 30-second expiry
must load the page again, trading startup latency for a bounded idle lifetime.
