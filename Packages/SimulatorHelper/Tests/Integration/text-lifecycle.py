#!/usr/bin/env python3
"""text-lifecycle.py GUEST_BINARY AX_STATE_BINARY DEDICATED_SIMULATOR_UUID"""
import json, signal, subprocess, sys, time
binary, observer, udid = sys.argv[1:]
def state(value=None):
    args=['xcrun','simctl','spawn',udid,observer]
    if value is not None: args.append(str(value))
    return int(subprocess.check_output(args,text=True).strip())
original=state()
try:
    for previous in [0,1]:
        for ending in ['quit','eof','sigterm']:
            state(previous)
            p=subprocess.Popen(['xcrun','simctl','spawn',udid,binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            ready=json.loads(p.stdout.readline())
            assert ready.get('event')=='ready',ready
            assert ready['accessibilityChanged']==(previous==0),ready
            assert state()==1
            if ending=='quit':
                p.stdin.write(b'{"id":1,"command":"quit"}\n');p.stdin.flush()
                assert json.loads(p.stdout.readline())['ok']
            elif ending=='eof':p.stdin.close()
            else:p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)
            deadline=time.monotonic()+2
            while state()!=previous:
                assert time.monotonic()<deadline, (previous,ending,'AX setting not restored')
                time.sleep(.01)
            print('PASS',previous,ending,flush=True)
finally:state(original)
