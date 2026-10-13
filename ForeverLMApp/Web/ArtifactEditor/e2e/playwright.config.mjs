// Browser tests of the page editor, run in WebKit, the engine of the Mac and
// iPhone apps' web views: `npm run e2e` (all), `npm run e2e:corpus` (every
// page stored on this Mac, read only), `npm run e2e:budget` (typing speed).
import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.mjs',
  outputDir: './.results',
  globalSetup: './build-e2e.mjs',
  fullyParallel: true,
  timeout: 60_000,
  reporter: [['list']],
  use: {
    ...devices['Desktop Safari'],
    viewport: { width: 1000, height: 800 },
    headless: true,
  },
  projects: [{ name: 'webkit', use: { browserName: 'webkit' } }],
})
