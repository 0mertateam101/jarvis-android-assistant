import { test, expect, type APIRequestContext, type Page } from "@playwright/test";

// Jarvis customer-portal click test (Issue #13).
//
// Drives the real React portal in a real browser: log in with an
// invited customer's email + access code, open the Pay page, see the
// assigned payment method, create an invoice, see the barcode/QR,
// submit a payment reference and see the invoice stay PENDING, open
// the receipt. Plus one negative: a wrong code gets the generic denial.
//
// The spec creates its own portal / payment method / invite through
// the API in beforeAll, so it passes standalone and never depends on
// the API e2e scripts' state (portal-a / portal-b / their customers).
// It runs against the docker server (http://localhost:4000) with the
// portal served by `vite preview` on port 4173 — see playwright.config.ts.
//
// Admin login: the docker stack is fresh per run, but the API e2e step
// runs BEFORE this spec in the same workflow, so an admin already
// exists by then and /api/auth/register returns 403 ("Registration is
// closed"). The setup therefore tries to register its own admin first
// (works standalone against a fresh server) and falls back to logging
// in as the docker-e2e script's test admin when registration is closed.
// Test data only — never real credentials, never Don's real handles.

const API_URL = process.env.API_URL ?? "http://localhost:4000";

const PORTAL_SLUG = "playwright-portal";
const PORTAL_NAME = "Playwright Portal";
const CUSTOMER_EMAIL = "playwright-customer@test.local";
const AMOUNT = "150.00";
const DESCRIPTION = "Playwright click test";
const REFERENCE = "PW-TEST-REF-001";

const SETUP_ADMIN = { email: "playwright-admin@test.local", password: "PlaywrightAdmin123!" };
// Test admin created by server/scripts/docker-e2e-test.sh (same stack,
// same run). Only used when registration is already closed.
const DOCKER_E2E_ADMIN = { email: "docker-admin@test.local", password: "TestAdmin123!" };

let customerCode = "";
let portalId = "";

