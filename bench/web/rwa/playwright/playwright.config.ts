import { defineConfig, devices } from '@playwright/test';

// One worker: the app keeps one shared database file, which each test resets.
export default defineConfig({
  testDir: './tests',
  workers: 1,
  reporter: 'list',
  use: { baseURL: 'http://localhost:3000' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 1000 } } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'], viewport: { width: 1280, height: 1000 } } },
  ],
});
