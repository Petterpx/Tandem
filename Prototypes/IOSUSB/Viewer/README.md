# Standalone USB viewer

This AppKit diagnostic app does not link Tandem. It requires macOS 14 or later and FFmpeg with HEVC decoding and MJPEG encoding.

```sh
Prototypes/IOSUSB/scripts/build-viewer.sh
build/ios-usb-native/TandemUSBProbe.app/Contents/MacOS/TandemUSBProbe --self-test
```

Launch the built executable with `--backend /absolute/backend --udid DEVICE_ID`. Optional arguments are `--ffmpeg /absolute/ffmpeg` (default `/opt/homebrew/bin/ffmpeg`) and `--metrics /absolute/events.ndjson`. Paths and device IDs are passed to child processes as argument arrays.

The viewer starts the backend with `--udid DEVICE_ID`. Backend stdin receives NDJSON commands; stdout must contain only Annex-B HEVC; stderr carries NDJSON events or plain diagnostics. Commands use monotonically increasing numeric `id` values. Touch messages carry `op: touch`, `phase: down|move|up` and normalized top-left-origin `x`, `y`. Home sends `op: button, button: home`; shutdown sends `op: stop`. The optional metrics log appends viewer FPS/counts plus backend and FFmpeg diagnostics as NDJSON.

View Only is enabled at startup. Touch and Home require a decoded frame and an explicit change of that switch. A drag must begin inside the aspect-fit image; dragging outside clamps to its edges. Releasing the mouse, disabling input, losing focus, or quitting releases an active touch. The writer coalesces adjacent pending moves while preserving down/up transitions. Parsed frames coalesce before main-thread display to prevent rendering queues from growing.

On close, the viewer releases any touch, sends stop, and closes backend stdin after pending commands. It gives both children three seconds to exit gracefully, sends SIGTERM if needed, then SIGKILL at twenty seconds. This includes the backend's bounded touch-release and media-stop cleanup budget even when SIGTERM starts cleanup. App termination waits for both child processes to exit and finishes immediately when they exit normally. No persistent service is installed.

View updates counts main-thread image assignments per second. AppKit may combine multiple assignments into one draw; this number is not the physical display presentation rate.

The offline self-test checks fragmented/concatenated JPEG streams with real generated JPEGs, image decoding, letterbox coordinate mapping, and touch-command ordering. It launches no window or backend. Physical-device video, touch behavior, and observed latency need a separate authorized device test.
