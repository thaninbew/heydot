#!/usr/bin/env python3
"""Bounded lifecycle probes. Run after swift build; creates no UI or login items.
All subprocesses use a temporary HOME/CFFIXED_USER_HOME/HEYDOT_HOME and are reaped.
Counts refer to this worktree's debug HeyDot executable, via pgrep.
"""
import os, pathlib, tempfile, subprocess, socket, threading, time, json, re, fcntl
binary=str((pathlib.Path(__file__).resolve().parents[1]/'.build/out/Products/Debug/HeyDot').resolve())
results=[]
def count():
 p=subprocess.run(['pgrep','-f','^'+re.escape(binary)+r'( |$)'],capture_output=True,text=True)
 return len(p.stdout.splitlines())
with tempfile.TemporaryDirectory(prefix='hl-',dir='/tmp') as root:
 env=dict(os.environ, HOME=root, HEYDOT_HOME=root, CFFIXED_USER_HOME=root)
 run=pathlib.Path(root)/'Library/Application Support/HeyDot/run';run.mkdir(parents=True)
 control=run/'control.sock'
 def cli(args, **extra):
  return subprocess.run([binary]+args,env=dict(env,**extra),capture_output=True,text=True,timeout=7)
 before=count()
 # Fake app ownership excludes another app before it initializes AppKit/WebKit or microphone.
 lockpath=pathlib.Path(root)/'Library/Application Support/.HeyDot-app.lock'
 with lockpath.open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  assert cli([]).returncode==1
  assert cli(['--reset-onboarding']).returncode==1
  assert cli(['--uninstall-data']).returncode==1
 results.append(dict(scenario='app lease blocks second UI and both maintenance commands',before=before,after=count()))
 for ssh in [False,True]:
  if control.exists():control.unlink()
  listener=socket.socket(socket.AF_UNIX);listener.bind(str(control));listener.listen(1)
  stop=threading.Event()
  def slow():
   peer,_=listener.accept()
   with peer:
    peer.recv(65536)
    # A byte every 100 ms defeated the former per-read socket timeout.
    while not stop.wait(.1):
     try:peer.sendall(b' ')
     except OSError:break
  t=threading.Thread(target=slow);t.start()
  began=time.monotonic()
  try:
   q=cli(['--control-ssh'],SSH_ORIGINAL_COMMAND='status --json') if ssh else cli(['--control','status','--json'])
   elapsed=time.monotonic()-began
   assert q.returncode==1 and 4.8<elapsed<6.5,(q.returncode,elapsed)
   results.append(dict(scenario='drip peer '+('control-ssh' if ssh else 'control'),before=before,after=count(),seconds=round(elapsed,2),exit=q.returncode))
  finally:stop.set();t.join(timeout=1);listener.close();control.unlink()
 assert cli(['--control','status','--json']).returncode==0
 # Maintenance after all owners exit operates only on this temporary HOME.
 settings=run.parent/'settings.json';settings.write_text('{}')
 assert cli(['--reset-onboarding']).returncode==0
 assert list(run.parent.glob('settings.json.reset-*'))
 assert cli(['--uninstall-data']).returncode==0 and not run.parent.exists()
 results.append(dict(scenario='reset then uninstall after exit',before=before,after=count()))
 assert count()==before
print(json.dumps(results,indent=2))
