# The agent-tools benchmark: the steps an AI agent takes to try out a feature of an app, driven
# through Speedrun, agent-device and Argent, each with its own recommended loop. No model in the
# loop: the script makes the calls an agent would, so every run makes the same ones.
#
# Two tasks: on Speedrun Bench (../app), skip the onboarding, continue as a guest, search the
# shop for "sneaker", check "6 products", open "City Sneaker", check its sizes; on a neutral app
# (tester-army's mobile-benchmark, made by others: NEUTRAL_APP), open Login Form, fill an
# unknown account, submit, check "Invalid credentials".
#
# Per run: the wall time, its session set-up and close included, the number of calls, and
# everything the tools answered, which an agent reads (characters, ~tokens as characters / 4,
# and images, ~tokens as width x height / 750). Results in results/.
#   npm install                       # agent-device and Argent, pinned (package.json)
#   python3 bench.py android|ios [tool...] [--via mcp|cli] [--app bench|neutral]
#                    [--animations normal|default|fast] [--runs N]
# --via: each tool's MCP server (started once per tool, as an agent's client does) or its
# command line (a process per call). --animations (iOS): normal, every app at UIKit's normal
# speed (Speedrun's 10x turned off); default, each tool as it comes (Speedrun runs the app's
# animations 10x faster, the others at normal speed); fast, every tool launching the app with
# Speedrun's 10x (-UIAnimationDragCoefficient 0.1 and the UIKit/UIPreferences feature flag). On Android
# the animation scales are set to 0 before each tool (Speedrun turns them off on its own).
# The device: DEVICE=<serial or simulator UDID>, else the first adb device (Android) or the
# booted simulator (iOS).
import base64, json, os, queue, re, struct, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
SPEEDRUN = os.path.join(HERE, '..', '..', 'speedrun')
AD = os.path.join(HERE, 'node_modules', '.bin', 'agent-device')
ARGENT = os.path.join(HERE, 'node_modules', '.bin', 'argent')
ENV = dict(os.environ, DO_NOT_TRACK='1')  # Argent's usage stats off
RUNNERS = ['com.callstack.agentdevice.runner.uitests.xctrunner']  # iOS UI test runners besides Speedrun's
FAST_ARGS = ['-UIAnimationDragCoefficient', '0.1']
FAST_ENV = {'SIMCTL_CHILD_FEATUREFLAGS_ENABLED': 'UIKit/UIPreferences'}
# The neutral app: tester-army/e2e's apps/mobile-benchmark, built for Release (see README.md).
NEUTRAL = os.environ.get('NEUTRAL_APP', '')

# A task: its app, how to install it, and its steps. ('tap', id, label): an element by its id,
# by its label when id is None (Argent also falls back to the label: its iOS tree leaves some
# ids out); ('fill', id, label, text): tap a field and type; ('enter',); ('text', t) and
# ('id', x): check that it shows.
TASKS = {
    'bench': dict(
        app='dev.speedrun.bench',
        ios=os.path.join(HERE, '..', 'app', 'prebuilt', 'SpeedrunBench.app'),
        android=None,  # ../app/bench.sh install android
        first='onboarding-skip',
        steps=[('tap', 'onboarding-skip', 'Skip'), ('tap', 'guest', 'Continue as guest'),
               ('tap', 'tab-shop', 'Shop'), ('fill', 'search-input', 'Search products', 'sneaker'),
               ('enter',), ('text', '6 products'), ('tap', None, 'City Sneaker'), ('id', 'size-M')]),
    'neutral': dict(
        app='dev.e2e.benchmark',
        ios=os.path.join(NEUTRAL, 'ios', 'build', 'Build', 'Products', 'Release-iphonesimulator', 'e2eBenchmark.app'),
        android=os.path.join(NEUTRAL, 'android', 'app', 'build', 'outputs', 'apk', 'release', 'app-release.apk'),
        first='Login Form',
        steps=[('tap', 'Login Form', 'Login Form. '), ('fill', 'email-input', 'Email', 'someone@example.com'),
               ('fill', 'password-input', 'Password', 'benchmark-pass'), ('enter',),
               ('tap', 'login-button', 'Log in'), ('text', 'Invalid credentials')]),
}


