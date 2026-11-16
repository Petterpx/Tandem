#!/usr/bin/env python3
"""Check held-contact EOF cleanup. Run only with the Settings main list visible."""
import argparse
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--udid", required=True)
args = parser.parse_args()
backend = subprocess.Popen([str(root / "build/ios-usb-native/tandem-ios-usb"), "--udid", args.udid],
                           stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
events = []
try:
    # Bound the entire subprocess even if its first-frame event never arrives.
    import threading
    watchdog = threading.Timer(25, backend.terminate)
    watchdog.daemon = True
    watchdog.start()
    for line in backend.stderr:
        event = json.loads(line)
        events.append(event)
        if event.get("event") == "video_started":
            break
    else:
        raise RuntimeError("No video before backend exit")
    time.sleep(0.4)
    for identifier, (phase, y) in enumerate([("down", .72), ("move", .65), ("move", .58), ("move", .5)], 1):
        backend.stdin.write((json.dumps({"id": identifier, "op": "touch", "phase": phase, "x": .5, "y": y}) + "\n").encode())
        backend.stdin.flush()
        time.sleep(.08)
    backend.stdin.close()
    for line in backend.stderr:
        events.append(json.loads(line))
    backend.wait(timeout=18)
finally:
    watchdog.cancel()
    if backend.poll() is None:
        backend.terminate()
        try:
            backend.wait(timeout=18)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()
cleanup = [event for event in events if event.get("event") == "touch_cleanup"]
summary = next((event["result"] for event in events if event.get("event") == "summary"), {})
result = {"backend_exit": backend.returncode, "touch_cleanup": cleanup, "backend_summary": summary}
result["passed"] = backend.returncode == 0 and any(
    event.get("sent") is True and event.get("reason") == "stdin_eof" for event in cleanup
) and summary.get("media_stop_sent") is True
destination = root / "build/ios-usb-native/eof-cleanup.json"
destination.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
