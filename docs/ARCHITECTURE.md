# JARVIS — Architecture

## Overview

JARVIS is a monorepo with three runnable pieces and one source of truth
for the data model:

- **API server** (`server/`) — Node 20, Express, TypeScript, Prisma.
  SQLite for dev, Postgres for prod (two schemas — see "Data model"
  below). Owns all business rules.
- **Customer portal** (`apps/portal/`) — Vite + React + TypeScript. Public-
  facing; a customer only ever sees the one portal they have a grant for.
- **Android control app** (`apps/android/`) — Kotlin + Jetpack Compose.
  Don only (ADMIN JWT). Text command bar + voice input.
- **Shared types** (`packages/shared/`) — mirrors the server types for the
  portal / Android clients. Server is the source of truth; keep them in sync.

## Data model

Prisma schema: `server/prisma/schema.prisma`. All IDs are `cuid()` strings.
All timestamps are UTC (`DateTime`, `@default(now())`).

### Dual schema: SQLite (dev) / Postgres (Docker, prod)

Prisma ties the datasource `provider` to the schema file, and the client
validates the URL protocol against it at startup — a SQLite schema given
a `postgresql://` URL crashes immediately with error **P1012** ("the URL
must start with the protocol `file:`"). That is what killed the first
GitHub Actions docker run (run 43210865406, 2026-11-12): the compose file
passes a Postgres URL while the only schema was SQLite. So the repo
carries **two schemas with identical models**:

| | SQLite (dev / tests) | Postgres (Docker / prod) |
|---|---|---|
| Schema | `server/prisma/schema.prisma` | `server/prisma/postgres/schema.prisma` |
| Provider | `sqlite` | `postgresql` |
| Migrations | `server/prisma/migrations/` | `server/prisma/postgres/migrations/` |
| URL | `file:./dev.db` (absolute path in tests) | `postgresql://USER:PASS@HOST:5432/jarvis?schema=public` |
| Generate | `npx prisma generate` | `npx prisma generate --schema=prisma/postgres/schema.prisma` |
| Migrate | `npx prisma migrate dev` | `npx prisma migrate deploy --schema=prisma/postgres/schema.prisma` |

Rules:
- **Keep the two schemas in sync.** Same models, same fields, same
  relations — only the `provider` (and header comment) may differ. All
  field types used are portable across both: `String`, `Int`-free
  (none used), `Decimal` (Postgres: `DECIMAL(65,30)`), `DateTime`
  (Postgres: `TIMESTAMP(3)`), `Boolean`, `Float` (Postgres:
  `DOUBLE PRECISION`), `cuid()` ids. Statuses are plain strings in
  both — no native enums anywhere.
- **The Postgres init migration is generated, not hand-written:**
  `DATABASE_URL=postgresql://... npx prisma migrate diff --from-empty
  --to-schema-datamodel prisma/postgres/schema.prisma --script` (a
  dummy local URL is enough — the command never connects). Regenerate
  it the same way after any model change; never edit the SQL by hand.
  Incremental migrations are generated the same way with
  `--from-schema-datamodel <old schema> --to-schema-datamodel <new
  schema>` (save a copy of the old schema first) for both providers,
  so the two migration histories stay in step.
- **Docker:** `server/Dockerfile` generates the client from the Postgres
  schema in the build stage and runs `migrate deploy --schema=...` in
  its `CMD`. The GitHub Actions workflow builds `dist/` on the host
  with the SQLite schema (for `tsc` only) — the runtime client is the
  one from the image. The compose bind-mount `./server:/app` hides the
  image's `/app/prisma`, but the host `./server/prisma` also contains
  the `postgres/` folder, so the runtime `migrate deploy --schema=...`
  still resolves; `/app/node_modules` is an anonymous volume, so the
  Postgres-generated client survives the mount.
- **Never mix them:** a `file:` URL with the Postgres schema, or a
  `postgresql://` URL with the SQLite schema, fails at startup (P1012).
  The test scripts always use absolute-path SQLite `DATABASE_URL`s and
  the default schema — they never touch Postgres.

### User (Don / admins)

```
User {
  id, email (unique), passwordHash (bcrypt), name?, role: ADMIN | CUSTOMER,
  createdAt, updatedAt
}
```

- The **first** registered user becomes `ADMIN`. Later users can only be
  created by an ADMIN. Customers of a portal are **not** `User` rows —
  they are `AccessGrant`s (see below). `role: CUSTOMER` exists for a future
  customer-account mode and is not used by the portal login flow.
- Passwords: bcrypt, cost 12. Never log or return `passwordHash`.

### Portal

```
Portal {
  id, slug (unique, url-safe), name, description?, currency (default "USD"),
  status: ACTIVE | ARCHIVED, ownerId -> User,
  createdAt, updatedAt
  grants: AccessGrant[], methods: PortalPaymentMethod[],
  invoices: Invoice[], traffic: TrafficLog[], accounts: LinkedAccount[]
}
```

A portal is one custom website / payment portal. Its "project folder" in
the Android app is the portal detail view: its grants, methods, invoices,
traffic reports, and linked accounts.

### AccessGrant — the invite / code system

```
AccessGrant {
  id, portalId -> Portal, email, codeHash (bcrypt),
  status: ACTIVE | REVOKED | TERMINATED,
  lastUsedAt?, createdAt, expiresAt?
}
```

Flow:
1. Don enters an email in the Android app → `POST /api/access/invite`.
2. Server generates a code `XXXX-XXXX-XXXX` (see `utils/codes.ts`),
   bcrypt-hashes it into `codeHash`, stores the grant as `ACTIVE`.
3. The plain code is returned **once** in the invite response, to Don only.
   It is never stored, never logged, never emailed by the server (Don
   shares it with the customer out-of-band, or a future approved email
   template may include it — human approval gate applies).
4. Customer logs in at the portal with **email = username, code = password**.
   Server checks blocklist + `TERMINATED` first, then `bcrypt.compare`.
5. Success → short-lived customer JWT (`role: CUSTOMER`, `portalId` claim,
   12h expiry). Failure → generic `Invalid credentials`.

`TERMINATED` is the policy-termination state. A terminated grant can never
log in again, even with the correct code. Revoked (`REVOKED`) is Don's
soft off-switch (re-invite creates a fresh grant + fresh code).

### PaymentMethod + PortalPaymentMethod (many-to-many)

```
PaymentMethod {
  id, type: CASH_APP | VENMO | ZELLE | CHIME | PAYPAL | CARD | BANK
          | BTC | LTC | XMR | ETH | USDT | USDC | DOGE,
  label, handle (public handle / URL / address — NEVER a secret),
  details? (JSON: e.g. { "note": "All Pockets Full Consulting" }),
  ownerId -> User, createdAt
}
PortalPaymentMethod { id, portalId, paymentMethodId, createdAt }
  @@unique([portalId, paymentMethodId])
```

Don adds a method once and assigns it to any number of portals. The portal
Pay page only lists methods assigned to that portal.

**Example handles (Don's already-known handles, not secrets):**
Cash App `$MsCarterb`, Chime `$apfmoneygoat`, Venmo `@Plummer2002`.
Crypto methods store a **public address only**.

### Invoice + Payment

```
Invoice {
  id, number (unique, "JAR-1001", "JAR-1002", …),
  portalId -> Portal, payerEmail, payerName?,
  amount (Decimal, string in JSON), currency,
  status: PENDING | PAID | FAILED | REFUNDED | CANCELLED,
  barcodePayload ("JARVIS|JAR-1001|150.00|USD"),
  barcodeQrDataUrl?, emailStatus: QUEUED | SENT | SIMULATED | FAILED,
  proofHash?, items (JSON: [{ description, amount }]),
  paymentMethodId?, createdAt, paidAt?
}
Payment {
  id, invoiceId -> Invoice, method: string, amount, currency,
  reference? (txHash / Stripe payment_intent / provider ref),
  status: PENDING | CONFIRMED | FAILED,
  simulated (Boolean — true unless a real provider confirmed it),
  proofHash, createdAt
}
```

Invoice numbering: a DB counter / serial per server (see `invoice.ts`
`nextInvoiceNumber()` — in prod use a DB sequence or a locked counter row;
the current implementation uses `count + 1001` inside a transaction and is
documented as safe for single-instance dev, to be replaced by a sequence
for multi-instance prod — Copilot Prompt 6).

**Proof of payment:** `proofHash = sha256(invoiceNumber + "|" + amount +
"|" + currency + "|" + reference + "|" + paidAtISO)`. It is printed on the
receipt and in the PDF so Don or the payer can verify the receipt matches
the payment record.

### TrafficLog — IP security / reverse lookup

```
TrafficLog {
  id, portalId -> Portal, ip, userAgent?, path,
  hasAccess (Boolean), ptr?, country?, region?, city?,
  isp?, org?, lat?, lon?, lookupSource? ("PTR+ip-api" | "FALLBACK"),
  lookupSimulated (Boolean), createdAt
}
```

Flow (see `services/ipLookup.ts` + `routes/security.ts`):
1. Every portal visit is logged (`POST /api/security/visit` — called by
   the portal on load and by the server on unauthenticated hits).
2. If the visitor **has a valid grant** (`hasAccess: true`), no lookup runs.
3. If not, the server runs a reverse lookup:
   - `dns.reverse(ip)` → PTR hostname (best effort, timeout 3s);
   - `GET http://ip-api.com/json/<ip>?fields=status,country,regionName,city,isp,org,lat,lon`
     (free tier, no key) → geo + ISP;
   - on any failure, fields fall back to `UNKNOWN` and `lookupSource`
     records the fallback — the visit is still logged.
4. The `TrafficLog` is the report. Don reads it per portal in the Android
   app (Security tab) or `GET /api/security/portals/:id/traffic`.
   Reports are filed **per portal** — never mixed across portals.

### BlockedUser

```
BlockedUser {
  id, portalId? (null = global block), email?, ip?,
  reason, blockedById -> User, createdAt
}
```

Checked **before** password verification on every login and payment
attempt. A match denies with a generic message. Blocking an email also
sets that email's grants on the portal to `TERMINATED` (see `security.ts`).

### LinkedAccount

```
LinkedAccount {
  id, portalId -> Portal, type (e.g. "STRIPE", "CASH_APP", "EMAIL", "DOMAIN", "OTHER"),
  label, handle (public identifier / URL), notes?, createdAt
}
```

"Link all necessary information on my app for all accounts on each portal"
— this is the per-portal account book. **Never store secrets here.**
A `type: OTHER` row with a note like "see password manager" is the correct
pattern for anything credential-like.

### IdVerification — customer ID pictures (Prompt 12)

```
IdVerification {
  id, portalId -> Portal (cascade), email,
  idType (DRIVERS_LICENSE | STATE_ID | NATIONAL_ID — never PASSPORT),
  frontPath, backPath, selfiePath (server-side paths under
    server/uploads/id-verifications/ — never returned to customers),
  status (PENDING | VERIFIED | REJECTED, default PENDING),
  reviewedById?, reviewedAt?, createdAt, updatedAt
}
@@unique([portalId, email]) — a re-upload replaces the record and resets
status to PENDING.
```

ID images are sensitive PII: stored under `server/uploads/` (gitignored,
never committed, never served publicly), streamed only through the
authenticated image route to Don or the owning customer, and never
logged beyond the record id. **Payment is NOT blocked by verification**
— an unverified customer can still pay.

### PortalAsset — portal customisation files (Prompt 12)

```
PortalAsset {
  id, portalId -> Portal (cascade),
  kind (LOGO | BANNER | IMAGE | DOCUMENT | FILE),
  originalName, storedPath (server-side, under server/uploads/),
  mimeType, size, uploadedById, createdAt
}
```

One LOGO and one BANNER per portal max (a new upload replaces the old).
Files are downloadable only through the public asset file route, which
streams by asset id. ID verification images are a different model and
are never reachable through this route.

## Security model

| Actor | Auth | Can do |
|---|---|---|
| Don (ADMIN) | JWT, `role: ADMIN` | Everything: portals, invites, methods, block, invoices, accounts |
| Customer | Customer JWT, `role: CUSTOMER`, `portalId` claim | Log in to that portal only, view/pay own invoices, view own receipts |
| Anonymous visitor | None | Load the portal login page only; visit is logged |

- JWT secret: `JWT_SECRET` env, min 32 chars. Admin tokens 7 days,
  customer tokens 12 hours.
- Rate limiting: login and invite endpoints are rate-limited in
  `src/index.ts` (`express-rate-limit`: 10/min per IP on `/api/access/login`,
  30/min on `/api/security/visit`). Tighten in prod.
- CORS: portal origin (`APP_URL` / `PORTAL_ORIGIN`) and the Android app
  only. Never `*` with credentials.
- Helmet headers on; `X-Powered-By` off.
- **Uploads:** files live under `server/uploads/` (gitignored) with
  random server-side filenames — the user-supplied name is stored in
  the DB only. Uploads are never served as a public static path; each
  file is streamed through a scoped route. ID verification images are
  PII and are never returned in an API response or logged.
- **reCAPTCHA (Prompt 12):** a CUSTOMER payment submit must pass
  reCAPTCHA (`services/captcha.ts`). With no `RECAPTCHA_SECRET_KEY`
  configured the check always passes and is labelled simulated. When
  configured, a missing/invalid token is a `400` and nothing is
  recorded; a network error reaching Google counts as NOT verified.
  Don's ADMIN manual confirm never needs a captcha.

## Payment flows

### Fiat / wallet (Cash App, Venmo, Zelle, Chime, PayPal, card, bank)

1. Customer presses **Pay** → portal calls `POST /api/invoices`
   `{ portalSlug, payerEmail, amount, currency, items, paymentMethodId }`.
2. Server creates the invoice (`JAR-1001+`), builds the barcode payload,
   generates the QR (`qrcode` lib), and queues the email (`email.ts`).
   Without SMTP the email is `SIMULATED` — logged, not sent.
3. Customer sees the QR + Code128 string + the assigned method's handle
   (e.g. Cash App `$MsCarterb`) and pays in their own app.
4. Customer (or Don) submits the payment reference →
   `POST /api/payments/:invoiceId/confirm` with `{ reference }`.
   Card payments go through Stripe when `STRIPE_SECRET_KEY` is set
   (webhook confirms); otherwise Don confirms manually in the app and the
   record is labelled `simulated: true`.
5. On confirmation, invoice → `PAID`, `Payment` row + `proofHash` written,
   receipt email sent (or simulated), PDF available at
   `GET /api/invoices/:id/pdf`.

### Crypto (BTC / LTC / XMR / ETH / USDT / USDC / DOGE)

Same invoice flow, with `CryptoPaymentService` (`services/crypto.ts`):

```
checkout → reference → txHash submit → verify → confirm → PAID
```

1. **Checkout.** Invoice created for a crypto method → the create
   response includes `crypto: { currency, address, amount, reference }` —
   the portal's configured **public address** (never a private key), the
   exact crypto amount, and the payment reference (the invoice number,
   e.g. `JAR-1001`). The customer can re-fetch the same details later
   with `GET /api/invoices/:id/crypto` (customer-scoped). The QR code /
   barcode only *shows* these details — scanning it never pays anything
   and never marks anything `PAID`.
2. **Pay.** Customer sends the exact amount on-chain from their wallet
   to the address.
3. **Submit reference.** Customer submits the transaction hash (or
   provider reference) → `POST /api/payments/:invoiceId/confirm`
   `{ reference: "<txHash>" }`. The reference must be 64 hex chars
   (optionally `0x`-prefixed) or a provider reference — anything else
   is a `400`. Submitting it only **records** a `PENDING` payment; the
   invoice stays `PENDING`.
4. **Verify.** The server calls `CryptoPaymentService.verify()`:
   - *SIMULATED mode* (no provider keys): `verify()` always returns
     `confirmed: false`. The payment is labelled `simulated: true` and
     nothing auto-confirms — ever.
   - *Provider mode* (`BTCPAY_URL` + `BTCPAY_API_KEY` or
     `COINBASE_COMMERCE_API_KEY`): the provider check is the only path
     (the `ProviderCryptoService` stub returns unconfirmed until the
     provider API is wired — see the `// INTEGRATION POINT` in
     `crypto.ts`).
5. **Confirm → PAID.** Exactly one of these flips the invoice:
   - a **provider webhook**: `POST /api/webhooks/crypto/:provider`
     (BTCPay / Coinbase), HMAC-SHA256 signed with
     `BTCPAY_WEBHOOK_SECRET` / `COINBASE_WEBHOOK_SECRET`. Creates a
     `CONFIRMED` payment with `simulated: false`, sets `proofHash` /
     `paidAt`, queues the receipt email. Idempotent — a replay returns
     `alreadyPaid: true`.
   - **Don's manual confirm** (`adminConfirm: true`, ADMIN only) — in
     SIMULATED mode only. The confirmation is explicitly labelled
     `SIMULATED` (the `Payment` row and the note both say so). With a
     provider configured, manual confirm is **refused** with `400`.
   - a future on-chain check (same `verify()` interface).
6. **Receipt.** On `PAID` the receipt email is queued (or `SIMULATED`)
   and the PDF is available at `GET /api/invoices/:id/pdf`.

**Hard rule:** `PAID` requires a confirmation record (a `CONFIRMED`
`Payment` row). A QR/barcode scan alone never creates one, and a
customer-submitted txHash alone never creates one. A CUSTOMER passing
`adminConfirm: true` gets `403` — self-confirming is forbidden, never
silently ignored.

| Mode | How PAID happens | `Payment.simulated` |
|---|---|---|
| SIMULATED (no provider keys) | Don's manual `adminConfirm` only | `true` |
| Provider (BTCPay / Coinbase keys set) | Signed webhook only | `false` |

**Provider integration (to finish, once Don has keys):** see the
`// INTEGRATION POINT` block in `services/crypto.ts` — (1) `quote()`
must call the provider's invoice/charge API and use real exchange
rates (the simulated fixed rates are fake, for UI testing only);
(2) `verify()` must query the provider and return `confirmed: true`
only when the provider reports confirmed/complete; (3) point the
provider's webhook at `/api/webhooks/crypto/:provider` — the endpoint
is already implemented and HMAC-verified. Env vars:
`BTCPAY_URL`, `BTCPAY_API_KEY`, `BTCPAY_WEBHOOK_SECRET`,
`COINBASE_COMMERCE_API_KEY`, `COINBASE_WEBHOOK_SECRET` (see
`.env.example`).

## Invoice / receipt format

- Number: `JAR-1001+`, sequential.
- Header: portal name, Don's business label (from the portal / linked
  account — default "JARVIS Portal"), date (UTC), invoice number.
- Payer: email (+ name if given). Items: description + amount each.
- Total, currency, payment method (label + type), transaction reference,
  proof hash, barcode payload + QR (in the PDF).
- Footer: "Proof of payment — verify with proof hash" + portal contact.
- PDF generated with `pdfkit` in `services/invoice.ts`.

## Simulated vs Real — the rule

Every external side effect has a **simulated** path (default, no keys) and
a **real** path (keys set). The code always records which path was used
(`emailStatus`, `Payment.simulated`, `TrafficLog.lookupSimulated`) so Don
can tell real from demo in the data itself. **No real money moves until
Stripe / crypto-provider keys and SMTP are configured.**
