# Starts the sleep guard (argv: guard path, signal name, "unload"|"check"), lets
# it run into a hung child for a second, sends it the signal, prints its exit
# status. Used by tests/system.sh. SIGINT is restored to its default in the
# child: a background process of a non-interactive shell starts with it ignored,
# and a script cannot trap a signal that was ignored on entry (under systemd it
# is not ignored).
import os, signal, subprocess, sys, time

guard, name, mode = sys.argv[1:4]
sig = getattr(signal, name)

def defaults():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    os.setsid()

args = [guard] + (["--check"] if mode == "check" else [])
p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     preexec_fn=defaults, restore_signals=True)
time.sleep(1)
if p.poll() is not None:
    print("exited early: %d" % p.returncode)
    sys.exit(0)
os.kill(p.pid, sig)
try:
    rc = p.wait(timeout=8)
except subprocess.TimeoutExpired:
    p.kill()
    rc = "timeout"
print(rc)
