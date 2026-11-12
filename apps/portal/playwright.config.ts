import { defineConfig } from "@playwright/test";

// Jarvis customer-portal click test (Issue #13, Prompt 9 limit fix).
//
// Runs against the real portal served by `vite preview` — it does NOT
// start the preview itself. In CI the docker-e2e workflow starts it
// (see the Playwright step snippet in /tmp/docker-e2e-playwright-snippet.yml):
//
//   cd apps/portal && VITE_API_URL=http://localhost:4000 npm run build
//   npx vite preview --port 4173 --strictPort &
//   npx playwright test
//
// Locally: start the dev server (or the docker stack) on
// http://localhost:4000 first, then build + preview the portal the
// same way, then run `npx playwright test` from apps/portal.
// PORTAL_URL / API_URL override the defaults below.

const PORTAL_URL = process.env.PORTAL_URL ?? "http://localhost:4173";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  // One worker: both tests share the invite created in beforeAll, and
  // serial runs keep the flow deterministic on a shared test stack.
  workers: 1,
  use: {
    baseURL: PORTAL_URL,
    trace: "retain-on-failure",
  },
});
