# The agent-tools benchmark: the same steps an AI agent takes on Speedrun Bench, driven through
# Speedrun's session, agent-device and Argent, each from its command line and with its own
# recommended loop: a fresh launch, skip the onboarding, continue as a guest, open the shop,
# search "sneaker", check "6 products", open "City Sneaker", check its sizes show. No model in
# the loop: the script makes the calls an agent would, so every run makes the same ones.
#
# Per run: the wall time, the number of calls, and everything the tools printed, which an agent
# reads (characters, and ~tokens as characters / 4). Results in results/<platform>-<tool>.*.
#   npm install                                   # agent-device and Argent, pinned (package.json)
#   python3 bench.py android|ios [tool...] [--runs N]   tools: speedrun agent-device argent
# The device: DEVICE=<serial or simulator UDID>, else the first adb device (Android) or the
# booted simulator (iOS). Speedrun Bench installed (../app/bench.sh install <platform>).
import json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SPEEDRUN = os.path.join(HERE, '..', '..', 'speedrun')
AD = os.path.join(HERE, 'node_modules', '.bin', 'agent-device')
ARGENT = os.path.join(HERE, 'node_modules', '.bin', 'argent')
IOS_APP = os.path.join(HERE, '..', 'app', 'prebuilt', 'SpeedrunBench.app')
APP = 'dev.speedrun.bench'
ENV = dict(os.environ, DO_NOT_TRACK='1')  # Argent's usage stats off
RUNNERS = ['com.callstack.agentdevice.runner.uitests.xctrunner']  # iOS UI test runners besides Speedrun's


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors='replace', env=ENV)


class Calls:
    """Runs the tools' commands: their time and what they printed."""
    def __init__(self):
        self.n, self.chars, self.biggest, self.log = 0, 0, 0, []

    def __call__(self, *cmd):
        t = time.time()
        p = sh(*cmd)
        out = p.stdout + p.stderr
        self.n += 1
        self.chars += len(out)
        self.biggest = max(self.biggest, len(out))
        self.log.append(f'{time.time() - t:6.2f} s {len(out):6d} ch  {" ".join(cmd[1:])[:90]}')
        if p.returncode != 0:
            raise RuntimeError(f'{" ".join(cmd[1:])} exited {p.returncode}: {out[-600:]}')
        return out


def speedrun(c, platform, dev):
    c(SPEEDRUN, 'do', 'launchApp')
    c(SPEEDRUN, 'look')
    for step in ['tapOn: {id: onboarding-skip}', 'tapOn: {id: guest}', 'tapOn: {id: tab-shop}',
                 'tapOn: {id: search-input}', 'inputText: sneaker', 'pressKey: Enter',
                 'assertVisible: "6 products"', 'tapOn: "City Sneaker"', 'assertVisible: {id: size-M}']:
        c(SPEEDRUN, 'do', step)


def agent_device(c, platform, dev):
    target = ['--platform', 'android', '--serial', dev] if platform == 'android' else ['--platform', 'ios', '--udid', dev]
    c(AD, 'open', APP, *target, '--foreground')
    if platform == 'ios':
        # open returns before the app has drawn its first screen (its snapshot is empty): the
        # agent waits for what it expects.
        c(AD, 'wait', 'id="onboarding-skip"')
    for sel in ['id="onboarding-skip"', 'id="guest"', 'id="tab-shop"']:
        c(AD, 'click', sel, '--settle')
    c(AD, 'fill', 'id="search-input"', 'sneaker', '--settle')
    if platform == 'android':
        c(AD, 'keyboard', 'enter')
    else:
        c(AD, 'type', '\n')  # its keyboard command is Android's; on iOS a newline submits
    c(AD, 'wait', 'text', '6 products')
    c(AD, 'click', 'label="City Sneaker"', '--settle')
    c(AD, 'wait', 'id="size-M"')
    c(AD, 'close')


