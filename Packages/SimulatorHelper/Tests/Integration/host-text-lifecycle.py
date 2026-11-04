#!/usr/bin/env python3
"""host-text-lifecycle.py HOST_HELPER AX_STATE_BINARY DEDICATED_SIMULATOR_UUID"""
import json, os, pathlib, queue, re, signal, socket, subprocess, sys, tempfile, threading, time
binary,observer,udid=sys.argv[1:]
guest=str(pathlib.Path(binary).with_name('tandem-simulator-text'))
def state(value=None):
    args=['xcrun','simctl','spawn',udid,observer]
    if value is not None:args.append(str(value))
    return int(subprocess.check_output(args,text=True).strip())
def guest_pids():
    result=subprocess.run(['pgrep','-f','^'+re.escape(guest).replace('/private/tmp/', '(/private)?/tmp/')+'$'],capture_output=True,text=True)
    return set(map(int,result.stdout.split()))
original=state()
try:
    for previous in [0,1]:
        for ending in ['quit','eof','sigterm','sigkill']:
            assert not guest_pids(),'Previous guest still alive'
            state(previous)
            directory=tempfile.TemporaryDirectory(prefix='tandem-text-lifecycle-')
            video=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            video_path=directory.name+'/video.sock'
            video.bind(video_path);video.listen(1)
            def drain_video():
                connection,_=video.accept()
                with connection:
                    while connection.recv(65536):pass
            threading.Thread(target=drain_video,daemon=True).start()
            p=subprocess.Popen([binary,'--udid',udid],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,TANDEM_VIDEO_SOCKET=video_path))
            messages=queue.Queue()
            def consume():
                for line in p.stdout:messages.put(json.loads(line))
            threading.Thread(target=consume,daemon=True).start()
            while messages.get(timeout=20).get('event')!='ready':pass
            # A read-only handshake consumer guarantees async guest startup completed.
            # No editable focus is required; no text/clipboard content is changed.
            deadline=time.monotonic()+10
            while not guest_pids() or state()!=1:
                assert time.monotonic()<deadline,'Guest did not start'
                time.sleep(.01)
            observed=guest_pids()
            if ending=='quit':p.stdin.write(b'{"id":1,"command":"quit"}\n');p.stdin.flush()
            elif ending=='eof':p.stdin.close()
            elif ending=='sigterm':p.send_signal(signal.SIGTERM)
            else:p.kill()
            p.wait(timeout=3)
            deadline=time.monotonic()+3
            while guest_pids() or state()!=previous:
                assert time.monotonic()<deadline,(previous,ending,'guest or AX state leaked',guest_pids())
                time.sleep(.01)
            video.close();directory.cleanup()
            print('PASS',previous,ending,'guest pids',sorted(observed),'gone, AX restored',flush=True)
finally:state(original)
