# Simulator video fixture

Use a disposable, booted iOS simulator. Never select a simulator containing someone's active work. This fixture requests a 60 Hz display link, animates a cyan rectangle, displays its frame counter, and changes the background every frame. It does not access the clipboard or insert text.

The script only builds an ad-hoc signed iOS 17+ arm64 simulator app:

```sh
fixture_app="$(Packages/SimulatorHelper/Tests/Integration/build-video-fixture.sh /tmp/tandem-video-fixture)"
xcrun simctl install "$TEST_SIMULATOR_UDID" "$fixture_app"
xcrun simctl launch "$TEST_SIMULATOR_UDID" local.tandem.video-probe
```

Leave the animation running long enough for simulator startup work to settle. Close other viewers of this same test device before connecting Tandem. Keep the machine's other work comparable between runs.

Run the decoded-frame benchmark against either a script-built helper or the actual helper inside Tandem.app:

```sh
TANDEM_VIDEO_BENCHMARK=1 \
TANDEM_TEST_SIMULATOR="$TEST_SIMULATOR_UDID" \
TANDEM_SIMULATOR_HELPER="$TEST_HELPER_PATH" \
TANDEM_BENCHMARK_FRAME=/tmp/tandem-decoded.png \
swift test --package-path Packages/TandemCore --filter SimulatorPerformanceLiveTests
```

The test warms the session for two seconds, then observes approximately twelve seconds of animation while sending twenty Enter RPCs. `TANDEM_VIDEO_BENCHMARK` reports actual decoded arrival rate, changing-background samples, frame-interval percentiles, RPC percentiles, dimensions, and encoder-output-to-decoded latency. That latency excludes simulator rendering and encoding. `TANDEM_NATIVE_STATS` reports submitted output counters; they are supplementary and do not replace decoded-frame measurements. The current acceptance floor is 50 decoded frames/s with Enter RPC p95 below 150 ms. For before/after comparisons, keep a copy of the previous helper and rerun the same test; a slow baseline is expected to fail that acceptance assertion.

To exercise portrait/landscape transitions, relaunch with the child environment flag. The fixture requests landscape left, portrait, landscape right, and portrait at 2/5/8/11 seconds:

```sh
xcrun simctl terminate "$TEST_SIMULATOR_UDID" local.tandem.video-probe
SIMCTL_CHILD_VIDEO_PROBE_ROTATE=1 xcrun simctl launch "$TEST_SIMULATOR_UDID" local.tandem.video-probe
```

The benchmark's `dimensions_history` should alternate portrait and landscape without losing the session. Optionally set `TANDEM_ROTATION_FRAME=/tmp/tandem-rotated.png` to save a decoded landscape frame; it may capture UIKit's rotation animation. Restart without the child flag to restore a continuous portrait fixture.

The helper's static-source test submits one synthetic IOSurface, then a final source, with no following render event. This checks that neither frame waits for another submission. Default tests allow scheduling slack; opt into the separate 200 ms cold-first-frame/final-frame performance check with:

```sh
TANDEM_STATIC_LATENCY=1 swift test --package-path Packages/SimulatorHelper --filter staticSource
```

Remove the installed fixture when finished:

```sh
xcrun simctl uninstall "$TEST_SIMULATOR_UDID" local.tandem.video-probe
```

## Scroll input fixture

Use `build-scroll-fixture.sh /tmp/tandem-scroll-fixture`, then install
`/tmp/tandem-scroll-fixture/ScrollFixture.app` on an explicitly chosen disposable
simulator. The fixture records UIKit touch timestamps, pan state, scroll offsets,
display callbacks, and a recovery button. Its event buffer and background writer
are bounded.

`scroll-input.py HELPER UUID OUTPUT_DIR --mode ack-paced` measures native input;
`--warm` reuses the current fixture process after its first table scroll. The
`continuous` and `wheel-pulses` modes deliberately enqueue raw helper commands
without the App's input coalescing and are diagnostic stress cases, not measurements
of the final App input path. Run `scroll-input.py --self-test` to check the evidence
analyzer without touching a device.

The opt-in App suite `IOSScrollLiveTests` exercises the complete hidden
VideoSurfaceView → ScrollGesture → InputRouter → native helper path. Set
`TANDEM_SCROLL_BENCHMARK=1`, `TANDEM_TEST_SIMULATOR=UUID`, and
`TANDEM_SIMULATOR_HELPER=HELPER` in the test host's environment (the corresponding
`EnvironmentVariables` entry in a copied `.xctestrun` file works for
`xcodebuild test-without-building`). It is skipped by default and never posts
input events to the host desktop. Keep cold fixture setup, native touch release,
normal UIKit deceleration, and state-file publication latency separate.

See [scroll regression evidence](../../../../../docs/superpowers/qa/ios-scroll-regression.md)
for the reproduction and acceptance results.

Set `TANDEM_SCROLL_FOLLOW=1` to also measure onset, sustained motion, reversal,
held pauses, and decoded picture changes. `TANDEM_SCROLL_FOLLOW_REPORT_ONLY=1`
records exploratory follow metrics without applying provisional follow thresholds;
the existing actual-release budgets remain enforced. Evidence-file publication
waits are separate from latency assertions based on guest event timestamps.
See [continuous follow evidence](../../../../../docs/superpowers/qa/ios-scroll-follow.md).
