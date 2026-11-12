# COPILOT_PROMPTS — 12 ordered prompts for GitHub Copilot Agent / VS Code Copilot

Work through these **in order (1 → 12)**. Each prompt is copy-paste ready.
Open the repo in VS Code with Copilot Chat (or GitHub Copilot Agent), paste
one prompt, review the diff, run the checks it names, then move on.
Do not skip ahead — later prompts depend on earlier ones.

---

## Prompt 1 — Server foundation: install, migrate, boot

> In `server/`, install dependencies, run `npx prisma migrate dev --name init`
> against SQLite (`DATABASE_URL=file:./dev.db`), then `npm run dev` and
> confirm `GET /health` returns `{ ok: true }`. Fix any TypeScript errors
> in `src/index.ts`, `src/db.ts`, and the middleware so the server boots
> cleanly. Do not change the route paths in `src/index.ts`. Report the exact
> commands you ran and any errors you fixed.

**Touches:** `server/package.json`, `server/prisma/schema.prisma`, `server/src/index.ts`, `server/src/db.ts`
**Done when:** `GET /health` returns 200.

## Prompt 2 — Owner auth (Don = ADMIN) + JWT

> Implement `server/src/routes/auth.ts` and the JWT middleware in
> `src/middleware/auth.ts` + `requireAdmin.ts` so Don can register the first
> ADMIN user, log in, and receive a JWT. Verify: (a) the first registered
> user becomes ADMIN, later registrations are blocked unless an ADMIN invites
> them; (b) `GET /api/auth/me` with a valid token returns the user;
> (c) an expired / missing token returns 401; (d) a CUSTOMER token cannot
> call any `/api/admin/*` or admin-only route (403). Add tests or a curl
> script under `server/scripts/` showing each case. Never log passwords or
> tokens.

**Touches:** `server/src/routes/auth.ts`, `server/src/middleware/*`
**Done when:** register → login → `/me` works; customer token is rejected on admin routes.

## Prompt 3 — Portals + linked accounts

> Implement `server/src/routes/portals.ts` and `accounts.ts` from
> `docs/API.md`: create / list / get / update / archive a Portal, and add /
> list / remove LinkedAccounts per portal (type, label, public handle or
> URL — never a secret). A portal has a slug, name, description, currency,
> and status. Only ADMIN can create or edit. Return 404 for unknown slugs.
> Update `docs/API.md` if any field changes. Verify with curl against the
> running server.

**Touches:** `server/src/routes/portals.ts`, `server/src/routes/accounts.ts`, Prisma `Portal`, `LinkedAccount`
**Done when:** full portal CRUD works; linked accounts attach to the right portal only.

## Prompt 4 — Access grants: invite by email, code = password

> Implement `server/src/routes/access.ts` using `src/utils/codes.ts`:
> `POST /api/access/invite` takes `{ portalId, email }`, generates a code
> (`XXXX-XXXX-XXXX`), bcrypt-hashes it, stores an `AccessGrant` with status
> `ACTIVE`, and returns the plain code **once** in the response (to Don
> only). `POST /api/access/login` takes `{ portalSlug, email, code }`,
> checks the blocklist + `TERMINATED` status first, verifies with
> `bcrypt.compare`, and on success returns a short-lived customer JWT scoped
> to that portal. On failure return the generic `Invalid credentials`
> message. Verify: correct code logs in, wrong code fails, a revoked grant
> fails, and the plain code is nowhere in the database or logs.

**Touches:** `server/src/routes/access.ts`, `server/src/utils/codes.ts`, Prisma `AccessGrant`, `BlockedUser`
**Done when:** invite → login (good code) → 200; login (bad code) → 401 generic; DB holds only the hash.

## Prompt 5 — Payment methods: add many, assign to many portals

> Implement `server/src/routes/payments.ts` (payment-methods part) from
> `docs/API.md`: ADMIN creates PaymentMethods of types `CASH_APP`, `VENMO`,
> `ZELLE`, `CHIME`, `PAYPAL`, `CARD`, `BANK`, `BTC`, `LTC`, `XMR`, `ETH`
> (public handle / address only — validate format loosely, never accept a
> private key), lists them, and assigns / unassigns them to portals via
> `PortalPaymentMethod`. The portal Pay page must only offer methods
> assigned to that portal. Seed the example handles from `README.md`
> (Cash App `$MsCarterb`, Chime `$apfmoneygoat`, Venmo `@Plummer2002`) as
> an optional dev seed, clearly labelled as examples.

