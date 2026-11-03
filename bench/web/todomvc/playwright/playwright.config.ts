import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  reporter: 'list',
  use: { baseURL: 'http://127.0.0.1:8791' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