def sh(*cmd, env=ENV):
    return subprocess.run(cmd, capture_output=True, text=True, errors='replace', env=env)


def image_tokens(data):
    """What an image costs a model: Claude's estimate, width x height / 750, after it scales the
    image to at most 1568 pixels on its long side."""
    raw = base64.b64decode(data)
    w = h = 0
    if raw[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', raw[16:24])
    elif raw[:2] == b'\xff\xd8':
        i = 2
        while i < len(raw) - 9:
            marker, size = raw[i + 1], struct.unpack('>H', raw[i + 2:i + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack('>HH', raw[i + 5:i + 9])
                break
            i += 2 + size
    scale = min(1, 1568 / max(w, h, 1))
    return int(w * scale * h * scale / 750)


class Mcp:
    """A stdio MCP client, as an agent's: started once, then one request per tool call."""
    def __init__(self, cmd, env, log):
        self.log = open(log, 'w')
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                  text=True, env=env, cwd=HERE)
        self.lines, self.id = queue.Queue(), 0
        threading.Thread(target=self._read, daemon=True).start()
        self.request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                    'clientInfo': {'name': 'speedrun-agent-bench', 'version': '1'}})
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def _read(self):
        for line in self.p.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _send(self, m):
        self.p.stdin.write(json.dumps(m) + '\n')
        self.p.stdin.flush()

    def request(self, method, params, timeout=180):
        self.id += 1
        self._send({'jsonrpc': '2.0', 'id': self.id, 'method': method, 'params': params})
        end = time.time() + timeout
        while True:
            line = self.lines.get(timeout=max(0.1, end - time.time()))
            if line is None:
                raise RuntimeError('the MCP server exited')
            m = json.loads(line)
            if 'method' in m and 'id' in m:  # a request from the server: nothing to offer
                self._send({'jsonrpc': '2.0', 'id': m['id'], 'error': {'code': -32601, 'message': 'not supported'}})
            elif m.get('id') == self.id:
                if 'error' in m:
                    raise RuntimeError(f'{method}: {m["error"]}')
                return m['result']

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        self.log.close()


class Calls:
    """Makes a tool's calls, by MCP or command line, and keeps their time and what they answered."""
    def __init__(self, mcp=None):
        self.mcp, self.n, self.chars, self.images, self.image_tokens, self.biggest, self.log = mcp, 0, 0, 0, 0, 0, []

    def _count(self, t, what, text, images=0, itokens=0):
        self.n += 1
        self.chars += len(text)
        self.images += images
        self.image_tokens += itokens
        self.biggest = max(self.biggest, len(text))
        extra = f' +{images} image(s) ~{itokens} tokens' if images else ''
        self.log.append(f'{time.time() - t:6.2f} s {len(text):6d} ch{extra}  {what[:100]}')

    def cli(self, *cmd):
        t = time.time()
        p = sh(*cmd)
        out = p.stdout + p.stderr
        self._count(t, ' '.join(cmd[1:]), out)
        if p.returncode != 0:
            raise RuntimeError(f'{" ".join(cmd[1:])} exited {p.returncode}: {out[-600:]}')
        return out

    def tool(self, name, args):
        t = time.time()
        r = self.mcp.request('tools/call', {'name': name, 'arguments': args})
        texts, images, itokens = [], 0, 0
        for c in r.get('content', []):
            if c.get('type') == 'text':
                texts.append(c['text'])
            elif c.get('type') == 'image':
                images += 1
                itokens += image_tokens(c['data'])
        text = '\n'.join(texts)
        self.blocks = texts
        self._count(t, f'{name} {json.dumps(args)}', text, images, itokens)
        if r.get('isError'):
            raise RuntimeError(f'{name} {json.dumps(args)}: {text[-600:]}')
        return text


