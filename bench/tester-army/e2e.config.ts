// The Settings benchmarks on tester-army's e2e runner (https://github.com/tester-army/e2e),
// locators only, so no model. DEVICE picks an emulator serial or simulator name.
import type { E2EConfig } from 'e2e';
import { mobile } from '@e2e-dev/mobile';

const device = process.env.DEVICE;

export default {
  targets: [
    { name: 'android', engine: mobile({ platform: 'android', device }), app: { bundleId: 'com.android.settings' } },
    { name: 'ios', engine: mobile({ platform: 'ios', device }), app: { bundleId: 'com.apple.Preferences' } },
  ],
  workers: 1,
} satisfies E2EConfig;
