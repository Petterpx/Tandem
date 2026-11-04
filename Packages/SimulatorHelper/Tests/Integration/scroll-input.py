#!/usr/bin/env python3
"""Native scroll regression. Opt-in: scroll-input.py HELPER DEDICATED_UDID OUTPUT_DIR.
Build/install ScrollFixture first. Never targets `booted`; drains the native video stream.
--self-test tests the evidence analyzer without touching a simulator.
"""
import argparse, contextlib, hashlib, json, math, os, pathlib, queue, socket, subprocess, sys, tempfile, threading, time, unittest


def self_test():
    class EvidenceTests(unittest.TestCase):
        def test_deceleration_is_not_stale_native_input(self):
            result = summarize([{'sent': 10., 'ack': 10.01}], [
                {'kind': 'touch', 'phase': 'ended', 'uptime': 10.02},
                {'kind': 'frame', 'uptime': 10.3, 'offset': 100, 'dragging': False, 'decelerating': True},
                {'kind': 'frame', 'uptime': 10.5, 'offset': 120, 'dragging': False, 'decelerating': True}], 10.)
            self.assertEqual(result['native_moves_after_stop'], 0)
            self.assertAlmostEqual(result['native_release_delay_ms'], 20.)
            self.assertEqual(result['deceleration_travel_after_stop_points'], 20.)
        def test_stale_touch_and_unreleased_gesture_are_visible(self):
            result = summarize([{'sent': 10., 'ack': 10.8}], [
                {'kind': 'touch', 'phase': 'moved', 'uptime': 10.5}], 10.)
            self.assertEqual(result['native_moves_after_stop'], 1)
            self.assertFalse(result['native_touch_released'])
            self.assertAlmostEqual(result['rpc_p95_ms'], 800.)
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(EvidenceTests))
    if not result.wasSuccessful(): raise SystemExit(1)


def percentile(values, quantile):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * quantile) - 1)] if values else None


def summarize(commands, events, stopped):
    latencies = [(row['ack'] - row['sent']) * 1000 for row in commands if 'ack' in row]
    touches = [row for row in events if row['kind'] == 'touch']
    releases = [row for row in touches if row['phase'] in ('ended', 'cancelled') and row['uptime'] >= stopped - .05]
    frames = [row for row in events if row['kind'] == 'frame' and row['uptime'] >= stopped]
    deceleration = [row['offset'] for row in frames if row.get('decelerating')]
    last_touch = touches[-1] if touches else {}
    intervals = [(right['uptime'] - left['uptime']) * 1000 for left, right in zip(frames, frames[1:])]
    release = releases[-1] if releases else {}
    all_frames = [row for row in events if row['kind'] == 'frame']
    all_gaps = [(right['uptime'] - left['uptime']) * 1000 for left, right in zip(all_frames, all_frames[1:])]
    return {
        'scenario_frame_gap_max_ms': max(all_gaps, default=None),
        'native_release_event_delay_ms': (release['eventTimestamp'] - stopped) * 1000 if 'eventTimestamp' in release else None,
        'native_release_delivery_delay_ms': (release['uptime'] - release['eventTimestamp']) * 1000 if 'eventTimestamp' in release else None,
        'commands': len(commands), 'acks': len(latencies),
        'rpc_p50_ms': percentile(latencies, .5), 'rpc_p95_ms': percentile(latencies, .95),
        'rpc_max_ms': max(latencies, default=None),
        'native_touch_released': last_touch.get('phase') in ('ended', 'cancelled'),
        'native_release_delay_ms': (releases[-1]['uptime'] - stopped) * 1000 if releases else None,
        'native_moves_after_stop': sum(row['phase'] == 'moved' and row['uptime'] > stopped for row in touches),
        'native_touch_counts': {phase: sum(row['phase'] == phase for row in touches) for phase in ('began', 'moved', 'ended', 'cancelled')},
        'deceleration_travel_after_stop_points': max(deceleration) - min(deceleration) if deceleration else 0,
        'total_travel_after_stop_points': max(row['offset'] for row in frames) - min(row['offset'] for row in frames) if frames else 0,
        'post_stop_frame_gap_max_ms': max(intervals, default=None),
    }