class Speedrun:
    def __init__(self, c, platform, dev, task, via, animations):
        self.c, self.platform, self.dev, self.task, self.via = c, platform, dev, task, via
        # normal: UIKit's own speed, the flow's argument turning Speedrun's 10x off
        self.launch_cmd = 'launchApp: {arguments: {UIAnimationDragCoefficient: 1}}' \
            if platform == 'ios' and animations == 'normal' else 'launchApp'

    def do(self, command):
        if self.via == 'mcp':
            return self.c.tool('run', {'commands': command})
        return self.c.cli(SPEEDRUN, 'do', command)

    def launch(self):
        if self.via == 'mcp':
            self.c.tool('session_start', {'app': self.task['app'], 'platform': self.platform, 'device': self.dev})
        else:
            self.c.cli(SPEEDRUN, 'session', 'start', '--app', self.task['app'], '--device', self.dev)
        self.do(self.launch_cmd)
        self.c.tool('look', {}) if self.via == 'mcp' else self.c.cli(SPEEDRUN, 'look')

    def tap(self, id, label):
        self.do(f'tapOn: {{id: "{id}"}}' if id else f'tapOn: "{label}"')

    def fill(self, id, label, text):
        self.tap(id, label)
        self.do(f'inputText: "{text}"')

    def enter(self):
        self.do('pressKey: Enter')

    def text(self, t):
        self.do(f'assertVisible: "{t}"')

    def id(self, x):
        self.do(f'assertVisible: {{id: "{x}"}}')

    def end(self):
        self.c.tool('session_stop', {}) if self.via == 'mcp' else self.c.cli(SPEEDRUN, 'session', 'stop')


class AgentDevice:
    def __init__(self, c, platform, dev, task, via, animations):
        self.c, self.platform, self.dev, self.task, self.via = c, platform, dev, task, via
        self.fast = platform == 'ios' and animations == 'fast'
        if self.fast and via == 'cli':
            raise SystemExit('--animations fast: by MCP only for agent-device')

    def call(self, name, args, cli):
        return self.c.tool(name, args) if self.via == 'mcp' else self.c.cli(AD, *cli)

    def launch(self):
        target = {'platform': self.platform, 'serial' if self.platform == 'android' else 'udid': self.dev}
        args = dict(app=self.task['app'], foreground=True, **target)
        if self.fast:
            args['launchArgs'] = FAST_ARGS
        flags = ['--platform', self.platform, '--serial' if self.platform == 'android' else '--udid', self.dev]
        self.call('open', args, ['open', self.task['app'], *flags, '--foreground'])
        if self.platform == 'ios':
            # open returns before the app has drawn its first screen (its snapshot is empty): the
            # agent waits for what it expects.
            self.id(self.task['first'])

    @staticmethod
    def selector(id, label):
        return f'id="{id}"' if id else f'label="{label}"'

    def tap(self, id, label):
        sel = self.selector(id, label)
        self.call('click', {'target': {'kind': 'selector', 'selector': sel}, 'settle': True}, ['click', sel, '--settle'])

    def fill(self, id, label, text):
        sel = self.selector(id, label)
        self.call('fill', {'target': {'kind': 'selector', 'selector': sel}, 'text': text, 'settle': True},
                  ['fill', sel, text, '--settle'])

    def enter(self):
        if self.platform == 'android':
            self.call('keyboard', {'action': 'enter'}, ['keyboard', 'enter'])
        else:  # its keyboard command is Android's; on iOS a newline submits
            self.call('type', {'text': '\n'}, ['type', '\n'])

    def text(self, t):
        self.call('wait', {'kind': 'text', 'text': t}, ['wait', 'text', t])

    def id(self, x):
        self.call('wait', {'kind': 'selector', 'selector': f'id="{x}"'}, ['wait', f'id="{x}"'])

    def end(self):
        self.call('close', {}, ['close'])


