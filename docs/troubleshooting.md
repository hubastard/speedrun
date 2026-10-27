# Troubleshooting

- **The first iOS run takes a few seconds.** Speedrun starts its agent on the simulator
  (3–6 s) and keeps it running, so later runs start in about 0.2 s. It stops after 10 idle
  minutes, or with `speedrun --stop-agent`.
- **"Another UiAutomation client is running on the device".** Android allows only one UI
  automation tool at a time. Speedrun stops Maestro's leftover driver itself; stop any other
  tool (Appium, `uiautomator`, an instrumentation test) before running.
- **Slow or flaky runs on a busy machine.** An emulator stalls when the host is short of
  memory or CPU. Shut iOS simulators down while testing on Android (run
  `speedrun --stop-agent` first), and rerun before trusting a failure.
- **The iOS agent does not start.** A release's agent is built with one Xcode (the archive's
  `README.txt` names it). With a much different Xcode, build Speedrun from source. The
  agent's own log is `$TMPDIR/speedrun-ios-runner-7778.log`.
- **More detail:** `SPEEDRUN_DEBUG=1 speedrun test …` prints every screen read and shell
  command with its time, and for each tap what lies at its point. Agent logs on Android:
  `adb logcat -s SpeedrunAgent`.
