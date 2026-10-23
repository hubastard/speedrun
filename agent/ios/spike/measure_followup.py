# Follow-ups: where tap delivery time goes, what animates on General, how fast typing can go.
import io, os, statistics, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_client import Agent, s, i
from PIL import Image, ImageChops

med = statistics.median
a = Agent()
a.call(b"\x28" + s("com.apple.Preferences"))

def center(text):
    body, _, _ = a.call(b"\x2a" + s(text) + bytes([1]))
    assert body[0], text
    l, t, r, b = struct.unpack_from(">iiii", body, 1)
    return (l + r) // 2, (t + b) // 2

def reference(timeout=2500):
    body, _, _ = a.call(b"\x2b" + bytes([2]) + i(timeout))
    ok, since, waited, checks, changes, top, bottom, first = struct.unpack_from(">BIIIIIII", body)
    return first / 1000, since / 1000, changes, (top, bottom)

print("== When does the screen first change after a tap? (reference: screenshots, ~100 ms apart)")
for op, name in [(b"\x03", "TAP, waits for delivery"), (b"\x2d", "TAP_NOWAIT")]:
    firsts, lasts, calls = [], [], []
    for _ in range(4):
        for target in ("General", "BackButton"):
            x, y = center(target)
            body, _, ms = a.call(op + i(x, y, 100))
            calls.append(ms)
            f, l, _, _ = reference()
            firsts.append(f); lasts.append(l)
    print(f"  {name:26s} call {med(calls):6.1f} ms   first change {med(firsts):6.1f} ms   last change {med(lasts):7.1f} ms after the tap")

print("== What keeps changing on General? (PNG screenshots after the push)")
x, y = center("General")
a.call(b"\x03" + i(x, y, 100))
t0 = time.perf_counter()
shots = []
while time.perf_counter() - t0 < 3.0:
    body, _, _ = a.call(b"\x0e")
    n, = struct.unpack_from(">I", body)
    shots.append((time.perf_counter() - t0, Image.open(io.BytesIO(body[4:4 + n])).convert("RGB")))
for (t1, im1), (t2, im2) in zip(shots, shots[1:]):
    d = ImageChops.difference(im1, im2)
    bbox = d.getbbox()
    if bbox:
        mx = max(d.crop(bbox).getextrema(), key=lambda e: e[1])[1]
        print(f"  {t1*1000:6.0f}->{t2*1000:6.0f} ms: changed box {bbox}, max channel diff {mx}")
x, y = center("BackButton")
a.call(b"\x03" + i(x, y, 100)); reference(1500)

print("== Typing speed: largest rate that keeps every character")
x, y = center("magnifyingglass")
a.call(b"\x03" + i(x, y, 100)); reference(1500)
for rate in (30, 60, 100, 150, 200, 300):
    ok = 0; times = []
    for _ in range(3):
        body, _, _ = a.call(b"\x08" + s("Speedrun bench") + i(rate))
        times.append(struct.unpack(">I", body[:4])[0] / 1000)
        body, _, _ = a.call(b"\x2a" + s("Speedrun bench") + bytes([2]))
        ok += body[0]
        a.call(b"\x08" + s("\b" * 25) + i(30))
    print(f"  {rate:4d} chars/s: 14 chars in {med(times):6.1f} ms, correct {ok}/3")
x, y = center("close")
a.call(b"\x03" + i(x, y, 100)); reference(1500)
