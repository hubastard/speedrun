// bench_scenario.yaml: one awaited call per command. TIMES laps (default 3).
import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { timer } from './timing';

const TIMES = Number(process.env.TIMES ?? 3);

test('bench_scenario', { timeout: 600_000 }, async ({ app, screen, device }) => {
  const { step, report } = timer();
  await step('launchApp', () => app.open());
  for (let i = 0; i < TIMES; i++) {
    await step('tap Display & touch', () => screen.getByText('Display & touch').tap());
    await step('tap Display size & text', () => screen.getByText('Display size & text').tap());
    await step('assertVisible Bold text', () => expect(screen.getByText('Bold text')).toBeVisible());
    await step('back', () => device.back());
    await step('back', () => device.back());
    await step('scroll down', () => screen.scrollUntilVisible(screen.getByText('About emulated device'), { direction: 'down' }));
    await step('tap About emulated device', () => screen.getByText('About emulated device').tap());
    await step('tap Device name', () => screen.getByText('Device name').tap());
    await step('erase', () => screen.getByRole('textbox').clear());
    await step('input', () => screen.getByRole('textbox').fill('Speedrun bench'));
    await step('assertVisible Speedrun bench', () => expect(screen.getByText('Speedrun bench')).toBeVisible());
    await step('tap Cancel', () => screen.getByText('Cancel').tap());
    await step('back', () => device.back());
    await step('scroll up', () => screen.scrollUntilVisible(screen.getByText('Network & internet'), { direction: 'up' }));
  }
  report();
});