class Argent:
    # By MCP, Argent's server answers every action with the screen after it: it waits for the
    # screen to go idle (up to 1.5 s after a tap, 3 s after a launch), then attaches a
    # screenshot and the element tree. Its rules: tap from that tree, describe only when there
    # is no fresh one. By command line, an action answers only that it ran: the agent waits for
    # the screen to go idle and reads it itself (describe), as its guide says.
    TREE = '--- Elements after action (describe) ---'

    def __init__(self, c, platform, dev, task, via, animations):
        self.c, self.platform, self.dev, self.task, self.via = c, platform, dev, task, via
        self.fast = platform == 'ios' and animations == 'fast'
        self.tree = None  # the element tree the last answer brought (MCP)

    def tool(self, name, **args):
        args = dict(udid=self.dev, **args)
        if self.via == 'mcp':
            self.c.tool(name, args)
            out = self.c.blocks[0] if self.c.blocks else ''  # its answer; then the screen after it
            trees = [b for b in self.c.blocks if b.startswith(self.TREE)]
            if trees:
                self.tree = trees[-1]
        else:
            out = self.c.cli(ARGENT, 'run', name, '--args', json.dumps(args))
        try:
            return json.loads(out)
        except ValueError:
            return out

    def launch(self):
        self.tool('launch-app', bundleId=self.task['app'], **({'launchArgs': FAST_ARGS} if self.fast else {}))
        if self.via == 'cli':
            self.idle()

    def idle(self):
        # Argent's guide: after a launch or a navigation, before a raw tap (a tap does not wait
        # for the app, and one during a screen's slide-in was lost on iOS).
        self.tool('await-screen-idle', timeoutMs=3000, minStableMs=250)

    def tap(self, id, label):
        # What the agent does: find the element in the screen's tree and tap its frame's centre.
        # By its id, else by its label (its start): on iOS the tree leaves some ids out. The
        # tree: the last answer's (MCP), else a describe, again while the target is not there.
        for attempt in range(15):
            if self.via == 'mcp' and attempt == 0 and self.tree:
                tree = self.tree
            else:
                d = self.tool('describe')
                tree = d['description'] if isinstance(d, dict) else d
            found = [l for l in tree.split('\n') if id and f'id="{id}"' in l] or \
                    [l for l in tree.split('\n') if label and re.search(rf'^\s*\S+ "{re.escape(label)}', l)]
            for line in found:
                m = re.search(r'\(([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\)\s*$', line)
                if not m: continue
                x, y, w, h = map(float, m.groups())
                self.tool('gesture-tap', x=round(x + w / 2, 4), y=round(y + h / 2, 4))
                if self.via == 'cli':
                    self.idle()
                return
        raise RuntimeError(f'not on screen: {id or label}')

    def fill(self, id, label, text):
        self.tap(id, label)
        self.tool('keyboard', text=text)

    def enter(self):
        self.tool('keyboard', key='enter')

    def check(self, selector):
        out = self.tool('await-ui-element', selector=selector, condition='visible', timeoutMs=10000)
        if not (isinstance(out, dict) and out.get('success')):
            raise RuntimeError(f'{selector}: {out}')

    def text(self, t):
        self.check({'text': t})

    def id(self, x):
        self.check({'identifier': x})

    def end(self):
        pass  # no session: its tool server stays up, as it does for an agent


TOOLS = {'speedrun': Speedrun, 'agent-device': AgentDevice, 'argent': Argent}
SERVERS = {'speedrun': [SPEEDRUN, 'mcp'], 'agent-device': [AD, 'mcp'], 'argent': [ARGENT, 'mcp']}


def run_task(tool):
    tool.launch()
    for step in tool.task['steps']:
        getattr(tool, step[0])(*step[1:])
    tool.end()


def reset_app(platform, dev, task):
    if platform == 'android':
        sh('adb', '-s', dev, 'shell', 'pm', 'clear', task['app'])
    else:
        sh('xcrun', 'simctl', 'uninstall', dev, task['app'])
        sh('xcrun', 'simctl', 'install', dev, task['ios'])


def stop_others(platform, dev):
    """Only one UI automation client at a time (Android's UiAutomation, one UI test runner per
    simulator): every tool's background service is stopped before the next tool."""
    sh(SPEEDRUN, 'session', 'stop')
    sh(SPEEDRUN, '--stop-agent')
    sh(AD, 'close')
    sh('pkill', '-f', 'node_modules/agent-device')
    sh(ARGENT, 'run', 'stop-all-simulator-servers', '--args', '{}')
    sh(ARGENT, 'server', 'stop')
    if platform == 'ios':
        for runner in RUNNERS:
            sh('xcrun', 'simctl', 'terminate', dev, runner)
    else:
        sh('adb', '-s', dev, 'shell', 'settings put global window_animation_scale 0; '
           'settings put global transition_animation_scale 0; settings put global animator_duration_scale 0')


def option(args, name, default, choices=None):
    if name not in args:
        return default
    i = args.index(name)
    value = args[i + 1]
    del args[i:i + 2]
    if choices and value not in choices:
        raise SystemExit(f'{name}: one of {", ".join(choices)}')
    return value


