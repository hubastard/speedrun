# Step 2 of the iOS plan: time each building block through the spike agent.
# Start state: Settings freshly launched on its home screen (scrolled to the top).
import os, statistics, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_client import Agent, s, i, nodes

med = statistics.median
a = Agent()

def report(label, xs, unit="ms"):
    xs = sorted(xs)
    print(f"  {label:58s} median {med(xs):8.1f}  min {xs[0]:8.1f}  max {xs[-1]:8.1f} {unit}  (n={len(xs)})")

def query(text, mode=1):
    body, _, ms = a.call(b"\x2a" + s(text) + bytes([mode]))
    found = body[0]
    l, t, r, b = struct.unpack_from(">iiii", body, 1)
    return found, (l, t, r, b), ms

def tap(text_or_box, hold=100):
    if isinstance(text_or_box, str):
        found, (l, t, r, b), _ = query(text_or_box)
        assert found, text_or_box
    else:
        l, t, r, b = text_or_box
    body, _, ms = a.call(b"\x2e" + i((l + r) // 2, (t + b) // 2, hold))
    return struct.unpack(">I", body[:4])[0] / 1000, ms

def idle(mode, timeout=2500):
    body, _, ms = a.call(b"\x2b" + bytes([mode]) + i(timeout))
    ok = body[0]; since, waited, checks = struct.unpack_from(">III", body, 1)
    return ok, since / 1000, waited / 1000, checks, ms

print("== Transport: 200 PINGs")
report("round trip (host)", [a.call(b"\x01")[2] for _ in range(200)])

state = a.call(b"\x28" + s("com.apple.Preferences"))[0][0]
print(f"== Target app: com.apple.Preferences, state {state} (4 = running foreground)")

print("== Full hierarchy (Settings home)")
for mode, name in [(0, "snapshot() + walk"), (1, "snapshot().dictionaryRepresentation + walk")]:
    host, snap, walk, counts = [], [], [], []
    for _ in range(10):
        body, _, ms = a.call(b"\x29" + bytes([mode]))
        c, su, wu = struct.unpack_from(">III", body)
        host.append(ms); snap.append(su / 1000); walk.append(wu / 1000); counts.append(c)
    report(f"{name}: total (host)", host)
    report("    snapshot", snap)
    report("    walk + encode", walk)
    print(f"    nodes: {counts[0]}")

print("== Targeted lookup: first element labelled \"General\"")
for mode, name in [(0, "firstMatch.exists + .frame"), (1, "firstMatch.snapshot().frame"), (2, "firstMatch.exists")]:
    report(name, [query("General", mode)[2] for _ in range(10)])
report("firstMatch.exists, no such element", [query("Nope", 2)[2] for _ in range(3)])

print("== Screenshot")
report("XCUIScreen.main.screenshot() png (host)", [a.call(b"\x0e")[2] for _ in range(5)])

print("== Tap: synthesized event, delivery time")
for hold in (100, 20):
    xs = []
    for _ in range(4):
        inj, _ = tap("General", hold); idle(2, 1500); xs.append(inj)
        inj2, _ = tap("BackButton", hold); idle(2, 1500); xs.append(inj2)
    report(f"hold {hold} ms: synthesize -> completion", xs)

print("== Settle after a tap (General, then back): when it ends, measured from the tap")
ref_in, ref_back = [], []
for _ in range(5):
    tap("General"); ref_in.append(idle(2, 2000)[1])
    tap("BackButton"); ref_back.append(idle(2, 2000)[1])
report("reference: last screen change (screenshots for 2 s), push", ref_in)
report("reference: last screen change, pop", ref_back)
for mode, name in [(0, "XCTest quiescence (event loop + animations idle)"), (1, "Maestro isScreenStatic (2 screenshots, equal)")]:
    since_in, since_back, checks = [], [], []
    for _ in range(5):
        tap("General"); r = idle(mode); since_in.append(r[1]); checks.append(r[3])
        tap("BackButton"); r = idle(mode); since_back.append(r[1]); checks.append(r[3])
    report(f"{name}, push", since_in)
    report(f"{name}, pop", since_back)
    print(f"    checks per settle: median {med(checks)}")

print("== Typing into the search field")
tap("magnifyingglass"); idle(0)
for rate in (30, 1000):
    body, _, _ = a.call(b"\x2f" + s("Speedrun bench") + i(rate))
    typed = struct.unpack(">I", body[:4])[0] / 1000
    found = query("Speedrun bench", 2)[0]
    body, _, _ = a.call(b"\x2f" + s("\b" * 25) + i(rate))
    erased = struct.unpack(">I", body[:4])[0] / 1000
    cleared = not query("Speedrun bench", 2)[0]
    print(f"  {rate:5d} chars/s: type 14 chars {typed:7.1f} ms (field shows it: {bool(found)}), "
          f"erase 25 {erased:7.1f} ms (cleared: {cleared})")
tap("close"); idle(0)
