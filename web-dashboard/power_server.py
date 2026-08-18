#!/usr/bin/env python3
"""Real-time Mac power server: samples ioreg every 1s, appends CSV, streams via SSE."""
import json, re, subprocess, threading, time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CSV = "/tmp/power_log.csv"
HTML = "/tmp/power_dashboard.html"
PORT = 8777

history = deque(maxlen=7200)  # ~2h of 1s samples
cond = threading.Condition()

def sample():
    out = subprocess.run(["ioreg", "-rn", "AppleSmartBattery"],
                         capture_output=True, text=True).stdout
    def grab(pat, default=0):
        m = re.search(pat, out)
        return float(m.group(1)) if m else default
    def signed64(v):
        # ioreg reports negative power as wrapped uint64 (2^64 - n)
        return v - 2**64 if v >= 2**63 else v
    return {
        "ts":    time.strftime("%H:%M:%S"),
        "pct":   grab(r'"CurrentCapacity" = (\d+)'),
        "load":  grab(r'"SystemLoad"=(\d+)') / 1000,
        "batt":  signed64(grab(r'"BatteryPower"=(\d+)')) / 1000,
        "total": grab(r'"SystemPowerIn"=(\d+)') / 1000,
        "amp":   signed64(grab(r'"InstantAmperage" = (-?\d+)')) / 1000,
    }

def sampler():
    # keep CSV header-compatible with old log
    while True:
        s = sample()
        with cond:
            history.append(s)
            cond.notify_all()
        with open(CSV, "a") as f:
            f.write(f"{s['ts']},{s['pct']:.0f},{s['load']:.1f},{s['batt']:.1f},{s['total']:.1f},{s['amp']:.2f},\n")
        time.sleep(1)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.startswith("/events"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            last_idx = 0
            try:
                while True:
                    with cond:
                        cond.wait(timeout=5)
                        items = list(history)
                    new = items[last_idx:]
                    last_idx = len(items)
                    for s in new:
                        self.wfile.write(f"data: {json.dumps(s)}\n\n".encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path.startswith("/power_log.csv"):
            self.send_response(200)
            self.send_header("Content-Type", "text/csv")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            with open(CSV, "rb") as f:
                self.wfile.write(f.read())
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            with open(HTML, "rb") as f:
                self.wfile.write(f.read())

if __name__ == "__main__":
    threading.Thread(target=sampler, daemon=True).start()
    print(f"Serving on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
