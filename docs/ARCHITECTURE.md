# JARVIS — Architecture

## Overview

JARVIS is a monorepo with three runnable pieces and one source of truth
for the data model:

- **API server** (`server/`) — Node 20, Express, TypeScript, Prisma.
  SQLite for dev, Postgres for prod. Owns all business rules.
- **Customer portal** (`apps/portal/`) — Vite + React + TypeScript. Public-
  facing; a customer only ever sees the one portal they have a grant for.
- **Android control app** (`apps/android/`) — Kotlin + Jetpack Compose.
  Don only (ADMIN JWT). Text command bar + voice input.
- **Shared types** (`packages/shared/`) — mirrors the server types for the
  portal / Android clients. Server is the source of truth; keep them in sync.

## Data model

Prisma schema: `server/prisma/schema.prisma`. All IDs are `cuid()` strings.
All timestamps are UTC (`DateTime`, `@default(now())`).

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
          | BTC | LTC | XMR | ETH,
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

### Crypto (BTC / LTC / XMR / ETH)

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
