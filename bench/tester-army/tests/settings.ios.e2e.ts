// bench_scenario_ios.yaml: one awaited call per command. TIMES laps (default 3).
import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { timer } from './timing';

const TIMES = Number(process.env.TIMES ?? 3);

test('bench_scenario_ios', { timeout: 600_000 }, async ({ app, screen }) => {
  const { step, report } = timer();
  await step('launchApp', () => app.open());
  for (let i = 0; i < TIMES; i++) {
    await step('tap General', () => screen.getByText('General').tap());
    await step('tap About', () => screen.getByText('About').tap());
    await step('assertVisible iOS Version', () => expect(screen.getByText('iOS Version')).toBeVisible());
    await step('tap BackButton', () => screen.getByTestId('BackButton').tap());
    await step('tap BackButton', () => screen.getByTestId('BackButton').tap());
    await step('scroll down', () => screen.scrollUntilVisible(screen.getByText('Developer'), { direction: 'down' }));
    await step('tap magnifyingglass', () => screen.getByTestId('magnifyingglass').tap());
    await step('erase', () => screen.getByRole('textbox').clear());
    await step('input', () => screen.getByRole('textbox').fill('Speedrun bench'));
    await step('assertVisible Speedrun bench', () => expect(screen.getByRole('textbox')).toHaveValue('Speedrun bench'));
    await step('tap close', () => screen.getByText('close').tap());
    await step('scroll up', () => screen.scrollUntilVisible(screen.getByText('General'), { direction: 'up' }));
  }
  report();
});
