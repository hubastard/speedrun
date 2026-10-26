# Swipe shapes vs. fling: a row's position polled while a DRAG_TEST plays (sent without
# waiting) and until it stops. In Settings > General > Keyboard > Keyboards > Add New Keyboard
# (a long UIKit list), each shape dragging 350 points up from the screen's center.
#   python3 agent/ios/spike/swipe.py maestro drag glide1400 tail40_200 tail40_125
import struct, subprocess, sys, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_client import Agent, s, i, nodes

APP = "com.apple.Preferences"
X, Y0, Y1 = 201, 437, 87

def shape(name):
    """(points as (y, offset_ms, duration_ms), lift_ms)"""
    if name == "maestro":  # what moveToPoint at 100 ms and liftUp at 701 ms play: a glide
        return [(Y0, 0, 0), (Y1, 100, 601)], 701
    if name == "drag":  # Input.drag: a 12-point kick, fast, the last 40 points at 200 points/s
        return [(Y0, 0, 0), (Y0 - 12, 0, 40), (Y1 + 40, 40, 150), (Y1, 190, 200)], 390
    if name.startswith("glide"):  # glide<ms>: constant speed
        ms = int(name[5:]); return [(Y0, 0, 0), (Y1, 0, ms)], ms
    if name.startswith("tail"):  # tail<points>_<ms>: fast in 100 ms, then the last points slowly
        pt, ms = map(int, name[4:].split("_"))
        return [(Y0, 0, 0), (Y1 + pt, 0, 100), (Y1, 100, ms)], 100 + ms
    raise SystemExit(f"unknown shape {name}")

a = Agent()
a.call(b"\x28" + s(APP))  # APP: the target of QUERY

def query(text):
    body, _, _ = a.call(b"\x2a" + s(text) + bytes([1]))
    return struct.unpack_from(">iiii", body, 1)[1] if body[0] else None

def tap(label):
    for _ in range(30):
        body, _, _ = a.call(b"\x0a"); n, = struct.unpack_from(">I", body)
        for d, (l, t, r, b), f, text, desc, *_ in nodes(body, 4, n):
            if t > 120 and (desc == label or desc.startswith(label + ",")):  # a row, not a title
                a.call(b"\x03" + i((l + r) // 2, (t + b) // 2)); time.sleep(1.2); return
        time.sleep(0.1)
    raise SystemExit(f"no {label}")

def row():
    """A row in the lower part of the screen, as the one to follow."""
    body, _, _ = a.call(b"\x29" + bytes([0])); c, = struct.unpack_from(">I", body)
    ns = nodes(body, 12, c)
    for n in ns:  # a cell (type 75) whose label QUERY finds where it is
        if n[6] == "75" and n[4] and 550 < n[1][1] < 780:
            y = query(n[4])
            if y is not None and any(m[4] == n[4] and abs(m[1][1] - y) <= 1 for m in ns): return n[4]
    raise SystemExit("no row to follow")

subprocess.run(["xcrun", "simctl", "terminate", "booted", APP], capture_output=True)
subprocess.run(["xcrun", "simctl", "launch", "booted", APP], capture_output=True)
time.sleep(2.5)
for label in ("General", "Keyboard", "Keyboards", "Add New Keyboard"): tap(label)
for name in sys.argv[1:] or ["maestro", "drag"]:
    points, lift = shape(name)
    label = row(); y0 = query(label)
    t0 = time.perf_counter()
    a.call(bytes([50]) + i(len(points)) + b"".join(i(X, y, o, d) for y, o, d in points) + i(lift, 0))
    trace = []
    while time.perf_counter() - t0 < 3.0:
        y = query(label)
        if y is None: break
        trace.append(((time.perf_counter() - t0) * 1000, y0 - y))
    if not trace or len(trace) < 2: print(f"{name}: the row left the screen"); continue
    final = trace[-1][1]
    still = next(t for t, y in trace if abs(y - final) <= 1)
    print(f"{name:12s} lift at {lift:4d} ms: moved {final:4d} points, still from {still:5.0f} ms")
    time.sleep(0.3)
