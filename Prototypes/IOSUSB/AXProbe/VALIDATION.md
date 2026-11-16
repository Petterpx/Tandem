# Native AX feasibility — 2026-11-15

## Result

On the connected iPhone 17 Pro running iOS **27.0.1 (24A446)**, the native
Accessibility Audit service provides fast element descriptions and some child
relationships. The tested interface does **not** provide a complete, passive,
positioned UI snapshot suitable for Tandem's element actions. Production
`.uiTree` remains disabled for physical iPhones.

The experiment does not require an iOS runner. It used the existing USB pairing
and ran alongside Tandem's existing native video/HID session. No persistent
accessibility setting was changed, and no messages were sent.

## Physical-device observations

| Probe | Observed result |
|---|---|
| Direct USB service | `com.apple.accessibility.axAuditDaemon.remoteserver` connected successfully. |
| Authentication | Lockdown requests service SSL; TLS 1.2 authentication followed by plain DTX works. The paired device certificate is pinned. |
| DTX startup | Skip Instruments' published-capabilities handshake; invoke selectors on the control channel. |
| Cold connection and capability query | About 0.54 seconds in the initial Python probe; later connection setups were about 0.38–0.41 seconds. |
| Device API version | `deviceApiVersion` returned 26 on this iOS 27 device. This is the daemon API version, not the OS version. |
| Element properties | `Label`, `Value`, `Identifier`, `Traits`, and `TraitsHumanReadable` returned supported values. Typical property RPCs took about 2–10 ms. Missing values remained missing. |
| Hierarchy | `_AXHierarchyElementsAttribute` returned `AXAuditNode_v1`; some Home icons, folders, and Settings rows had real `ChildrenValue_v1`. Leaves had no children field. Minimal and full attribute metadata gave equivalent results in sampled nodes. |
| Geometry | `Frame`, `AXFrame`, `Rect`, `Bounds`, `Position`, `Size`, and related tested names returned null. No usable coordinate getter was established. |
| Navigation | Inspector Next moves typically took about 20–70 ms. One target search visited 37 nodes in 1.40 seconds; another visited 27 in 1.06 seconds, including label reads. These are bounded walks, not full-tree timings. |
| Completeness | On Settings search's empty-results page, Next cycled through only three result-placeholder elements. The visible search field and close button were missing. A separate Last lookup could find a keyboard element. |
| Side effects | Inspector navigation can scroll the app and draw a green focus rectangle, even after visuals were disabled before walking. It cannot be treated as passive observation. |
| Native activation | With a freshly focused Settings row labelled `外观`, canonical element serialization, `AXAction-2010`, `PerformsActionValue_v1=1`, and a null action value, the request was written successfully. An immediate independent video-frame screenshot after 0.6 seconds still showed the Settings home list; the Appearance page did not open. A prior Battery activation attempt also did not establish successful navigation. |
| Cleanup | After walking stopped, ShowVisuals false, monitoring false, Inspector false, and connection close were sent. An independent screenshot confirmed the focus rectangle had disappeared. |

`deviceFetchSpecialElement:` accepts integer 0 / 1 and returned first / last
element handles in this test. These are not application-root enums. Platform
element bytes are transient handles; they are not stable app accessibility IDs.
The absence of a children field does not establish that a UI subtree is empty.

## Why activation and bounds cannot be assumed

The installed Xcode Accessibility Inspector and the **local iOS 26.5 Simulator
runtime's** `axauditd` were inspected without running the Inspector UI. This is
supporting implementation evidence from a different OS build, not a substitute
for the physical iOS 27 results above:

- Activation checks `allowDeveloperActionsOnElement:` and
  `_AuditDoesAllowDeveloperAttributes(pid)` before dispatching an AX action. A
  rejected action can complete silently. A DTX write is not proof of a click.
- Property reads use an explicit name whitelist; the inspected implementation
  has no generic Frame/AXFrame/Position branch. The parameterized getter returns
  null.
- The inspected Next/Previous path ignores the include-containers and non-AX
  flags. First/Last use a different path, consistent with the observed traversal
  gap. This does not prove the implementation is identical on iOS 27.
- Focus updates redraw the cursor without checking the show-visuals flag.
  Disabling Inspector alone does not hide it. ShowVisuals false after the final
  focus update and disconnect cleanup are necessary.

No attempt was made to bypass a target application's entitlement checks.

## Consequences for the assistant

Adding this partial walk to every model turn would add observation cost while
still needing screenshots for missing controls and HID coordinates. It would
also disturb the screen. It therefore does not justify enabling Tandem's
existing `get_ui_tree` / indexed tap path for physical iPhones.

The prior 35.7-second Settings task spent 11.142 and 8.691 seconds on its two
action decisions and required a third model turn for final visual verification.
Fast property RPCs alone do not remove those decisions.

The subsequent external observation experiment was removed at the user's
request. Tandem currently retains native video, native input, and screenshot
observation; no additional observation service is integrated.

## Evidence and reproducibility

The independent Rust CLI and its offline tests are in this directory. The
prototype uses the existing pinned MIT `idevice` implementation. Python was
used only in an isolated, ignored research virtual environment; it is not a
runtime dependency of Tandem.

The final Rust smoke test passed direct USB metadata, first/last handles, one
focus step, and both hierarchy wrappers. The focused hierarchy contained four
real nodes in each mode; the unfocused special handles supplied no hierarchy.
All three cleanup writes succeeded, and an independent screenshot confirmed
that no cursor remained. Six Rust offline tests and the Swift guarded-plan
fixtures passed. No production app code changed for this AX experiment.

One earlier repeat connection failed with `InvalidContentType` before metadata
output; the failure's exact TLS phase was not captured. Phase-only diagnostics
were added without logging credentials or changing handshake behavior. The
same smoke test and three subsequent metadata-only connections succeeded.
The cause remains unresolved; a TLS/plaintext boundary race is a hypothesis,
not an established diagnosis. These short probes do not establish connection
reliability, and the CLI does not automatically retry.

Private NDJSON and screen images remain under the ignored
`build/ios-usb-native/` directory:

- `ax-rust-probe.json`: native Rust service and metadata result.
- `ax-rust-final.jsonl`: final Rust hierarchy and cleanup smoke test.
- `ax-repeat-{1,2,3}.jsonl`: subsequent successful metadata-only connections.
- `ax-hierarchy-probe.jsonl`: Home focus, attributes, and minimal/full hierarchy.
- `ax-settings-hierarchy.jsonl`: incomplete Settings-search traversal.
- `ax-focus-probe.jsonl`: first/last handles and explicit focus reads.
- `ax-settings-root.jsonl`: Settings rows and real child relationships.
- `ax-safe-activation-immediate.jsonl`: safe Appearance navigation request.
- `ax-native-activate-immediate.jpg`: no navigation after that request.
- `ax-cleanup-confirmed.jpg`: independent confirmation of overlay cleanup.
- `ax-rust-cleanup-confirmed.jpg`: cleanup confirmation after the Rust probe.

These recordings may contain private screen text and must not be committed.