class Helper:
    def __init__(self, binary, udid, directory):
        self.directory = directory
        self.responses, self.commands = {}, []
        self.condition = threading.Condition()
        self.next_id = 0
        self.events = []
        self.video_bytes = 0
        self.video = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.video.bind(str(directory / 'video.sock'))
        self.video.listen(1)
        self.video.settimeout(20)
        self.stderr = open(directory / 'helper.stderr', 'wb')
        self.process = subprocess.Popen([binary, '--udid', udid], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.stderr, bufsize=0, env=dict(os.environ, TANDEM_VIDEO_SOCKET=str(directory / 'video.sock')))
        threading.Thread(target=self.consume, daemon=True).start()
        threading.Thread(target=self.drain_video, daemon=True).start()
        with self.condition:
            if not self.condition.wait_for(lambda: any(row.get('event') == 'ready' for row in self.events), 30):
                raise RuntimeError('Helper did not become ready: ' + repr(self.events))

    def consume(self):
        for line in self.process.stdout:
            row = json.loads(line)
            observed = time.monotonic()
            with self.condition:
                if 'id' in row:
                    self.responses[row['id']] = (row, observed)
                else:
                    self.events.append(row)
                self.condition.notify_all()

    def drain_video(self):
        try:
            connection, _ = self.video.accept()
            with connection:
                while chunk := connection.recv(262144):
                    self.video_bytes += len(chunk)
        except (TimeoutError, OSError):
            pass

    def send(self, phase, x=.5, y=.6, planned=None):
        self.next_id += 1
        row = dict(id=self.next_id, command='touch', phase=phase, pointer='finger', x=x, y=y)
        sample = dict(row, sent=time.monotonic(), planned=planned)
        self.commands.append(sample)
        self.process.stdin.write((json.dumps(row) + '\n').encode())
        self.process.stdin.flush()
        return sample

    def wait(self, samples, timeout=45):
        deadline = time.monotonic() + timeout
        for sample in samples:
            with self.condition:
                if not self.condition.wait_for(lambda: sample['id'] in self.responses, max(0, deadline - time.monotonic())):
                    raise RuntimeError(f'Timeout awaiting touch ACK {sample}')
                response, sample['ack'] = self.responses[sample['id']]
            sample['response'] = response
            assert response.get('ok'), response

    def close(self):
        try:
            self.process.stdin.write(b'{"id":999999,"command":"quit"}\n')
            self.process.stdin.flush()
            self.process.stdin.close()
            self.process.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait()
        self.video.close()
        self.stderr.close()


