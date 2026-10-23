# Typing knobs vs. dropped characters: Settings' search field, TYPE_TEST with each
# (first-character rate, rest rate, wait cap), then the field's value read back.
import os, statistics, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_client import Agent, s, i, nodes

a = Agent()
def screen():
    body, _, _ = a.call(b"\x0a"); n, = struct.unpack_from(">I", body); return nodes(body, 4, n)
def center(key):
    for d, (l, t, r, b), f, text, desc, vid, *_ in screen():
        if key in (text, desc, vid): return (l + r) // 2, (t + b) // 2
def settle():
    a.call(b"\x05" + i(34, 1000, 10000))
def type_test(text, first, rest, cap):
    body, _, ms = a.call(b"\x31" + s(text) + i(first, rest, cap)); return ms
def field_value():
    for d, box, f, text, desc, vid, cls, *_ in screen():
        if cls == "SearchField": return text
    return None

TEXT = "Speedrun bench"
for first, rest, cap in [(1, 30, 500), (30, 30, 500), (30, 60, 500), (30, 100, 500), (100, 100, 500), (30, 300, 500), (100, 300, 0)]:
    times, ok, values = [], 0, []
    for _ in range(5):
        type_test("\b" * 30, 30, 30, 500); settle()
        times.append(type_test(TEXT, first, rest, cap)); settle()
        v = field_value(); values.append(v); ok += v == TEXT
    bad = sorted(set(v for v in values if v != TEXT))
    print(f"  first {first:3d}/s, rest {rest:3d}/s, wait cap {cap:3d} ms: {statistics.median(times):6.0f} ms, correct {ok}/5  {bad}")
type_test("\b" * 30, 30, 30, 500); settle()
print("  erase 25 on an empty field, Maestro's way:", round(type_test("\b" * 25, 1, 30, 500)), "ms")
a.call(b"\x03" + i(*center("close"))); settle()