async function apiJson(
  request: APIRequestContext,
  method: "GET" | "POST",
  path: string,
  token?: string,
  body?: Record<string, unknown>,
): Promise<{ status: number; json: any }> {
  const res = await request.fetch(`${API_URL}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    data: body,
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status(), json };
}

test.beforeAll(async ({ request }) => {
  // 1. Admin token: register our own admin if the server is fresh,
  //    otherwise log in as the docker-e2e test admin (registration is
  //    closed once any user exists — see server/src/routes/auth.ts).
  let adminToken = "";
  const reg = await apiJson(request, "POST", "/api/auth/register", undefined, {
    email: SETUP_ADMIN.email,
    password: SETUP_ADMIN.password,
    name: "Playwright",
  });
  if (reg.status === 201) {
    adminToken = reg.json.data.token as string;
  } else {
    const login = await apiJson(request, "POST", "/api/auth/login", undefined, {
      email: DOCKER_E2E_ADMIN.email,
      password: DOCKER_E2E_ADMIN.password,
    });
    if (login.status !== 200) {
      throw new Error(
        `Playwright setup: no admin available (register ${reg.status}, docker-e2e admin login ${login.status})`,
      );
    }
    adminToken = login.json.data.token as string;
  }

  // 2. Our own portal (slug is unique to this spec).
  const portal = await apiJson(request, "POST", "/api/portals", adminToken, {
    name: PORTAL_NAME,
    slug: PORTAL_SLUG,
    currency: "USD",
  });
  if (portal.status === 201) {
    portalId = portal.json.data.portal.id as string;
  } else {
    // Portal already exists (spec re-run against a warm stack) — fetch it.
    const existing = await apiJson(request, "GET", `/api/portals/${PORTAL_SLUG}`, adminToken);
    if (existing.status !== 200) {
      throw new Error(`Playwright setup: create portal ${portal.status}, fetch existing ${existing.status}`);
    }
    portalId = existing.json.data.portal.id as string;
  }

  // 3. One Cash App method, assigned to this portal only.
  const method = await apiJson(request, "POST", "/api/payment-methods", adminToken, {
    type: "CASH_APP",
    label: "Cash App — Playwright",
    handle: "$pwtest",
  });
  if (method.status !== 201) {
    throw new Error(`Playwright setup: create payment method ${method.status}`);
  }
  const methodId = method.json.data.method.id as string;
  const assign = await apiJson(request, "POST", `/api/portals/${PORTAL_SLUG}/methods`, adminToken, {
    paymentMethodId: methodId,
  });
  if (assign.status !== 201) {
    throw new Error(`Playwright setup: assign method ${assign.status}`);
  }

  // 4. Invite our customer — the plain code is returned once, here.
  //    Re-invite rotates the code, so a re-run still gets a fresh one.
  const invite = await apiJson(request, "POST", "/api/access/invite", adminToken, {
    portalId,
    email: CUSTOMER_EMAIL,
  });
  if (invite.status !== 201) {
    throw new Error(`Playwright setup: invite customer ${invite.status}`);
  }
  customerCode = invite.json.data.code as string;
  if (!customerCode) throw new Error("Playwright setup: invite returned no code");
});

async function loginAsCustomer(page: Page) {
  await page.goto("/");
  await page.getByLabel("Portal").fill(PORTAL_SLUG);
  await page.getByLabel("Email (username)").fill(CUSTOMER_EMAIL);
  await page.getByLabel("Access code (password)").fill(customerCode);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(new RegExp(`/portal/${PORTAL_SLUG}$`));
  await expect(page.getByRole("heading", { name: `Welcome, ${CUSTOMER_EMAIL}` })).toBeVisible();
}

test("happy path: log in, pay, reference stays PENDING, receipt shows it", async ({ page, request }) => {
  await loginAsCustomer(page);

  // Portal home shows exactly the method assigned to this portal.
  await expect(page.getByText("Cash App — Playwright")).toBeVisible();
  await expect(page.getByText("$pwtest")).toBeVisible();

  // Pay page: create the invoice.
  await page.getByRole("button", { name: "Pay now" }).click();
  await expect(page).toHaveURL(new RegExp(`/portal/${PORTAL_SLUG}/pay$`));
  await expect(page.getByRole("heading", { name: "Pay" })).toBeVisible();
  await expect(page.getByLabel("Payment method")).toContainText("Cash App — Playwright");
  await page.getByLabel("What is this for?").fill(DESCRIPTION);
  await page.getByLabel("Amount (USD)").fill(AMOUNT);
  await page.getByRole("button", { name: "Generate payment barcode" }).click();

  // Barcode + QR are on screen, with the exact payload format.
  const invoiceHeading = page.getByRole("heading", { name: /Invoice JAR-\d+ — 150\.00 USD/ });
  await expect(invoiceHeading).toBeVisible();
  const invoiceNumber = ((await invoiceHeading.textContent()) ?? "").match(/JAR-\d+/)?.[0] ?? "";
  expect(invoiceNumber).toMatch(/^JAR-\d+$/);
  await expect(page.getByAltText("Payment QR code")).toBeVisible();
  await expect(page.getByText(`JARVIS|${invoiceNumber}|150.00|USD`, { exact: false })).toBeVisible();

  // Submit a payment reference: recorded, invoice stays PENDING —
  // a reference alone never marks it PAID (verified through the API too).
  await page.getByLabel("Payment reference (transaction hash / receipt ref)").fill(REFERENCE);
  await page.getByRole("button", { name: "I have paid — submit reference" }).click();
  await expect(page.getByText("Reference recorded. Awaiting confirmation")).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`/portal/${PORTAL_SLUG}/pay$`));

  // Receipt page shows the same invoice, still PENDING, no proof yet.
  await page.getByRole("link", { name: "View receipt" }).click();
  await expect(page.getByRole("heading", { name: `Receipt — ${invoiceNumber}` })).toBeVisible();
  await expect(page.getByText("PENDING", { exact: false })).toBeVisible();
  await expect(page.getByText("Payment not confirmed yet")).toBeVisible();
  await expect(page.getByText(`JARVIS|${invoiceNumber}|150.00|USD`, { exact: false })).toBeVisible();

  // API cross-check: the invoice really is still PENDING server-side.
  const invoiceId = ((await page.url().match(/\/receipt\/([^/]+)$/)?.[1]) ?? "") as string;
  const customerLogin = await apiJson(request, "POST", "/api/access/login", undefined, {
    portalSlug: PORTAL_SLUG,
    email: CUSTOMER_EMAIL,
    code: customerCode,
  });
  expect(customerLogin.status).toBe(200);
  const got = await apiJson(
    request,
    "GET",
    `/api/invoices/${invoiceId}`,
    customerLogin.json.data.token as string,
  );
  expect(got.status).toBe(200);
  expect(got.json.data.invoice.status).toBe("PENDING");
  expect(got.json.data.invoice.number).toBe(invoiceNumber);
});

test("negative: wrong access code gets the generic denial", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("Portal").fill(PORTAL_SLUG);
  await page.getByLabel("Email (username)").fill(CUSTOMER_EMAIL);
  await page.getByLabel("Access code (password)").fill("AAAA-BBBB-CCCC");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(
    page.getByText("Invalid credentials. If you believe this is a mistake, contact the portal owner."),
  ).toBeVisible();
  // Still on the login page — no portal, no methods, no denial reason.
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByRole("heading", { name: "Sign in to your portal" })).toBeVisible();
});
