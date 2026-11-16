# Native AX experiment

Independent Rust executable. It reuses the existing pinned MIT `idevice`
dependency and does not touch the video/HID backend or install an iOS runner.
Direct USB metadata, first/last handles, one focus step, minimal/full hierarchy,
and cursor cleanup have been exercised on the connected iOS 27.0.1 device.
Six offline tests cover protocol and cleanup behavior. RSD remains unvalidated.
See [the iOS 27 feasibility record](VALIDATION.md) for the physical-device
findings and why this is not enabled as Tandem's UI-tree implementation.

```sh
CARGO_TARGET_DIR=build/ios-usb-native/cargo-target cargo build --offline --manifest-path Prototypes/IOSUSB/AXProbe/Cargo.toml
build/ios-usb-native/cargo-target/debug/tandem-ios-ax-probe --help
```

No arguments means no device access. With `--probe --udid DEVICE` it starts
the native AX daemon through the direct USB lockdown service and reads
capabilities/settings. It skips the DTX capabilities exchange for this daemon.
If direct USB requests service TLS, it authenticates with the local pairing
record using TLS 1.2, pins the paired device certificate, and takes the bare
socket back for DTX. Credentials never leave memory or the existing local
pairing store. `--rsd` instead discovers the service through the USB
CoreDevice tunnel and performs the shim's RSDCheckin before DTX.
Output is NDJSON and can include private screen text.
Do not commit captured output.

`--probe --udid DEVICE --walk 60` additionally enables app monitoring and moves
the Accessibility Inspector cursor. **Focus traversal can automatically scroll
the app and briefly show a green highlight**, including when visuals were
disabled before traversal. It is not a pure read operation. It does not activate
elements, enable VoiceOver, or change system accessibility settings.

After a walk or explicit Inspector enable, cleanup sends these commands in order
on success, RPC failure, the 100-second experiment timeout, and Ctrl-C:

1. `deviceInspectorShowVisuals: false` to request cursor hiding.
2. `deviceSetAppMonitoringEnabled: false`.
3. `deviceInspectorEnable: false`.

Disabling Inspector alone does not hide the cursor. The probe keeps the
connection alive for a further 500 ms for asynchronous cursor-frame cleanup.
`cleanup.sent` means the transport write succeeded; neither that event nor the
delay confirms the highlight disappeared. Force-kill/disconnection can prevent
cleanup. Cleanup does not undo automatic scrolling.

Additional opt-in experiments:

```sh
# Read special-element selectors 0 and 1; do not move inspector focus implicitly.
build/ios-usb-native/cargo-target/debug/tandem-ios-ax-probe --probe --udid DEVICE --special 0,1 --hierarchy minimal

# Compare the small attribute wrapper with full metadata supplied by a focus event.
build/ios-usb-native/cargo-target/debug/tandem-ios-ax-probe --probe --udid DEVICE --walk 1 --hierarchy both --inspector-enable
```

`--special 0,1` sends `deviceFetchSpecialElement:` with NSNumber 0/1 only when
requested. These have been identified as first/last selectors by static protocol
research; the probe does not assume they return root application elements.
`--hierarchy minimal|full|both` reads `_AXHierarchyElementsAttribute` through
`deviceElement:valueForAttribute:` on the selected element. Minimal sends the
attribute name; full sends the original `AXAuditElementAttribute_v1` from the
focus event, retaining `DisplayAsTree_v1` and all unknown metadata unchanged.
If no full metadata was supplied, it emits `hierarchy_skipped` instead of guessing.

Hierarchy output retains the raw response and normalized node records. Only an
explicit `ChildrenValue_v1` establishes parent-child paths. Absent children are
`not_provided`, not proof of a leaf; unknown fields remain in `fields` and raw
output. A native `AXAuditNode_v1` can represent a single node. Bounds, application
identifiers and a complete tree are never fabricated.

`--inspector-enable` explicitly enables the transient Inspector, then attempts
to disable it during cleanup. This does not restore an unknown prior enabled
state; do not run it alongside another Inspector client. Without this option the
probe does not enable Inspector; a walk still sends the three cleanup commands
above. The visual-overlay setting is disabled during this cleanup.

This is a **bounded sequential focus walk**, not a complete UI tree snapshot.
It stops on the first repeated platform identifier or its limit. Platform
identifiers are session handles, not guaranteed stable accessibility IDs.
Each requested attribute requires one RPC while its element is focused;
`Frame` and `Traits` support, coordinates, labels and app `Identifier` values
must be checked on the actual device. Missing attributes do not prove absence
of a screen control. No parent-child hierarchy is inferred. Some UI frameworks
or inaccessible custom drawing may expose little information.

The daemon's activation selector is intentionally absent. The upstream Python
API documents activation as requiring `task_for_pid-allow` on the target;
existing HID remains the candidate action path if normal apps reject AX actions.

Protocol research sources (not copied implementation):

- https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/accessibilityaudit.py
- https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/dtx_service_provider.py
- https://github.com/jkcoxson/idevice/tree/89702099f4d7552f704f93b4526756abda319ceb

DTX encoding, NSKeyedArchive, software tunnel and check-in implementation come
from the existing MIT dependency. See [its notice](../Backend/THIRD_PARTY.md).
