# The Settings benchmarks on tester-army's e2e

[`bench_scenario.yaml`](../../bench_scenario.yaml) and
[`bench_scenario_ios.yaml`](../../bench_scenario_ios.yaml) ported to
[e2e](https://github.com/tester-army/e2e): one awaited call per command, locators and
assertions only, so no model. Each test prints its steps' median times.

```
npm install
npm run android                                   # the emulator, or DEVICE=<serial>
TIMES=3 DEVICE="iPhone 17 Pro" npm run ios        # a booted simulator, Settings in English
```

TIMES sets the laps (3 by default). The scripts turn e2e's telemetry off. e2e installs helper
apps on the device (`com.callstack.agentdevice.*`) and keeps a background process and an iOS
test runner between runs; stop speedrun's iOS agent (`./speedrun --stop-agent`) before an
iOS run, and e2e's runner before speedrun's.
