# Simulator helper

`tandem-simulator` is a per-device child process of Tandem, with JSON-lines on stdin/stdout for control and a private Unix socket for binary video. There is no TCP listener or persistent service installation. Closing the stream or sending `quit` releases the owned contact and exits; the simulator remains booted. The session also owns a guest text process launched through `simctl spawn`.

The main app and TandemCore retain macOS 14 support. This optional backend requires Apple Silicon, macOS 15 or later, Xcode and an installed iOS simulator runtime. It uses private Xcode APIs through Meta's FBSimulatorControl **1.7.7**, pinned exactly in `Package.resolved`; future Xcode updates may require an idb update. Intel builds skip the helper and retain Android functionality.

Build from the repository root:

```sh
scripts/build-simulator-helper.sh /path/to/destination
swift test --package-path Packages/SimulatorHelper
# Optional: sends a touch and temporarily writes/restores the device clipboard.
python3 Packages/SimulatorHelper/Tests/Smoke/simulator-smoke.py /path/to/destination/tandem-simulator SIMULATOR-UUID
```

The destination contains the host helper, the iOS 17+ simulator text binary, `CoreSimulatorStub.framework`, `AccessibilityPlatformTranslationStub.framework` and third-party licenses. Inside an `.app`, notices are written to `Contents/Resources/SimulatorLicenses` and the guest binary to `Contents/Resources/Simulator`. The framework re-exports the copy of CoreSimulator installed by Xcode. The build script adds an executable-relative framework runpath and signs the local binaries; no `DYLD_*` environment is required. Distribution should sign bundled code with the application's signing identity. No idb command-line installation is required.

Every input RPC is acknowledged after native transport delivery. Human touch events share one continuous HID operation: movement does not repeat display routing or drain on each event. Taps settle before text, and keys, AI input and shutdown finish or cancel the human operation before acquiring HID. A display change cancels the bound operation and releases its original contact; uncertain input is never replayed. `finger` and `ai` share one native contact: while one owns it, the other receives `AI_LOCKED`, and cannot move or release it. Coordinates are normalized against the displayed, rotated screen. Full-resolution PNG screenshots remain a `simctl` responsibility.

Preview frames follow native framebuffer completion events. CoreImage snapshots rotation and scaling into owned NV12 buffers, then VideoToolbox performs hardware H.264 encoding with at most two frames in flight and one replaceable pending source. Preview long edge is at most 1920 pixels, targeting 60 fps. The App supplies `TANDEM_VIDEO_SOCKET` in a private, per-generation temporary directory; video packets have a 16-byte header (`TDV`, version 1, big-endian UInt32 payload length and UInt64 encoder-output uptime in microseconds) followed by one complete Annex-B access unit. The App decodes every packet in order and retains only the newest decoded frame for display. Slow readers fail within a bounded interval without dropping dependent encoded frames. Socket and directory lifetime belongs to the session.

Boot the device headlessly. Simulator/DeviceHub can take ownership of a displayed device's framebuffer. The helper never closes those windows. If a framebuffer cannot be obtained, it returns an error asking the user to close that device's window and reconnect. Other devices and simulator windows can remain open.

Ordinary text uses the session-owned guest process and AXRuntime to insert Unicode into the current editable first responder, preserving the selection and caret. It does not change keyboard/language preferences, install into the tested App, export a UI tree, or write the clipboard. The guest temporarily enables ApplicationAccessibility only when needed and restores the original state on quit, EOF and SIGTERM. Startup warms the guest once; each new foreground App can still have a cold accessibility lookup. Delivery errors are never automatically replayed.

Secure fields are identified before insertion and use the native edit-menu Paste fallback. This path checks that the menu is native and newly presented; UIKit's smart spacing and paste permission prompts still apply, and it takes longer than ordinary typing. Custom controls which cannot confirm insertion fail explicitly. Explicit clipboard writes continue to use the checked system clipboard backend; paste then uses the text path or secure fallback.

Clipboard writes are checked by exact UTF-8 readback. When CoreDevice owns the pasteboard, the helper uses `devicectl device pasteboard` instead of trusting simctl's cached snapshot. Cooperating helpers serialize clipboard writes and secure pastes with a same-user, 0600 `flock`, retained through paste completion. Explicit clipboard writes and the secure fallback replace the simulator clipboard; CoreDevice clipboard sharing can also affect the host clipboard. Other applications can still copy independently, so the fallback verifies again immediately before delivery.

The helper does not log text or clipboard contents. Dependency notices are in [Licenses](Licenses/).