**Touches:** `server/src/routes/payments.ts`, Prisma `PaymentMethod`, `PortalPaymentMethod`
**Done when:** create method → assign to portal A only → portal B does not offer it.

## Prompt 6 — Invoices + payment barcode (QR + Code128) + email

> Implement `server/src/routes/invoices.ts` with `src/services/barcode.ts`,
> `email.ts`, and `invoice.ts`: creating an invoice numbers it `JAR-1001+`,
> computes the barcode payload `JARVIS|<invoice>|<amount>|<currency>`,
> generates a real QR code (data URL) and a Code128 payload string, stores
> the invoice, and queues an email to the payer with the barcode. If
> `SMTP_*` is unset, mark the email `SIMULATED`, log it, and still return
> the QR. Add `GET /api/invoices/:id` (customer-scoped) and
> `GET /api/invoices/:id/pdf` returning the PDF receipt. Verify the QR
> decodes to the exact payload string.

**Touches:** `server/src/routes/invoices.ts`, `server/src/services/barcode.ts`, `email.ts`, `invoice.ts`
**Done when:** invoice → QR decodes to `JARVIS|JAR-1001|…`; email status is `SIMULATED` without SMTP, `SENT` with SMTP.

## Prompt 7 — Crypto checkout (never mark paid on QR scan)

> Implement `server/src/services/crypto.ts` and the crypto flow in
> `payments.ts`: for `BTC`/`LTC`/`XMR`/`ETH`, return the portal's configured
> public address + exact amount + a payment reference; accept a
> `txHash` / provider reference from the customer; verify via the
> `CryptoPaymentService` interface. In SIMULATED mode, confirmation is
> explicitly labelled simulated and requires Don's manual confirm in the
> app. Add the real-provider hook (BTCPay / Coinbase Commerce) as an
> `// INTEGRATION POINT` with its env vars, and refuse to mark `PAID`
> without a provider/on-chain confirmation in non-simulated mode. Update
> `docs/ARCHITECTURE.md` with the crypto flow.

**Touches:** `server/src/services/crypto.ts`, `server/src/routes/payments.ts`
**Done when:** crypto invoice shows address + amount; `PAID` requires a confirmation record, never a scan alone.

## Prompt 8 — Security: visit logging, reverse lookup, blocklist, termination

> Implement `server/src/routes/security.ts` with `src/services/ipLookup.ts`:
> log every portal visit (`POST /api/security/visit` — portalSlug, ip,
> userAgent, path). If the visitor has no valid grant, run the reverse
> lookup (PTR via `dns.reverse` + geo/ISP via ip-api.com, fallback to
> `UNKNOWN`), store a `TrafficLog` with the findings, and file the report
> under that portal (listable via `GET /api/security/portals/:id/traffic`).
> Add `POST /api/security/block` (ADMIN) to block an email/IP and set the
> grant `TERMINATED`, and enforce the blocklist on login and payment.
> Verify: unauthorised visit creates a TrafficLog with lookup data;
> authorised visit does not trigger a lookup; blocked email gets a generic
> denial on login.

**Touches:** `server/src/routes/security.ts`, `server/src/services/ipLookup.ts`, Prisma `TrafficLog`, `BlockedUser`
**Done when:** unauthorised visit → TrafficLog + report; blocked user → generic 401/403.

## Prompt 9 — Customer portal (React): login, pay, receipt

> In `apps/portal/`, wire `src/App.tsx`, `src/api.ts`, and
> `src/pages/Login.tsx`, `PortalHome.tsx`, `Pay.tsx`, `Receipt.tsx` to the
> live server API from `docs/API.md`: login with email + code (store the
> customer JWT in memory/sessionStorage only, never localStorage), show the
> portal home with its assigned payment methods, create an invoice from
> the Pay page and display the QR + Code128 payload + the "barcode sent to
> your email" state, complete a simulated payment, then show the receipt
> with invoice number, proof hash, and a PDF download link. Handle 401/403
> with the generic message and a "contact the portal owner" hint. Run
> `npm run build` cleanly.

**Touches:** `apps/portal/src/**`
**Done when:** `npm run build` passes; full flow works against the dev server: login → pay → receipt.

## Prompt 10 — Android control app (Kotlin/Compose): Jarvis commands + voice

