# USB prototype acceptance — 2026-11-15

The shared-media-session approach passed the initial physical-device test.

## Native accessibility follow-up

The native AX daemon connected on the same iOS 27.0.1 device and returned fast
element labels and partial child relationships. The tested inspector interface
missed visible search controls, returned no usable bounds, could scroll/highlight
the page during traversal, and did not activate a safe Settings navigation row.
It is not enabled as a production UI-tree capability. See the
[AX feasibility record](AXProbe/VALIDATION.md) for measured results, cleanup,
implementation evidence, and the next experiment.

## Native Unicode input and phone assistant

The same iOS 27.0.1 phone passed native pasteboard SET plus Indigo Cmd+V input.
The assistant entered `Tandem中文A1😀` into Settings search in one `type_text`
operation. It handled the first Allow Paste dialog itself, then verified the
whole string on the next screenshot. The final test completed three actions in
39.7 seconds (including model inference), with no setting changes. The final
phone frame was independently inspected; the exact Chinese/ASCII/emoji query
was visible. The ignored evidence is `iphone-text-live-final.log` and
`iphone-text-final.jpg` under `build/ios-usb-native/`.

A separate real-model check used a synthetic chat screenshot, with a specified
recipient and message already filled. It selected the Send button instead of
requesting redundant confirmation. This check executed no device action and
sent no real message. Offline tests cover Unicode/escaped-byte limits,
keyboard cleanup, text/gesture exclusion, and cancellation without replay.

### Performance follow-up

Measured model decisions took about 8–10 seconds per action in the Settings
sample, while native text writes took 0.05–0.13 seconds before permission
handling. Native launch was 5.94 seconds on a cold request and 0.96 seconds on a
later request. These are single-device observations, not latency guarantees.

The implementation now preloads the native app directory, launches by actual
bundle ID, combines focus with text entry, and supports Cmd+A replacement.
SET is read back before any paste shortcut; a mismatch fails without replay.
The app records separate planning and execution durations.

An initial OCR implementation was too slow on this Mac. The bounded replacement
uses Vision revision 2 on the cropped, scaled dialog region. A real private
iOS 27 paste-dialog image was recognized in **0.305 seconds**, with the Allow
button at approximately `(0.313, 0.571)`. The exact Simplified Chinese dialog
wording was added to the matcher. A 600 ms OCR deadline and single-worker guard
prevent delayed recognition from issuing an input. Offline timeout, cancellation,
geometry and real-fixture tests passed.

After the user unlocked the phone, the final full-device speed check passed:
native launch plus one whole-text replacement completed the same class of
Settings search task in **2 actions / 35.7 seconds**, compared with the earlier
8-action / 98.2-second sample. Launch took **0.862 s** and replacement including
automatic paste permission handling took **0.774 s**. The two action decisions
took **11.142 s** and **8.691 s**; the final visual verification required another
model turn. This is one test, not a general speed guarantee. The final image was
independently checked: the field contained `Tandem快测F6🌈` with no old text
appended and no dialog left open. Evidence remains local in the ignored build
directory: `phone-agent-unlocked-speed.log`, `iphone-unlocked-speed.jpg`, and
`unlocked-speed-frames/`.

## Setup

- iPhone 17 Pro (`iPhone18,1`), iOS **27.0.1** (`24A446`), portrait.
- Apple Silicon Mac, macOS 27.0.1, USB transport verified by CoreDevice.
- Developer Mode enabled; DDI `27A9275`, compatible and usable.
- `idevice` pinned to `89702099f4d7552f704f93b4526756abda319ceb`.
- One displayservice media session; HEVC reception and UniversalHID input used
  that same session throughout each run. No Runner or phone-side app installed.

## Decoded-video and live-touch result

The final headless run discarded one second of decoder warm-up, then measured
15 seconds while sending six alternating vertical drags in the Settings main
list. Each drag lasted about 600 ms with 36 move reports scheduled at 60 Hz.

| Observation | Result |
|---|---:|
| First decoded frame after process start | 880.51 ms |
| Decoded frames in measurement window | 857 |
| Measured decode rate | 57.11 fps |
| Frame interval, median / p95 / maximum | 16.68 / 23.39 / 57.27 ms |
| Frame intervals over 100 ms | 0 |
| Decoded frames during active contacts | 210 |
| Decoded frames per drag | 36, 35, 34, 35, 34, 36 |
| Distinct decoded frames per drag | 17, 35, 34, 35, 34, 36 |
| Touch requests / acknowledgements | 228 / 228 |
| Rejected or unacknowledged input | 0 |
| Host command acknowledgement p50 / p95 | 0.183 / 0.272 ms |
| RTP sequence gaps | 0 |
| Backend / decoder exit status | 0 / 0 |
| Media stop acknowledged | Yes |