def run(binary, udid, output, mode, strict, warm=False):
    assert udid != 'EED031C0-B452-4761-8180-AD8557EB3D1E', 'Refusing user simulator'
    assert udid.lower() != 'booted', 'Explicit dedicated simulator UUID required'
    output.mkdir(parents=True, exist_ok=True)
    container = pathlib.Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', udid, 'local.tandem.scroll-fixture', 'data'], text=True).strip())
    state_path = container / 'Documents/scroll-state.json'
    if not warm:
        subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, 'local.tandem.scroll-fixture'], check=True, stdout=subprocess.DEVNULL)
    def read_state():
        return json.loads(state_path.read_text())
    def until(predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                state = read_state()
                if predicate(state): return state
            except (OSError, json.JSONDecodeError): pass
            time.sleep(.02)
        raise AssertionError('Guest state timeout')
    until(lambda state: state['uptime'] > time.monotonic() - 1)
    time.sleep(.5)
    with tempfile.TemporaryDirectory(prefix='tandem-scroll-', dir='/tmp') as directory:
        helper = Helper(binary, udid, pathlib.Path(directory))
        try:
            started = time.monotonic()
            # All points use the simulator's native touch API. No pre-recorded frames.
            if mode == 'ack-paced':
                sample = helper.send('down', y=.78)
                helper.wait([sample])
                while time.monotonic() < started + 1:
                    fraction = min(1, time.monotonic() - started)
                    sample = helper.send('move', y=.78 - .45 * fraction)
                    helper.wait([sample])
                helper.send('up', y=.33)
            elif mode == 'continuous':
                helper.send('down', y=.78)
                for index in range(1, 121):
                    planned = started + index / 120
                    time.sleep(max(0, planned - time.monotonic()))
                    helper.send('move', y=.78 - .45 * index / 120, planned=planned)
                helper.send('up', y=.33)
            else:
                # Mirrors old wheel swipe shape: down, five moves, up per tick.
                for index in range(60):
                    planned = started + index / 60
                    time.sleep(max(0, planned - time.monotonic()))
                    helper.send('down', y=.65, planned=planned)
                    for step in range(1, 6):
                        helper.send('move', y=.65 - .045 * step / 5, planned=planned)
                    helper.send('up', y=.605, planned=planned)
            stopped = time.monotonic()
            gesture_commands = list(helper.commands)
            helper.wait(gesture_commands)
            # Capture queued native events and legitimate deceleration separately.
            time.sleep(2)
            state = until(lambda row: row['uptime'] > time.monotonic() - .3)
            events = [row for row in state['events'] if row['uptime'] >= started]
            metrics = summarize(gesture_commands, events, stopped)
            metrics['input_duration_ms'] = (stopped - started) * 1000
            metrics['all_acks_after_stop_ms'] = (max(row['ack'] for row in gesture_commands) - stopped) * 1000
            metrics['last_state_dragging'] = state['dragging']
            metrics['last_state_decelerating'] = state['decelerating']
            metrics['video_bytes'] = helper.video_bytes
            # Recovery action is verified by actual guest UIButton action.
            count = state['buttonTaps']
            tap = [helper.send('down', x=state['buttonX'], y=state['buttonY'])]
            time.sleep(.06)
            tap.append(helper.send('up', x=state['buttonX'], y=state['buttonY']))
            helper.wait(tap)
            try:
                until(lambda row: row['buttonTaps'] > count, 3)
                metrics['recovery_button'] = True
            except AssertionError:
                metrics['recovery_button'] = False
            previous = read_state()
            recovery_start = time.monotonic()
            helper.send('down', y=.75)
            for step in range(1, 31):
                time.sleep(1 / 120)
                helper.send('move', y=.75 - .25 * step / 30)
            helper.send('up', y=.5)
            helper.wait(helper.commands[len(gesture_commands) + len(tap):])
            try:
                final = until(lambda row: any(event['kind'] == 'touch' and event['phase'] in ('ended', 'cancelled') and event['uptime'] > recovery_start for event in row['events']), 8)
            except AssertionError:
                final = read_state()
            recovery_events = [row for row in final['events'] if row['uptime'] > recovery_start]
            metrics['recovery_second_drag'] = any(row['kind'] == 'dragBegin' for row in recovery_events) and final['offset'] > previous['offset'] + 20
            metrics['recovery_final_released'] = summarize([], recovery_events, recovery_start)['native_touch_released']
            metrics['fixture_save_last_ms'] = final.get('saveLastMilliseconds')
            metrics['fixture_save_max_ms'] = final.get('saveMaxMilliseconds')
            metrics['fixture_dropped_events'] = final.get('droppedEvents')
            metrics['warm_run'] = warm
            metrics['mode'] = mode
            metrics['udid'] = udid
            metrics['helper'] = str(pathlib.Path(binary).resolve())
            metrics['helper_sha256'] = hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest()
            (output / 'guest-state.json').write_text(json.dumps(final, indent=2))
            (output / 'commands.json').write_text(json.dumps(helper.commands, indent=2))
            (output / 'summary.json').write_text(json.dumps(metrics, indent=2))
            (output / 'helper-events.json').write_text(json.dumps(helper.events, indent=2))
            print(json.dumps(metrics, indent=2))
            if strict:
                assert metrics['native_touch_released'], 'Native touch stuck down'
                assert not metrics['last_state_dragging'], 'UIScrollView remained dragging'
                assert metrics['native_release_delay_ms'] is not None and metrics['native_release_delay_ms'] < 250, 'Queued native release exceeded 250 ms'
                assert metrics['recovery_button'], 'Recovery button unusable'
                assert metrics['recovery_second_drag'], 'Second drag unusable'
                assert metrics['recovery_final_released'], 'Second drag left native touch down'
        finally:
            helper.close()
            (output / 'helper.stderr').write_bytes((pathlib.Path(directory) / 'helper.stderr').read_bytes())


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        self_test()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('helper')
        parser.add_argument('dedicated_udid')
        parser.add_argument('output_dir', type=pathlib.Path)
        parser.add_argument('--mode', choices=['continuous', 'ack-paced', 'wheel-pulses'], default='continuous')
        parser.add_argument('--strict', action='store_true', help='Fail on stuck input, >250ms native release or recovery failure')
        parser.add_argument('--warm', action='store_true', help='Reuse current fixture process instead of resetting; analyze only new events')
        args = parser.parse_args()
        run(args.helper, args.dedicated_udid, args.output_dir, args.mode, args.strict, args.warm)
