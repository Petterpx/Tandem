#!/usr/bin/env python3
"""Opt-in guest integration: text-input.py GUEST_BINARY DEDICATED_SIMULATOR_UUID.
Requires the TextFixture app built by build-text-fixture.sh. Never uses `booted`.
"""
import json, os, pathlib, queue, socket, subprocess, sys, tempfile, threading, time, urllib.parse
binary, udid = sys.argv[1:3]
host = "--host" in sys.argv[3:]
assert pathlib.Path(binary).is_file(), 'Guest text helper has not been built'
subprocess.run(['xcrun', 'simctl', 'launch', udid, 'local.tandem.text-fixture'], check=True, stdout=subprocess.DEVNULL)
container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', udid, 'local.tandem.text-fixture', 'data'], text=True).strip()
state = pathlib.Path(container) / 'Documents/state.json'
video_directory = tempfile.TemporaryDirectory(prefix='tandem-text-video-')
video = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
video_path = video_directory.name + '/video.sock'
video.bind(video_path)
video.listen(1)
def drain_video():
    connection, _ = video.accept()
    with connection:
        while connection.recv(65536): pass
if host: threading.Thread(target=drain_video,daemon=True).start()
process = subprocess.Popen(([binary, '--udid', udid] if host else ['xcrun', 'simctl', 'spawn', udid, binary]), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ,TANDEM_VIDEO_SOCKET=video_path))
messages = queue.Queue()
errors=[]
def consume():
    for line in process.stdout:
        message=json.loads(line)
        if message.get("event")=="error": errors.append(message)
        messages.put(message)
threading.Thread(target=consume, daemon=True).start()
while messages.get(timeout=15).get('event') != 'ready': pass
identifier = 0
def rpc(command, **fields):
    global identifier
    identifier += 1
    try:
        process.stdin.write((json.dumps(dict(id=identifier, command=command, **fields)) + '\n').encode())
        process.stdin.flush()
    except BrokenPipeError: raise RuntimeError(errors)
    while True:
        message = messages.get(timeout=10)
        if message.get('id') == identifier: return message
def reset(kind='view', text='', location=None, length=0):
    token = str(time.monotonic_ns())
    params = dict(kind=kind, text=text, length=length, token=token)
    if location is not None: params['location'] = location
    url = 'textfixture://reset?' + urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, 'local.tandem.text-fixture', url], check=True, stdout=subprocess.DEVNULL)
    deadline = time.monotonic()+5
    while time.monotonic()<deadline:
        try:
            if json.loads(state.read_text()).get('token')==token: break
        except (FileNotFoundError, json.JSONDecodeError): pass
        time.sleep(.005)
    time.sleep(.4)
    if kind=='web' and host:
        assert rpc('touch',phase='down',pointer='finger',x=.4,y=.2)['ok']
        assert rpc('touch',phase='up',pointer='finger',x=.4,y=.2)['ok']
        time.sleep(.4)
def insert(text, expected):
    start = time.monotonic()
    response = rpc('text', text=text)
    assert response.get('ok'), response
    deadline = max(start+2, time.monotonic()+.5)
    while time.monotonic()<deadline:
        actual = json.loads(state.read_text())
        if actual['text']==expected:
            # Guest UIKit delegate runs when text actually changes, before the host RPC reply.
            return max(0, (actual['uptime']-start)*1000), (time.monotonic()-start)*1000
        time.sleep(.001)
    raise AssertionError((text, expected, actual, response))
try:
    samples=[]
    for kind in ['view','field']:
        reset(kind)
        samples.append((kind, 'unicode_cold', *insert('中文🙂', '中文🙂')))
        samples.append((kind, 'unicode_warm', *insert('中文🙂', '中文🙂中文🙂')))
        reset(kind, 'prefix OLD suffix', 7, 3)
        samples.append((kind, 'selection', *insert('新🙂', 'prefix 新🙂 suffix')))
    reset('view')
    samples.append(('view','newline',*insert('第一行🙂\nSecond line','第一行🙂\nSecond line')))
    reset('view')
    expected=''
    for char in 'abcdefghijklmnopqrstuvwxyz0123456789':
        expected+=char
        samples.append(('view','ascii_cold' if len(expected)==1 else 'ascii_warm',*insert(char,expected)))
    reset('reject')
    rejected = rpc('text',text='blocked')
    assert rejected.get('code')=='UNSUPPORTED',rejected
    assert json.loads(state.read_text())['text']==''
    reset('view')
    samples.append(('view','recovery_after_rejection',*insert('still connected','still connected')))
    if host:
        reset('web')
        samples.append(('web','unicode_input_event',*insert('网页🙂\nSecond line','网页🙂\nSecond line')))
        assert json.loads(state.read_text())['inputEvents']>0
    reset('secure')
    if host:
        samples.append(('secure','native_paste',*insert('Secret123🙂','Secret123🙂')))
    else:
        response = rpc('text',text='private')
        assert response.get('code')=='NATIVE_PASTE_REQUIRED',response
        assert json.loads(state.read_text())['text']==''
    print(json.dumps(samples,ensure_ascii=False,indent=2))
finally:
    try:
        if process.poll() is None: rpc('quit')
    finally:
        try: process.stdin.close()
        except BrokenPipeError: pass
        process.wait(timeout=5)
assert process.returncode==0
video.close()
video_directory.cleanup()
