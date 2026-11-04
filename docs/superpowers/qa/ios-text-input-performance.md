# iOS simulator native text input verification

2026-11-04, Apple Silicon, Xcode 27 / iOS 27.0. All interactive checks used the dedicated `Tandem-Text-Latency` simulator (`F6C0062B-FCCD-4EE4-910F-8683C7D7000F`), with its inherited Zhuyin keyboard and disconnected hardware keyboard. No keyboard/language preferences were changed and the user's active simulator was not controlled.

## Behavior and implementation

The host starts one session-owned `tandem-simulator-text` guest process in parallel with video startup. The guest loads AXRuntime and inserts literal Unicode into the actual focused editor. Ordinary `text` requests do not use a clipboard, subprocess, edit menu, or whole accessibility tree. A single read-only startup preheat does not activate an app or alter selection.

The guest confirms the resulting UTF-16 caret location. A rejected or transformed edit returns `UNSUPPORTED` with an uncertain-delivery message; it does not disconnect a healthy session or replay the edit. Transport failures terminate the connection and never retry text. The pipe writer is nonblocking, runs off MainActor, and is cancellable even if the guest stops reading.

Secure text fields advertise AX's secure trait. The guest detects that trait **before** attempting an edit and returns `NATIVE_PASTE_REQUIRED`; only this response permits the host to use the existing system Paste menu. Other uncertain failures never fall back. Explicit `clipboard_set` still uses the existing verified simctl/CoreDevice clipboard backend; `paste: true` writes the clipboard and then invokes native literal insertion (or secure system Paste). Literal insertion does not add UIKit Paste smart-spacing.

ApplicationAccessibility is enabled only when needed, and its original state is restored on quit, EOF, or SIGTERM. The guest is a session process rather than an installed service or code injected into the tested app. Unsupported guest startup does not prevent video/touch from connecting; only text requests report that failure.

## Measured latency

UIKit timing comes from the fixture's actual text-change delegate, or WKWebView's JavaScript `input` callback, using the shared monotonic clock. ACK timing covers the full host JSON RPC. Tests verify exact actual text, rather than treating an RPC success as evidence of insertion.

| Scenario | Samples | Actual change, median / max | Full RPC, median / max |
| --- | ---: | ---: | ---: |
| Warm ASCII, consecutive characters | 35 | 7.32 / 18.64 ms | 12.15 / 37.47 ms |
| Warm Chinese + emoji | 2 | 14.05 / 19.30 ms | 20.69 / 26.80 ms |
| Cold Chinese + emoji after fixture process restart | 2 | 316.08 / 338.94 ms | 329.17 / 349.03 ms |
| Cold ASCII after fixture process restart | 1 | 372.16 ms | 382.68 ms |
| Selection replacement, new UITextView/UITextField processes | 2 | 318.82 / 321.23 ms | 332.43 / 333.60 ms |
| Chinese + emoji + newline, new UITextView process | 1 | 370.91 ms | 382.89 ms |
| WKWebView textarea, exact text and real input event | 1 | 265.17 ms | 287.94 ms |
| Secure UITextField, system Paste fallback | 1 | 2809.73 ms | 3325.51 ms |

The previous unmodified helper was also measured on the same fixture and simulator: ASCII, Chinese/emoji, and multiline insertion took **3056–3217 ms end to end**, with the actual text changing after **2600–2746 ms**. The warm path meets the interaction target; the first insertion into a newly launched app still pays a roughly 300 ms accessibility initialization cost. Secure-field fallback retains the slower existing menu behavior. Flutter and other custom text controls were not tested.

## Verification

- Full helper suite: 18 XCTest tests and 2 video Swift Testing tests passed.
- Real UITextView and UITextField: Chinese, emoji, newlines where supported, exact UTF-16 selection replacement, consecutive letters/digits.
- UITextField delegate rejection: no text change, explicit `UNSUPPORTED`, and subsequent insertion in the same helper session succeeds.
- WKWebView textarea: Chinese, emoji, newline, exact DOM text, and an actual JavaScript `input` event; no HTTP server.
- Secure UITextField: preflight returns `NATIVE_PASTE_REQUIRED` without changing the real field; full host fallback inserts the exact requested value.
- Guest lifecycle: original AX false/true × quit/EOF/SIGTERM, 6/6 passed.
- Full host → simctl → guest lifecycle: original AX false/true × host quit/EOF/SIGTERM/SIGKILL, 8/8 passed. Each check confirmed that the observed guest PID disappeared and the original AX state was restored.
- Pipe regressions: already-cancelled input sends nothing; large writes to a stopped reader time out or cancel without blocking MainActor; close reaps the child; EOF and unsupported startup preserve explicit failure semantics.

## Reproduction

Build the host/guest bundle with `scripts/build-simulator-helper.sh OUTPUT_DIR`. The guest is compiled for `arm64-apple-ios17.0-simulator`; AX selectors are checked at runtime. In a signed app, the guest is placed under `Contents/Resources/Simulator/`.

Build the test app with `Packages/SimulatorHelper/Tests/Integration/build-text-fixture.sh OUTPUT_DIR`, then install `TextFixture.app` on a dedicated simulator. Run:

```sh
python3 Packages/SimulatorHelper/Tests/Integration/text-input.py OUTPUT_DIR/tandem-simulator SIMULATOR_UUID --host
```

The integration runner creates and drains a private video socket automatically. The fixture source, guest-only runner, AX-state observer, guest lifecycle runner, and full host lifecycle runner are in the same integration directory. Compile `AccessibilityState.m` as an arm64 iOS Simulator executable for the lifecycle runners. Never substitute `booted` for the dedicated UUID.