def main():
    args = sys.argv[1:]
    runs = int(option(args, '--runs', '3'))
    via = option(args, '--via', 'mcp', ['mcp', 'cli'])
    task_name = option(args, '--app', 'bench', list(TASKS))
    animations = option(args, '--animations', 'normal', ['normal', 'default', 'fast'])
    platform, tools = args[0], args[1:] or list(TOOLS)
    task = TASKS[task_name]
    if task_name == 'neutral' and not NEUTRAL:
        raise SystemExit('--app neutral: NEUTRAL_APP=<tester-army/e2e checkout>/apps/mobile-benchmark, built (README.md)')
    if platform == 'android':
        dev = os.environ.get('DEVICE') or next(l.split()[0] for l in sh('adb', 'devices').stdout.splitlines()[1:] if l.endswith('device'))
        if task['android']:
            sh('adb', '-s', dev, 'install', '-r', task['android'])
    else:
        dev = os.environ.get('DEVICE') or re.search(r'\(([0-9A-F-]{36})\) \(Booted\)', sh('xcrun', 'simctl', 'list', 'devices', 'booted').stdout).group(1)
        motion = sh('xcrun', 'simctl', 'spawn', dev, 'defaults', 'read', 'com.apple.Accessibility', 'ReduceMotionEnabled').stdout.strip()
        if motion == '1':
            raise SystemExit('Reduce Motion is on in the simulator: turn it off first')
    label = f'{platform}-{task_name}-{via}' + (f'-{animations}' if platform == 'ios' else '')
    out = os.path.join(HERE, 'results')
    os.makedirs(out, exist_ok=True)
    table = []
    for name in tools:
        stop_others(platform, dev)
        env = dict(ENV, **FAST_ENV) if platform == 'ios' and animations == 'fast' else ENV
        mcp = Mcp(SERVERS[name], env, os.path.join(out, f'{label}-{name}.server.log')) if via == 'mcp' else None
        times, rows = [], []
        for i in range(runs + 1):  # run 0 warms up: agents installed and started, not counted
            reset_app(platform, dev, task)
            c = Calls(mcp)
            t = time.time()
            status = 'passed'
            try:
                run_task(TOOLS[name](c, platform, dev, task, via, animations))
            except Exception as e:
                status = f'FAILED: {e}'
            secs = time.time() - t
            run = 'warm-up' if i == 0 else f'run {i}'
            print(f'{label} {name} {run}: {secs:.1f} s, {status[:300]}, {c.n} calls, {c.chars} chars (~{c.chars // 4} tokens)'
                  + (f', {c.images} images (~{c.image_tokens} tokens)' if c.images else '') + f', largest {c.biggest}', flush=True)
            with open(os.path.join(out, f'{label}-{name}-{i}.log'), 'w') as f:
                f.write('\n'.join(c.log) + '\n')
            if i > 0:
                rows.append(dict(secs=round(secs, 2), calls=c.n, chars=c.chars, images=c.images,
                                 image_tokens=c.image_tokens, biggest=c.biggest, status=status))
            if status != 'passed' and name == 'speedrun':
                sh(SPEEDRUN, 'session', 'stop')
            elif status != 'passed' and name == 'agent-device':
                sh(AD, 'close')
        if mcp:
            mcp.close()
        stop_others(platform, dev)
        passed = sorted(r['secs'] for r in rows if r['status'] == 'passed')
        median = passed[len(passed) // 2] if passed else None
        table.append((name, median, len(passed), rows))
        json.dump(rows, open(os.path.join(out, f'{label}-{name}.json'), 'w'), indent=1)
    print(f'\n| Tool ({label}) | Median of passed runs | Runs | Passed | Calls | Text, ~tokens | Images, ~tokens | Largest answer |')
    print('|---|---:|---|---:|---:|---:|---:|---:|')
    for name, median, n, rows in table:
        r = rows[-1]
        print(f'| {name} | {median if median is not None else "-"} s | {", ".join(str(x["secs"]) for x in rows)} | {n}/{len(rows)} | '
              f'{r["calls"]} | {r["chars"]} ch, ~{r["chars"] // 4} | {r["images"]}, ~{r["image_tokens"]} | {r["biggest"]} ch |')


if __name__ == '__main__':
    main()