> In `apps/android/`, finish `MainActivity.kt`, `JarvisViewModel.kt`,
> `ApiClient.kt`, and `VoiceInput.kt` so Don can: log in as ADMIN, list
> portals, create a portal, invite a customer by email and see the
> generated code once, manage payment methods and assign them, view the
> security/traffic report for a portal, and block/terminate a user. Wire
> the text command bar in `JarvisViewModel` to parse commands such as
> `create portal <name>`, `invite <email> to <portal>`, and
> `block <email> on <portal>` into the real API calls. Keep the
> SpeechRecognizer voice input (on-device) and the Whisper hook disabled
> unless `WHISPER_API_KEY` is set. Verify the project syncs and builds in
> Android Studio; document any Gradle/SDK version you had to pin.

**Touches:** `apps/android/app/src/main/java/com/jarvis/assistant/**`
**Done when:** app builds; Don can complete invite → code display → block from the phone.

---

## Prompt 11 — Crypto payment methods: USDT, USDC, DOGE

> Add three crypto payment method types — `USDT`, `USDC`, and `DOGE` —
> to the existing crypto flow from Prompt 7. In
> `server/src/routes/payments.ts`, add the three types to the method
> enum (14 types total) and add loose handle checks: `USDT` / `USDC`
> accept an ERC-20 style address (`0x` + 40 hex) **or** a Tron style
> address (`T` + 33 base58 chars) — never lock to one chain; `DOGE`
> accepts a `D` prefix (P2SH `A` prefix), base58, 26–34 chars total.
> Keep the secret checks: a raw 64-hex handle is still rejected, and a
> `0x` address (40 hex) must not trip them. In
> `server/src/services/crypto.ts`, add the three to `CryptoCurrency`,
> `isCryptoType`, and the simulated dev rates (`USDT: 1`, `USDC: 1`,
> `DOGE: 0.2` — clearly fake, for UI testing only). They must get the
> full crypto treatment automatically through the existing generic
> paths — checkout quote, reference validation, webhook confirmation,
> never PAID on QR scan — with no per-coin special cases in the
> confirm / webhook paths. Add the three types to the Android hint
> text in `MainActivity.kt` and update `docs/API.md`,
> `docs/ARCHITECTURE.md`, and `README.md`. No schema change (method
> type is a plain string). No real provider keys, no real money —
> simulated mode only. Extend `server/scripts/payments-test.sh` and
> `server/scripts/crypto-test.sh` (fresh test DB, absolute
> `DATABASE_URL`) and run both.

**Touches:** `server/src/routes/payments.ts`, `server/src/services/crypto.ts`, `apps/android/app/src/main/java/com/jarvis/assistant/MainActivity.kt`, `docs/API.md`, `docs/ARCHITECTURE.md`, `README.md`, `server/scripts/payments-test.sh`, `server/scripts/crypto-test.sh`
**Done when:** USDT / USDC / DOGE methods create (201) with plausible handles, bad handles 400, secret-looking handles still 400, and a USDT invoice completes checkout → reference stays PENDING → Don manual confirm → PAID with proofHash.

---

## Prompt 12 — ID verification uploads, reCAPTCHA before payment, portal file uploads

