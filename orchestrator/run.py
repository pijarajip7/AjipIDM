#!/usr/bin/env python3
"""
Single-command launcher for orchestrator.py + dashboard.py together.

Run:
    python run.py

Equivalent to opening two terminals and running `python orchestrator.py` in
one and `streamlit run dashboard.py ...` in the other — this just saves
needing two terminal windows/tabs on the VPS. Output from both is streamed
here, prefixed with which process it's from.

Deliberately does NOT cascade-kill: if orchestrator.py crashes, dashboard.py
is left running (it already shows a "stale" warning once live_status.json
stops updating — see dashboard.py's render_live_panel — so it's more useful
alive than dead here, letting you notice and react remotely). If
dashboard.py crashes, orchestrator.py keeps rotating regardless — the
trading loop should never depend on the monitoring UI. Only Ctrl+C stops
both, deliberately.
"""

import argparse
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def stream_output(proc, prefix):
    for line in proc.stdout:
        print(f"[{prefix}] {line}", end="", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dashboard-address", default="0.0.0.0",
                         help="Streamlit bind address (default: 0.0.0.0, reachable from outside the VPS)")
    parser.add_argument("--dashboard-port", type=int, default=8501)
    args = parser.parse_args()

    # sys.executable + "-m" instead of bare "streamlit"/"python" — guarantees
    # both use the same interpreter/venv this launcher itself is running
    # under, regardless of PATH setup on the VPS.
    procs = {
        "orchestrator": subprocess.Popen(
            [sys.executable, os.path.join(HERE, "orchestrator.py")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        ),
        "dashboard": subprocess.Popen(
            [sys.executable, "-m", "streamlit", "run", os.path.join(HERE, "dashboard.py"),
             "--server.address", args.dashboard_address,
             "--server.port", str(args.dashboard_port),
             # Headless: no browser to auto-open on a VPS, and — importantly —
             # skips Streamlit's first-run "enter your email" onboarding
             # prompt, which otherwise reads stdin and hangs/EOFs when
             # launched as a subprocess with no TTY attached.
             "--server.headless", "true"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        ),
    }

    for name, proc in procs.items():
        threading.Thread(target=stream_output, args=(proc, name), daemon=True).start()

    print(f"[run] orchestrator + dashboard (http://{args.dashboard_address}:{args.dashboard_port}) started. Ctrl+C to stop both.",
          flush=True)

    exited = set()
    try:
        while len(exited) < len(procs):
            time.sleep(1)
            for name, proc in procs.items():
                if name in exited:
                    continue
                ret = proc.poll()
                if ret is not None:
                    exited.add(name)
                    print(f"[run] {name} exited (code {ret}) — {'all processes now stopped' if len(exited) == len(procs) else 'the other process keeps running'}.",
                          flush=True)
    except KeyboardInterrupt:
        print("\n[run] Ctrl+C — stopping both...", flush=True)
    finally:
        for name, proc in procs.items():
            if proc.poll() is None:
                proc.terminate()
        for name, proc in procs.items():
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    main()
