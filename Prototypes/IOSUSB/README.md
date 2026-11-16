# iOS USB native-service prototype

Independent diagnostic prototype for an iOS 27 iPhone connected to a Mac over
USB. The independent tools can run without Tandem. Tandem's experimental
`IOSPhysicalDriver` also reuses this backend, with native VideoToolbox HEVC
decoding instead of the standalone viewer's FFmpeg conversion.

The experiment keeps **one** CoreDevice displayservice media session alive,
receives and depacketizes its HEVC video, and sends UniversalHID contact/release
reports over the same device tunnel. It tests whether continuous video can stay
active during live mouse-driven input. No iPhone app, XCTest Runner, loopback VPN
or persistent host service is installed.

## Requirements

- A trusted, unlocked USB iPhone with Developer Mode enabled.
- Xcode with a compatible developer disk image (DDI). The preparation script
  asks `devicectl` to check and mount that image.
- Rust/Cargo, Swift/Xcode command-line tools and FFmpeg. FFmpeg is expected at
  `/opt/homebrew/bin/ffmpeg` by default; the viewer also accepts `--ffmpeg`.
- The backend pins the MIT-licensed `idevice` revision used by the source study.
  Dependency source and build products stay under ignored `build/ios-usb-native`.

## Build and run

From the repository root:

```sh
Prototypes/IOSUSB/scripts/build.sh
build/ios-usb-native/tandem-ios-usb --list
Prototypes/IOSUSB/scripts/prepare-usb.sh IPHONE_UDID
Prototypes/IOSUSB/scripts/run-viewer.sh IPHONE_UDID
```

The viewer starts in **View Only** mode. Once the phone's image appears, disable
View Only to send mouse down/move/up. Touches map into the aspect-fitted video,
with top-left origin and normalized coordinates; letterboxing cannot start a
touch. Losing focus releases the viewer's owned contact. Closing the window
stops and reaps its backend and FFmpeg children.

The preview uses FFmpeg to convert HEVC to JPEG for a small AppKit viewer. It is
an interoperability test, not a benchmark of a future VideoToolbox renderer.
Do not open the standalone viewer and Tandem's mirror for the same phone at the
same time: they would compete for the device's screen-sharing session.

## Measurement

Observe decoded video without sending touches:

```sh
Prototypes/IOSUSB/scripts/validate-usb.py --udid IPHONE_UDID
```

For input/video overlap, first put the iPhone on the **Settings main list** and
close the viewer so it does not hold another media session. This command sends
six alternating vertical gestures, with move events scheduled at 60 Hz:

```sh
Prototypes/IOSUSB/scripts/validate-usb.py --udid IPHONE_UDID --exercise
```

The result is written to ignored `build/ios-usb-native/validation.json`. It
records decoded frames, unique-frame comparisons, frames during active touch,
frame arrival gaps, command acknowledgement timings and exit results. It keeps
no screen images or video. A transport acknowledgement only proves that the
HID report was sent; visible UI response must also be checked. Frame hashes
changing during a test are supporting evidence, not an application-level success
claim.

Add `--framed-video` to exercise the TUV1 access-unit protocol consumed by
Tandem. This validates packet lengths, timestamps and complete encoded frames
in addition to decoded video and touch overlap.

Runtime viewer diagnostics are in
`build/ios-usb-native/viewer-backend-metrics.ndjson`. Pairing records stay in the
system's existing pairing store and must never be copied into this repository.

## Native text input

The backend accepts these stdin NDJSON commands while its media session is open:

```json
{"id":1,"op":"text","text":"中文 ASCII 😀"}
{"id":2,"op":"key","key":"enter"}
```

Text uses the phone's native CoreDevice pasteboard service and HID Command+V,
so Chinese and emoji do not depend on the selected hardware keyboard layout.
It **replaces the iPhone's general clipboard**. Focus an editable field first;
secure fields and apps that block paste may reject insertion. Optional
`"submit":true` presses Return after pasting; omission leaves submission to the
caller. No application or Runner is installed. Public clipboard read/write is
not exposed by this prototype's command protocol.

Text must contain 1–8192 UTF-8 bytes and no NUL. Supported key names are `enter`,
`delete` (Backspace), `tab`, `escape`, `left`, `right`, `up`, `down`, `home` and
`end`. Text transport is bounded to five seconds, followed by at most 1.5 seconds
of best-effort key release. Shutdown cancels the outstanding text/key request
and releases held keys. Failed or uncertain insertion is never replayed.
Acknowledgements contain byte counts and transport status, not the text.

`--probe --udid IPHONE_UDID` reports native text service advertisements without
reading or changing the clipboard or pressing keys. `ready.text` has this same
advertisement scope; actual service connection and authorization are attempted
only on the first text command. Missing text support does not stop video or
touch. A successful text acknowledgement confirms clipboard SET and HID writes;
verify the target field visually before claiming insertion succeeded.

See [VALIDATION.md](VALIDATION.md) for the actual acceptance result and limits.