> Three features sharing one upload infrastructure (multer, files under
> `server/uploads/` — gitignored, never committed, never served as a
> public static path; random server-side filenames, never the
> user-supplied name).
>
> **1. ID verification.** Add an `IdVerification` model to BOTH Prisma
> schemas (keep them identical except provider) + a migration for each
> (`prisma migrate diff --from-schema-datamodel <old> --to-schema-datamodel
> <new> --script`, one per provider): id, portalId (FK Portal, cascade),
> email, idType (`DRIVERS_LICENSE` | `STATE_ID` | `NATIONAL_ID` — NO
> passport option anywhere), frontPath, backPath, selfiePath, status
> (`PENDING` | `VERIFIED` | `REJECTED`, default PENDING), reviewedById?,
> reviewedAt?, createdAt, updatedAt; unique per (portalId, email) — a
> re-upload replaces the record and resets status to PENDING. New route
> file `server/src/routes/verification.ts` (mounted in `src/index.ts`
> before `portalsRouter`): `POST /api/portals/:portalId/id-verification`
> (CUSTOMER, own portal + own email only; multipart `idType`, `front`,
> `back`, `selfie` — all three images required, jpeg/png/webp only, each
> ≤ 10 MB; return 201 with the record minus file paths);
> `GET .../id-verification/me` (CUSTOMER own record);
> `GET .../id-verification` (ADMIN, owner-scoped list, no paths);
> `POST .../id-verification/:id/review` (ADMIN, `{ status: VERIFIED |
> REJECTED }`); `GET .../id-verification/:id/image/:field` (ADMIN
> owner-scoped OR owning CUSTOMER; streams the image; 403 otherwise,
> 404 for unknown field/id). Negatives: other-portal customer 403,
> missing image 400, non-image 400, oversized 400, bad idType (incl.
> `PASSPORT`) 400. ID images are sensitive PII: never log paths beyond
> the record id, never include image bytes in any response. Payment is
> NOT blocked by verification. Customer portal: ID section on PortalHome
> (type picker with the three options + "no passports" note, three file
> inputs with previews, submit, current status shown).
>
> **2. reCAPTCHA before payment.** Add `server/src/services/captcha.ts`:
> `verifyCaptcha(token)` returns `{ required, ok, simulated }`. No
> `RECAPTCHA_SECRET_KEY` configured → required=false, ok=true,
> simulated=true (SIMULATED, clearly labelled, nothing sent to Google).
> Configured → missing token fails; otherwise POST to Google's siteverify
> with a 5s timeout and return Google's `success`; a network error is
> NOT verified, never a pass. Add `RECAPTCHA_SECRET_KEY` +
> `RECAPTCHA_SITE_KEY` to `.env.example` (no real keys). Enforce in
> `POST /api/payments/:invoiceId/confirm` ONLY for CUSTOMER callers
> without `adminConfirm` (accept optional `captchaToken`; configured +
> missing/invalid → 400; simulated → proceed with
> `captcha: { simulated: true }` in the response). Don's ADMIN manual
> confirm is unchanged (no captcha). Portal Pay page: when
> `VITE_RECAPTCHA_SITE_KEY` is set, load the reCAPTCHA v2 script,
> render the checkbox, keep the submit button disabled until solved, and
> send the token; when unset, show a clearly-labelled simulated notice
> and leave the button enabled. No captcha npm dependency.
>
> **3. Portal file uploads.** Add a `PortalAsset` model to BOTH schemas
> + both migrations: id, portalId (FK Portal, cascade), kind (`LOGO` |
> `BANNER` | `IMAGE` | `DOCUMENT` | `FILE`), originalName, storedPath,
> mimeType, size, uploadedById, createdAt. New route file
> `server/src/routes/assets.ts` (mounted before `portalsRouter`):
> `POST /api/portals/:portalId/assets` (ADMIN, owner-scoped; multipart
> `file` + `kind`; images jpeg/png/webp/gif ≤ 10 MB for LOGO/BANNER/IMAGE,
> documents pdf/doc/docx/txt ≤ 25 MB for DOCUMENT/FILE; executables and
> archives → 400; one LOGO and one BANNER per portal max — a new upload
> replaces the old, file + record deleted);
> `GET /api/portals/:portalId/assets` (ADMIN list);
> `DELETE /api/portals/:portalId/assets/:id` (ADMIN, deletes record +
> file); `GET /api/portals/:slug/assets/:id/file` (public; streams the
> file — inline for images, attachment for documents; 404 otherwise;
> ID verification images must NEVER be reachable here). Extend
> `GET /api/portals/:id` with `logoAssetId` / `bannerAssetId` and the
> public-methods response with logo/banner/documents. PortalHome shows
> the logo/banner when set and lists documents with download links.
> Android: ID-verification review section (list + VERIFIED/REJECTED).
>
> Update `docs/API.md`, `docs/ARCHITECTURE.md`, `README.md`. Document
> the uploads dir + gitignore, the no-passport rule, the captcha
> simulated-vs-configured rule, PII handling, and that payment is NOT
> blocked by verification. Add a test script
> `server/scripts/id-captcha-assets-test.sh` (fresh test DB, absolute
> `DATABASE_URL`, real exit code) covering all three features including
> the negatives, plus a configured-captcha run with a dummy secret
> (submit without token → 400, garbage token → 400). Run it, plus
> `npx tsc --noEmit`, `npm run build` in `apps/portal`, and re-run
> `payments-test.sh` / `crypto-test.sh` (SIMULATED) for regressions.