Command acknowledgement timings measure the host pipe and service write only;
they are **not** touch-to-photon latency. Decode rate is also not a guarantee of
monitor presentation rate.

An earlier run measured 55.32 fps and included one 729 ms frame gap. The later
run above had no such gap. These short runs do not establish long-run latency
or stability guarantees.

## Input effect and cleanup

Separate frame captures before a drag and halfway through it visibly showed
the Settings list moving **before the release report**. This checks that
contact/move is acted on continuously, rather than replayed after mouse-up.
Those screen images remain local in the ignored build directory.

A control-channel EOF while a contact was held produced
`touch_cleanup: sent=true, reason=stdin_eof`, followed by a successful media
stop and exit 0. A new session then worked. Physical cable removal was not
performed; cleanup after a transport loss is necessarily best effort.

The independent AppKit viewer received and decoded thousands of live frames.
Its offline tests cover JPEG fragmentation, aspect-fit coordinate mapping and
ordered/coalesced mouse events; a real encoded HEVC fixture produced 60/60 JPEG
frames. Desktop automation could enumerate the running viewer but failed to
capture its window (`-10005`), so desktop mouse automation was not used as
evidence. Live-touch evidence above comes from the backend and phone stream.

## Local evidence and scope

Ignored files under `build/ios-usb-native/`:

- `touch-concurrency-final.json`: final metrics above.
- `touch-concurrency.json`: earlier run, including its long frame gap.
- `eof-cleanup.json`: held-contact EOF cleanup result.
- `gesture-before.jpg`, `gesture-mid-contact.jpg`, `gesture-after.jpg`:
  visual phone-side input confirmation; not committed.
- `viewer-backend-metrics.ndjson`: independent viewer pipeline diagnostics.

## Tandem driver integration

An experimental `IOSPhysicalDriver` was added after the prototype passed. It
uses TUV1 framed HEVC access units and native VideoToolbox decoding, sharing the
same long-lived backend between the workspace and MCP input.

- TUV1 + FFmpeg acceptance: 744 access units decoded, zero framing errors or
  dropped access units, video present during all six gestures, 228 input ACKs.
- Native `DeviceSession` acceptance: 118 decoded CVPixelBuffers over two seconds;
  16 and 12 decoded frames while two contacts were actively dragged. The test
  then stopped and restarted the same cached session, checked the replacement
  event subscription and current `.running` dimensions, and stopped cleanly.
- Core regression: the full `swift test` run passed across seven test targets
  (430 reported tests; hardware tests are disabled without explicit opt-in
  environment variables).
- App regression: 35 tests in five relevant suites passed, including physical
  screenshot acquisition, driver isolation, simulator commands, input queuing
  and MCP capability routing.
- App-level MCP acceptance passed through the bundled helper: USB discovery,
  screenshot, tapping Settings from App Library, and a 600 ms swipe followed by
  another screenshot. The resulting phone images visibly confirmed both the
  app launch and Settings list movement. Unsupported system-original screenshot,
  UI tree and Enter requests returned explicit `UNSUPPORTED` results.
- An earlier attempt encountered CoreDevice error 9022 (phone/VoIP call in
  progress). The backend now attempts audio once and continues with video if
  audio is unavailable; video failure still cleans up and fails. Error handling
  extracts readable descriptions instead of dumping archive bytes. Eight Rust
  tests passed, including call-state and socket-error formatting. The final
  app acceptance succeeded after this change; call-state fallback itself was
  not isolated as a controlled physical-device test.

This establishes feasibility for this USB device and OS build. Landscape,
rotation during a gesture, Wi-Fi, additional devices, long-duration stress,
text/clipboard and application management are outside this test. The encoded
stream is 1216×2656 while CoreDevice reports a 1206×2622 native display;
right/bottom padding was observed, and exact edge targeting/content-rect
calibration remains unverified. The current acceptance exercises the central
content area, using normalized coordinates.

The local built application is `build/ios-usb-native/Tandem.app`; it bundles the
native helper and MIT notice, and does not bundle FFmpeg. The acceptance app was
started from that bundle. No release was published.
