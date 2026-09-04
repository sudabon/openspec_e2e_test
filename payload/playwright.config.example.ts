import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  retries: 1, // リトライ成功 = フレークとして記録される
  reporter: [
    ['list'],
    ['json', { outputFile: 'test-results/e2e-results.json' }],
  ],
  use: {
    trace: 'on-first-retry',
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:3000',
  },
});