**Touches:** `server/prisma/schema.prisma`, `server/prisma/postgres/schema.prisma`, `server/prisma/migrations/*`, `server/prisma/postgres/migrations/*`, `server/package.json`, `server/src/services/uploads.ts`, `server/src/services/captcha.ts`, `server/src/routes/verification.ts`, `server/src/routes/assets.ts`, `server/src/routes/payments.ts`, `server/src/routes/portals.ts`, `server/src/index.ts`, `server/.env.example`, `.gitignore`, `apps/portal/src/api.ts`, `apps/portal/src/pages/Pay.tsx`, `apps/portal/src/pages/PortalHome.tsx`, `apps/android/app/src/main/java/com/jarvis/assistant/ApiClient.kt`, `apps/android/app/src/main/java/com/jarvis/assistant/JarvisViewModel.kt`, `apps/android/app/src/main/java/com/jarvis/assistant/MainActivity.kt`, `docs/API.md`, `docs/ARCHITECTURE.md`, `README.md`, `server/scripts/id-captcha-assets-test.sh`
**Done when:** ID upload (201, PENDING, no paths returned) + re-upload resets to PENDING + review flips VERIFIED + image streams only to Don/owner; customer payment submit without token succeeds in SIMULATED mode (response says simulated) and fails 400 in configured mode (no token or garbage token); ADMIN confirm needs no captcha; LOGO/BANNER/DOCUMENT upload + replace + public download + delete all work; `id-captcha-assets-test.sh` passes; `tsc` clean; portal builds; no regression in the payments/crypto scripts.

---

## Prompt 13 — Android APK build on GitHub Actions + portal click test (Playwright)

> Two things that could never run on the local machine, both done on
> GitHub Actions instead (same approach as the Docker check).
>
> **Part A — APK build.** New workflow `.github/workflows/apk-build.yml`
> (runs on push to `apps/android/**` + `workflow_dispatch`):
> ubuntu-latest, setup JDK 17 (Temurin), setup Android SDK, fetch
> `gradle/wrapper/gradle-wrapper.jar` from the official Gradle 8.7 URL
> and verify its SHA-256
> `cb0da6751c2b753a16ac168bb354870ebb1e162e9083f116729cec9c781156b8` (the
> jar cannot be committed through the text-only API tooling, so the
> workflow fetches it — see `apps/android/README.md`), then
> `./gradlew assembleDebug`. Upload the debug APK as an Actions artifact
> (`jarvis-debug-apk`, `apps/android/app/build/outputs/apk/debug/app-debug.apk`,
> 30-day retention) so Don can download it on his phone and install it.
> Debug APK only — no release signing (no signing keys exist). Update
> `apps/android/README.md` with the download steps.
>
> **Part B — Portal click test.** The React portal was never driven by
> clicks in a real browser. Add a Playwright spec
> `apps/portal/e2e/portal.spec.ts` + `apps/portal/playwright.config.ts`
> (add `@playwright/test` as a devDependency) that runs against the portal
> served by `vite preview` with `VITE_API_URL` pointing at the docker
> server: log in with an invited customer's email + code, open the Pay
> page, see the assigned methods, create an invoice, see the barcode/QR,
> submit a reference and see it stay PENDING, open the receipt. One happy
> path + one negative (wrong code → generic denial). The spec creates its
> own portal/methods/invite through the API in `beforeAll` so it passes
> standalone. Add a Playwright step to the EXISTING `docker-e2e.yml`
> workflow (after the API e2e step, BEFORE the Stop stack step — the
> compose stack must still be up): start `vite preview` on port 4173,
> install Playwright chromium, run the spec, stop preview; add
> `apps/portal/**` to the workflow's push paths.
>
> The workflow files cannot be pushed through the API (403, no workflow
> scope) — write them locally; they are created/edited through the
> GitHub web UI.

**Touches:** `.github/workflows/apk-build.yml`, `.github/workflows/docker-e2e.yml`, `apps/portal/e2e/portal.spec.ts`, `apps/portal/playwright.config.ts`, `apps/portal/package.json`, `apps/portal/package-lock.json`, `apps/portal/tsconfig.json`, `apps/android/README.md`
**Done when:** `apk-build.yml` exists on main and its first run is green with a downloadable `app-debug.apk` artifact; the Playwright spec passes in the docker-e2e run; `npx tsc --noEmit` clean in server/ and apps/portal; portal `npm run build` clean.