def argent(c, platform, dev):
    def tool(name, **args):
        return c(ARGENT, 'run', name, '--args', json.dumps(dict(udid=dev, **args)))

    def tap(id=None, label=None):
        # What the agent does: read the screen, find the element, tap its frame's centre (the
        # coordinates describe gives). Read again while the screen does not show it yet. By its
        # id, else by its label: on iOS describe leaves some ids out ("Skip" has none).
        for _ in range(15):
            lines = json.loads(tool('describe'))['description'].split('\n')
            found = [l for l in lines if id and f'id="{id}"' in l] or \
                    [l for l in lines if label and re.search(rf'^\s*\S+ "{re.escape(label)}"', l)]
            for line in found:
                m = re.search(r'\(([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\)\s*$', line)
                if not m: continue
                x, y, w, h = map(float, m.groups())
                tool('gesture-tap', x=round(x + w / 2, 4), y=round(y + h / 2, 4))
                idle()
                return
        raise RuntimeError(f'not on screen: {id or label}')

    def idle():
        # Argent's guide: after a launch or a navigation, before a raw tap (a tap does not wait
        # for the app, and one during a screen's slide-in was lost on iOS).
        tool('await-screen-idle', timeoutMs=3000, minStableMs=250)

    def check(selector):
        out = json.loads(tool('await-ui-element', selector=selector, condition='visible', timeoutMs=10000))
        if not out.get('success'):
            raise RuntimeError(f'{selector}: {out}')

    tool('launch-app', bundleId=APP)
    idle()
    tap(id='onboarding-skip', label='Skip')
    tap(id='guest', label='Continue as guest')
    tap(id='tab-shop', label='Shop')
    tap(id='search-input', label='Search products')
    tool('keyboard', text='sneaker')
    tool('keyboard', key='enter')
    check({'text': '6 products'})
    tap(label='City Sneaker')
    check({'identifier': 'size-M'})


TOOLS = {'speedrun': speedrun, 'agent-device': agent_device, 'argent': argent}


def reset_app(platform, dev):
    if platform == 'android':
        sh('adb', '-s', dev, 'shell', 'pm', 'clear', APP)
    else:
        sh('xcrun', 'simctl', 'uninstall', dev, APP)
        sh('xcrun', 'simctl', 'install', dev, IOS_APP)


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


def main():
    args = sys.argv[1:]
    runs = 3
    if '--runs' in args:
        i = args.index('--runs'); runs = int(args[i + 1]); del args[i:i + 2]
    platform, tools = args[0], args[1:] or list(TOOLS)
    if platform == 'android':
        dev = os.environ.get('DEVICE') or next(l.split()[0] for l in sh('adb', 'devices').stdout.splitlines()[1:] if l.endswith('device'))
    else:
        dev = os.environ.get('DEVICE') or re.search(r'\(([0-9A-F-]{36})\) \(Booted\)', sh('xcrun', 'simctl', 'list', 'devices', 'booted').stdout).group(1)
    os.makedirs(os.path.join(HERE, 'results'), exist_ok=True)
    table = []
    for name in tools:
        stop_others(platform, dev)
        if name == 'speedrun':
            sh(SPEEDRUN, 'session', 'start', '--app', APP, '--device', dev)
        times, rows = [], []
        for i in range(runs + 1):  # run 0 warms up: agents installed and started, not counted
            reset_app(platform, dev)
            c = Calls()
            t = time.time()
            status = 'passed'
            try:
                TOOLS[name](c, platform, dev)
            except Exception as e:
                status = f'FAILED: {e}'
            secs = time.time() - t
            label = 'warm-up' if i == 0 else f'run {i}'
            print(f'{platform} {name} {label}: {secs:.1f} s, {status[:200]}, {c.n} calls, {c.chars} chars (~{c.chars // 4} tokens), largest {c.biggest}', flush=True)
            with open(os.path.join(HERE, 'results', f'{platform}-{name}-{i}.log'), 'w') as f:
                f.write('\n'.join(c.log) + '\n')
            if i > 0:
                rows.append(dict(secs=round(secs, 2), calls=c.n, chars=c.chars, biggest=c.biggest, status=status))
        stop_others(platform, dev)
        passed = sorted(r['secs'] for r in rows if r['status'] == 'passed')
        median = passed[len(passed) // 2] if passed else None
        table.append((name, median, len(passed), rows))
        json.dump(rows, open(os.path.join(HERE, 'results', f'{platform}-{name}.json'), 'w'), indent=1)
    print(f'\n| Tool ({platform}) | Median of passed runs | Passed | Calls | Printed, ~tokens | Largest output |')
    print('|---|---:|---:|---:|---:|---:|')
    for name, median, n, rows in table:
        r = rows[-1]
        print(f'| {name} | {median if median is not None else "-"} s | {n}/{len(rows)} | {r["calls"]} | {r["chars"]} ch, ~{r["chars"] // 4} | {r["biggest"]} ch |')


if __name__ == '__main__':
    main()
