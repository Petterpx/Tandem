#!/usr/bin/env python3
"""Opt-in native smoke: helper path and a booted simulator UUID. Sends one touch."""
import contextlib
import json
import os
import queue
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading

helper, udid = sys.argv[1:]


@contextlib.contextmanager
def connect():
    messages = queue.Queue()
    with tempfile.TemporaryDirectory(prefix="tandem-smoke-", dir="/tmp") as directory:
        path = directory + "/video.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(1)
        listener.settimeout(20)
        process = subprocess.Popen([helper, "--udid", udid], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
                                   env=dict(os.environ, TANDEM_VIDEO_SOCKET=path))

        def consume():
            try:
                for line in process.stdout:
                    messages.put(json.loads(line))
            finally:
                messages.put(None)

        def consume_video():
            try:
                connection, _ = listener.accept()
                with connection:
                    def read_exact(count):
                        data = bytearray()
                        while len(data) < count:
                            chunk = connection.recv(count - len(data))
                            if not chunk:
                                raise EOFError()
                            data.extend(chunk)
                        return bytes(data)
                    first = True
                    while True:
                        magic, length, timestamp = struct.unpack(">4sIQ", read_exact(16))
                        assert magic == b"TDV\x01" and 0 < length <= 16 * 1024 * 1024
                        data = read_exact(length)
                        assert timestamp > 0 and data.startswith(b"\x00\x00\x00\x01")
                        if first:
                            messages.put({"event": "video"})
                            first = False
            except EOFError:
                pass
            except Exception as error:
                messages.put({"event": "error", "error": str(error)})

        threading.Thread(target=consume, daemon=True).start()
        threading.Thread(target=consume_video, daemon=True).start()

        def until(predicate):
            while True:
                message = messages.get(timeout=20)
                assert message is not None, f"Unexpected helper EOF (exit={process.poll()})"
                assert message.get("event") != "error", message
                if predicate(message):
                    return message

        def rpc(identifier, command, **fields):
            process.stdin.write((json.dumps(dict(id=identifier, command=command, **fields)) + "\n").encode())
            process.stdin.flush()
            return until(lambda value: value.get("id") == identifier)

        try:
            seen = set()
            while seen != {"ready", "video"}:
                seen.add(until(lambda value: value.get("event") in {"ready", "video"})["event"])
            yield process, rpc
        finally:
            if not process.stdin.closed:
                process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            listener.close()


with connect() as (process, rpc):
    original = rpc(1, "clipboard_get")
    assert original["ok"] is True
    try:
        assert rpc(2, "clipboard_set", text="Tandem 中文🙂", paste=False)["ok"] is True
        assert rpc(3, "clipboard_get")["text"] == "Tandem 中文🙂"
        assert rpc(4, "unknown")["code"] == "UNSUPPORTED"
        assert rpc(5, "key", key="power")["code"] == "UNSUPPORTED"
        assert rpc(6, "touch", phase="down", x=0.5, y=0.25, pointer="finger")["ok"] is True
        assert rpc(7, "touch", phase="up", x=0.5, y=0.25, pointer="ai")["code"] == "AI_LOCKED"
        assert rpc(8, "touch", phase="up", x=0.5, y=0.25, pointer="finger")["ok"] is True
    finally:
        rpc(9, "clipboard_set", text=original["text"], paste=False)
        assert rpc(10, "quit")["ok"] is True
        process.wait(timeout=5)
    assert process.returncode == 0

with connect() as (process, _):
    process.stdin.close()
    process.wait(timeout=5)
    assert process.returncode == 0, "EOF did not shut down cleanly"
with connect() as (process, _):
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=5)
    assert process.returncode == 0, "SIGTERM did not shut down cleanly"
print("PASS: native frame, clipboard, input acknowledgement, touch ownership, quit, EOF, SIGTERM")