---

## Prompt 14 — ARCHIVED guards, admin invite, atomic invoice numbering, compose secrets

> Finish the known gaps left open after Prompts 1–12.
>
> **1. ARCHIVED portal guards.** `POST /api/access/invite` to an ARCHIVED
> portal currently succeeds (201) and the invitee only fails at login
> with a 401 — reject with 409 `{ code: "PORTAL_ARCHIVED" }`.
> `GET /api/portals/:slug/public-methods` still lists an ARCHIVED portal's
> payment methods on its public Pay page — ARCHIVED portals must return
> 404 on the public routes (same as a missing portal); apply the same to
> the public asset-file route.
>
> **2. Admin invite.** `POST /api/auth/invite-admin` (ADMIN only) is a 501
> placeholder — implement it: body `{ email, password (min 8), name? }`,
> creates a second ADMIN user, 201 with the user and never the password
> hash, no token returned (the new admin signs in via `/login`). Duplicate
> email → 400, weak password → 400, non-admin → 403. This is the only way
> a second admin is created — public registration stays blocked.
>
> **3. Atomic invoice numbering.** `nextInvoiceNumber()` is count+1001 —
> two simultaneous creates can collide. Add a single-row counter model
> (`InvoiceCounter`, id `"main"`, `nextNumber`) to BOTH Prisma schemas +
> a migration for each (dual-schema rule), seeded from the existing
> invoice count so a pre-counter DB keeps its sequence and a fresh DB
> starts at JAR-1001; allocate with a transactional relative increment.
>
> **4. Compose secrets hardening.** `docker-compose.yml` bakes in
> `POSTGRES_PASSWORD=jarvis_dev_only` (a weak, publicly known dev
> password) and a `DATABASE_URL` default embedding it. The JWT_SECRET
> default is already a placeholder (`change-me-in-env`) — leave it, do
> NOT invent a real secret. Change compose to
> `POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}` and
> `DATABASE_URL=${DATABASE_URL:?set DATABASE_URL}` (fail fast when unset).
> Update the compose header comment, `README.md`, and
> `server/.env.example` with local run instructions. The docker-e2e
> workflow relies on the old defaults, so write the exact YAML snippet
> for the web UI: a step before `docker compose up` that generates random
> values (`openssl rand -hex 32` for JWT_SECRET, `openssl rand -hex 16`
> for POSTGRES_PASSWORD, DATABASE_URL built from the generated password)
> and exports them to `$GITHUB_ENV`. The workflow edit must land BEFORE
> the compose change is pushed, or the next docker run will fail.
>
> Update `docs/API.md`, `docs/ARCHITECTURE.md`, `README.md`. Extend the
> existing test scripts (fresh test DB, absolute `DATABASE_URL`, real exit
> code) and re-run `auth` / `access` / `payments` / `invoices` /
> `security` / `id-captcha-assets` / `crypto` (SIMULATED) /
> `portal-e2e` for regressions.

**Touches:** `server/src/routes/access.ts`, `server/src/routes/assets.ts`, `server/src/routes/auth.ts`, `server/src/routes/payments.ts`, `server/src/services/invoice.ts`, `server/prisma/schema.prisma`, `server/prisma/postgres/schema.prisma`, `server/prisma/migrations/*`, `server/prisma/postgres/migrations/*`, `docker-compose.yml`, `README.md`, `server/.env.example`, `docs/API.md`, `docs/ARCHITECTURE.md`, `server/scripts/auth-test.sh`, `server/scripts/access-test.sh`, `server/scripts/payments-test.sh`, `server/scripts/invoices-test.sh`, `server/scripts/id-captcha-assets-test.sh`
**Done when:** ARCHIVED invite 409 + ARCHIVED public routes 404; invite-admin 201 with no hash, duplicate/weak 400, non-admin 403; sequential invoices JAR-1001, JAR-1002, … and the sequence continues after a server restart; `grep -rn jarvis_dev_only` returns zero matches in the repo; `tsc` clean; all re-run test scripts pass; the docker-e2e workflow generates its own throwaway secrets and still passes.

---

## After all 14

Run `docker compose up --build`, repeat Prompt 9's end-to-end flow, then
ask Don for the first real portal name + its payment methods before
seeding any real data. Do not push until Don says so.
