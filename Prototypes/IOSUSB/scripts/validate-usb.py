#!/usr/bin/env python3
"""Measure decoded video while a single USB backend injects continuous touch.

Default is observation only. --exercise sends vertical swipes: put Settings on
the iPhone's screen first. No screen images or encoded video are written to disk.
Only counts, timings and frame-hash comparison results are retained.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import statistics
import struct
import subprocess
import sys
import threading
import time


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)], 3)


def main() -> int:
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--backend", type=Path, default=root / "build/ios-usb-native/tandem-ios-usb")
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--output", type=Path, default=root / "build/ios-usb-native/validation.json")
    parser.add_argument("--duration", type=float, default=12)
    parser.add_argument("--exercise", action="store_true")
    parser.add_argument("--framed-video", action="store_true", help="Validate Tandem's TUV1 access-unit framing too")
    args = parser.parse_args()
    if not 3 <= args.duration <= 120:
        parser.error("--duration must be between 3 and 120 seconds")
    for executable in (str(args.backend), args.ffmpeg):
        if not os.access(executable, os.X_OK):
            parser.error(f"not an executable file: {executable}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    backend_args = [str(args.backend), "--udid", args.udid]
    if args.framed_video:
        backend_args.append("--framed-video")
    backend = subprocess.Popen(backend_args,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        decoder = subprocess.Popen([args.ffmpeg, "-hide_banner", "-loglevel", "warning",
                                    "-probesize", "1000000", "-analyzeduration", "1000000",
                                    "-f", "hevc", "-i", "pipe:0", "-an", "-fps_mode", "passthrough",
                                    "-f", "framemd5", "pipe:1"],
                                   stdin=subprocess.PIPE if args.framed_video else backend.stdout,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except BaseException:
        backend.stdin.close()
        backend.stdout.close()
        try:
            backend.wait(timeout=18)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()
        raise
    assert backend.stdout is not None
    if not args.framed_video:
        backend.stdout.close()
    lock = threading.Lock()
    frames: list[tuple[float, str]] = []
    events: list[dict] = []
    pending: dict[int, float] = {}
    ack_rtt: list[float] = []
    decoder_errors: list[str] = []
    framing_errors: list[str] = []
    framed_units = 0
    first_frame = threading.Event()
    request_id = 0

    def forward_framed_video() -> None:
        nonlocal framed_units
        assert backend.stdout is not None and decoder.stdin is not None

        def exact(count: int) -> bytes:
            result = bytearray()
            while len(result) < count:
                part = backend.stdout.read(count - len(result))
                if not part:
                    break
                result.extend(part)
            return bytes(result)

        last_pts = -1
        try:
            while True:
                header = exact(16)
                if not header:
                    break
                if len(header) != 16 or header[:4] != b"TUV1":
                    raise ValueError("Invalid or partial TUV1 header")
                size, pts = struct.unpack(">IQ", header[4:])
                if not 0 < size <= 16 * 1024 * 1024 or pts < last_pts:
                    raise ValueError("Invalid frame size or non-monotonic timestamp")
                payload = exact(size)
                if len(payload) != size:
                    raise ValueError("Partial access unit")
                last_pts = pts
                decoder.stdin.write(payload)
                decoder.stdin.flush()
                with lock:
                    framed_units += 1
        except (OSError, ValueError) as exc:
            with lock:
                framing_errors.append(str(exc))
        finally:
            backend.stdout.close()
            decoder.stdin.close()

    def read_frames() -> None:
        assert decoder.stdout is not None
        for line in decoder.stdout:
            if line.startswith(b"#"):
                continue
            fields = line.decode("utf-8", errors="replace").strip().split(",")
            if len(fields) == 6:
                with lock:
                    frames.append((time.monotonic(), fields[-1].strip()))
                first_frame.set()

    def read_events() -> None:
        assert backend.stderr is not None
        for line in backend.stderr:
            try:
                event = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(event, dict):
                continue
            now = time.monotonic()
            with lock:
                events.append(event)
                event_id = event.get("id")
                if event.get("event") == "input_ack" and event_id in pending:
                    ack_rtt.append((now - pending.pop(event_id)) * 1000)

    def read_decoder_errors() -> None:
        assert decoder.stderr is not None
        for line in decoder.stderr:
            # ffmpeg diagnostics contain codec data, not screen contents.
            with lock:
                decoder_errors.append(line.decode("utf-8", errors="replace").strip())

    threads = [threading.Thread(target=target, daemon=True)
               for target in (read_frames, read_events, read_decoder_errors)]
    if args.framed_video:
        threads.append(threading.Thread(target=forward_framed_video, daemon=True))
    for thread in threads:
        thread.start()

    def send(op: str, **fields: object) -> None:
        nonlocal request_id
        request_id += 1
        if op == "touch":
            with lock:
                pending[request_id] = time.monotonic()
        assert backend.stdin is not None
        backend.stdin.write((json.dumps({"id": request_id, "op": op, **fields}) + "\n").encode())
        backend.stdin.flush()

    active_intervals: list[tuple[float, float]] = []
    active = False
    measure_start: float | None = None
    measure_end: float | None = None
    reason: str | None = None
    try:
        deadline = time.monotonic() + 30
        while not first_frame.wait(0.2):
            if backend.poll() is not None or decoder.poll() is not None:
                raise RuntimeError("backend or decoder exited before the first decoded frame")
            if time.monotonic() >= deadline:
                raise TimeoutError("no decoded frame within 30 seconds")
        print("Decoded video ready; beginning measurement", file=sys.stderr, flush=True)
        # Exclude the decoder's initial buffered burst from live frame-rate data.
        time.sleep(1)
        measure_start = time.monotonic()
        if args.exercise:
            for cycle in range(6):
                begin = time.monotonic()
                a, b = (0.72, 0.28) if cycle % 2 == 0 else (0.28, 0.72)
                send("touch", phase="down", x=0.5, y=a)
                active = True
                for step in range(1, 37):
                    due = begin + step / 60
                    time.sleep(max(0, due - time.monotonic()))
                    send("touch", phase="move", x=0.5, y=a + (b - a) * step / 36)
                send("touch", phase="up", x=0.5, y=b)
                active = False
                active_intervals.append((begin, time.monotonic()))
                time.sleep(0.5)
        remaining = measure_start + args.duration - time.monotonic()
        if remaining > 0:
            # Wake periodically to notice an early transport failure.
            deadline = time.monotonic() + remaining
            while time.monotonic() < deadline:
                if backend.poll() is not None:
                    raise RuntimeError("backend exited during measurement")
                time.sleep(max(0, min(0.2, deadline - time.monotonic())))
    except (Exception, KeyboardInterrupt) as exc:
        reason = str(exc) or type(exc).__name__
    finally:
        measure_end = time.monotonic()
        if active:
            try:
                send("touch", phase="up", x=0.5, y=0.5)
            except (BrokenPipeError, OSError):
                pass
        try:
            send("stop")
            assert backend.stdin is not None
            backend.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            backend.wait(timeout=18)
        except subprocess.TimeoutExpired:
            backend.terminate()
            try:
                backend.wait(timeout=3)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait()
        try:
            decoder.wait(timeout=5)
        except subprocess.TimeoutExpired:
            decoder.terminate()
            decoder.wait(timeout=3)
        for thread in threads:
            thread.join(timeout=1)

    with lock:
        snapshot = frames.copy()
        acks = [event for event in events if event.get("event") == "input_ack"]
        normal_stops = {"stop_command", "stdin_eof", "duration_elapsed", "sigint", "sigterm", "shutdown"}
        errors = [event for event in events if event.get("event") in ("error", "input_error")
                  or (event.get("event") == "disconnected" and event.get("reason") not in normal_stops)]
        summary = next((event.get("result", {}) for event in reversed(events)
                        if event.get("event") == "summary"), {})
        measured = [(at, digest) for at, digest in snapshot
                    if measure_start is not None and measure_start <= at <= measure_end]
        timed_gaps = [(a[0], b[0], (b[0] - a[0]) * 1000) for a, b in zip(measured, measured[1:])]
        gaps = [gap for _, _, gap in timed_gaps]
        active_frames = [frame for frame in snapshot
                         if any(begin <= frame[0] <= end for begin, end in active_intervals)]
        per_gesture = [{"frames_during_touch": sum(begin <= at <= end for at, _ in snapshot),
                        "unique_frames_during_touch": len({digest for at, digest in snapshot if begin <= at <= end}),
                        "maximum_frame_gap_ms": round(max((gap for a, b, gap in timed_gaps
                                                            if begin <= a and b <= end), default=0), 3),
                        "duration_ms": round((end - begin) * 1000, 2)}
                       for begin, end in active_intervals]
        result = {
            "schema": 1, "transport": "usb", "exercise": args.exercise,
            "framed_video": args.framed_video, "framed_access_units": framed_units,
            "framing_errors": framing_errors,
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "decoded_frames": len(snapshot),
            "measurement_decoded_frames": len(measured),
            "measurement_decoded_fps": round(len(measured) / (measure_end - measure_start), 2)
                                       if measure_start is not None and measure_end > measure_start else None,
            "last_frame_age_before_stop_ms": round((measure_end - measured[-1][0]) * 1000, 3)
                                             if measured else None,
            "unique_decoded_frames": len({digest for _, digest in snapshot}),
            "decoded_fps": round((len(snapshot) - 1) / (snapshot[-1][0] - snapshot[0][0]), 2)
                           if len(snapshot) > 1 and snapshot[-1][0] > snapshot[0][0] else None,
            "first_decoded_frame_ms": round((snapshot[0][0] - started) * 1000, 2) if snapshot else None,
            "frame_gap_ms": {"median": round(statistics.median(gaps), 3) if gaps else None,
                             "p95": percentile(gaps, .95), "maximum": round(max(gaps), 3) if gaps else None},
            "frame_gaps_over_100ms": [{"at_seconds": round(a - measure_start, 3), "gap_ms": round(gap, 3),
                                       "overlaps_touch": any(a <= end and b >= begin for begin, end in active_intervals)}
                                      for a, b, gap in timed_gaps if gap > 100],
            "frames_during_active_touch": len(active_frames), "gestures": per_gesture,
            "input_acks": len(acks), "input_rejected": sum(event.get("sent") is False for event in acks),
            "input_requests_without_ack": len(pending),
            "input_roundtrip_ms": {"p50": percentile(ack_rtt, .5), "p95": percentile(ack_rtt, .95)},
            "backend_exit": backend.returncode, "decoder_exit": decoder.returncode,
            "backend_summary": summary,
            "backend_errors": errors, "decoder_diagnostics": decoder_errors[-12:], "failure": reason,
            "note": "Transport acknowledgment is not proof of UI effect. Frame hashes are compared only; no image data is retained.",
        }
    result["pass_scope"] = "decoded video continuity during HID transport writes; UI behavior checked separately"
    result["passed"] = (not reason and len(measured) > 10 and backend.returncode == 0
        and decoder.returncode == 0 and summary.get("media_stop_sent") is True
        and result["last_frame_age_before_stop_ms"] < 500 and not errors and not framing_errors and (
        not args.exercise or (len(active_intervals) == 6 and all(g["frames_during_touch"] > 0 for g in per_gesture) and not pending
                              and len({digest for _, digest in snapshot}) > 1 and not errors
                              and result["input_rejected"] == 0)))
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as destination:
        json.dump(result, destination, indent=2, ensure_ascii=False)
        destination.write("\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
