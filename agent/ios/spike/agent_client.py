# Client for the iOS agent (agent/ios/SpeedrunAgentUITests/Agent.swift): framing as the Android agent (u8 op + fields; u32 len, u32 agent_us, body).
import socket, struct, time
class Agent:
    def __init__(self, port=7778, timeout=60):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    def _recv(self, n):
        b = b""
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c: raise EOFError("agent closed the connection")
            b += c
        return b
    def call(self, req):
        t = time.perf_counter(); self.s.sendall(req)
        n, = struct.unpack(">I", self._recv(4)); body = self._recv(n)
        return body[4:], struct.unpack(">I", body[:4])[0], (time.perf_counter() - t) * 1000
def s(x): b = x.encode(); return struct.pack(">H", len(b)) + b
def i(*v): return struct.pack(">" + "i" * len(v), *v)
def nodes(body, off, count):
    out = []
    for _ in range(count):
        d, l, t, r, b, f = struct.unpack_from(">HiiiiB", body, off); off += 19; strs = []
        for _ in range(6):
            n, = struct.unpack_from(">H", body, off); off += 2; strs.append(body[off:off+n].decode()); off += n
        out.append((d, (l, t, r, b), f, *strs))
    return out
