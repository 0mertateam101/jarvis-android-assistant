# JARVIS — API Reference

Base URL (dev): `http://localhost:4000`
Base URL (prod): set `APP_URL` / your deployed server URL.

All responses are JSON: success `{ ok: true, data: ... }`,
error `{ ok: false, error: { code, message } }`.

Auth headers:
- Don (admin): `Authorization: Bearer <admin JWT>`
- Customer: `Authorization: Bearer <customer JWT>` (scoped to one portal)

Generic login/denial errors always use the message `Invalid credentials`
or `Access denied` — they never reveal whether an account was terminated,
revoked, or never existed.

---

## Health

### `GET /health`
No auth. Returns `{ ok: true, data: { status: "ok", time: "<ISO>" } }`.

---

## Auth — Don (ADMIN)

### `POST /api/auth/register`
Body: `{ "email": "don@example.com", "password": "…", "name": "Don" }`
- First user ever registered becomes `ADMIN`. Later registrations return
  `403` unless called with an ADMIN token (future admin-invite flow).
- Response `201`: `{ user: { id, email, name, role }, token }`

### `POST /api/auth/login`
Body: `{ "email": "…", "password": "…" }`
- Response `200`: `{ user: { id, email, name, role }, token }`
- Wrong credentials → `401 { code: "INVALID_CREDENTIALS" }`.

### `GET /api/auth/me`
Admin JWT. Response `200`: `{ user: { id, email, name, role } }`.

---

## Portals (ADMIN)

### `POST /api/portals` — ADMIN
Body:
```json
{ "name": "VIP Coaching Portal", "slug": "vip-coaching",
  "description": "Private portal for coaching clients",
  "currency": "USD" }
```
Response `201`: the `Portal` object.

### `GET /api/portals` — ADMIN
Lists Don's portals. Response: `{ portals: [Portal, …] }`.

### `GET /api/portals/:id` — ADMIN
`:id` accepts the portal id **or** its slug; an unknown id or slug
returns `404`. Response: `{ portal: Portal }` (always includes the
linked accounts and the assigned payment methods).

### `PATCH /api/portals/:id` — ADMIN
Body: any of `{ name, description, currency, status }`
(`status`: `ACTIVE` | `ARCHIVED`). Response: updated `Portal`.

### `DELETE /api/portals/:id` — ADMIN
Archives the portal (`status: ARCHIVED`). Response: `{ portal }`.
Hard delete is not exposed — ask Don before adding one.

**Portal object:**
```json
{ "id": "cm…", "slug": "vip-coaching", "name": "VIP Coaching Portal",
  "description": "…", "currency": "USD", "status": "ACTIVE",
  "ownerId": "cm…", "createdAt": "2026-11-12T06:00:00.000Z",
  "updatedAt": "2026-11-12T06:00:00.000Z" }
```

---

## Access — invites, codes, customer login

### `POST /api/access/invite` — ADMIN
Body: `{ "portalId": "…", "email": "customer@example.com" }`
- Generates a code, bcrypt-hashes it, creates/refreshes an `AccessGrant`
  (`ACTIVE`). **Returns the plain code once, to Don only.**
- Response `201`:
```json
{ "grant": { "id": "…", "portalId": "…", "email": "customer@example.com",
             "status": "ACTIVE", "createdAt": "…" },
  "code": "7HLM-BN8B-2V9X",
  "warning": "Show this code once. It is not stored in plain text." }
```
- Re-inviting an `ACTIVE` email rotates the code (old code stops working).

### `GET /api/access/portals/:portalId/grants` — ADMIN
Lists grants for a portal (emails + status + `lastUsedAt`; **never** codes).
Scoped to portals the admin owns — unknown portal, or one owned by
another admin, is `404`. Accepts portal id or slug.

### `POST /api/access/login` — public (customer)
Body: `{ "portalSlug": "vip-coaching", "email": "customer@example.com", "code": "7HLM-BN8B-2V9X" }`
- Checks blocklist + `TERMINATED` first, then `bcrypt.compare`.
- Success `200`:
```json
{ "token": "<customer JWT, 12h, portalId claim>",
  "portal": { "id": "…", "slug": "vip-coaching", "name": "VIP Coaching Portal" },
  "email": "customer@example.com" }
```
- Failure `401`: `{ code: "INVALID_CREDENTIALS", message: "Invalid credentials" }`.

### `POST /api/access/revoke` — ADMIN
Body: `{ "grantId": "…" }` → sets `status: REVOKED`. Response: the grant.
Scoped to grants on portals the admin owns — a grant on another admin's
portal is `404`.

### `GET /api/access/me` — customer JWT
Returns `{ email, portalId }` for the caller's token.

---

## Payment methods (ADMIN) + assignment

### `POST /api/payment-methods` — ADMIN
Body:
```json
{ "type": "CASH_APP", "label": "Cash App — APF", "handle": "$MsCarterb",
  "details": { "note": "All Pockets Full Consulting" } }
```
Types: `CASH_APP | VENMO | ZELLE | CHIME | PAYPAL | CARD | BANK | BTC | LTC | XMR | ETH`.
`handle` is a public handle / URL / crypto address — never a secret.
Anything that looks like a private key, seed phrase, mnemonic, password,
API key, or raw 64-hex key in `handle` (or in `details`) is rejected with
`400`. Handle format is checked loosely per type: `$username` for
`CASH_APP` / `CHIME`, `@username` for `VENMO`, email or phone for `ZELLE` /
`PAYPAL`, a plausible address for `BTC` / `LTC` / `XMR` / `ETH`
(`0x` + 40 hex for `ETH`), 13–19 digits for `CARD`, at least 4 characters
for `BANK`. A wrong format is a `400`.
Response `201`: the `PaymentMethod`.

### `GET /api/payment-methods` — ADMIN
Response: `{ methods: [PaymentMethod, …] }` — only Don's own methods.

### `GET /api/payment-methods/:id` — ADMIN
Response: `{ method }`. Unknown id (or one Don does not own) → `404`.

### `DELETE /api/payment-methods/:id` — ADMIN
Deletes the method; its portal assignments are removed with it. Unknown
id (or one Don does not own) → `404`. A method already used by an invoice
→ `409`. Response `200`: `{ ok: true }`.

### `POST /api/portals/:portalId/methods` — ADMIN
Body: `{ "paymentMethodId": "…" }` — assigns a method to a portal.
`:portalId` accepts the portal id or slug. Assigning the same method twice
is idempotent — it returns the same link, never a duplicate.
Response `201`: the `PortalPaymentMethod` link. Unknown portal or method
(or one Don does not own) → `404`.

### `DELETE /api/portals/:portalId/methods/:methodId` — ADMIN
Unassigns. `:portalId` accepts the portal id or slug. Unknown portal or
method (or one Don does not own) → `404`. Response `200`: `{ ok: true }`.

### `GET /api/portals/:slug/public-methods` — public / customer
Lists only the methods assigned to that portal (label, type, handle).
Used by the portal Pay page. No admin data is exposed.

---

## Invoices + barcode + payments

### `POST /api/invoices` — customer JWT (or ADMIN)
Body:
```json
{ "portalSlug": "vip-coaching", "payerEmail": "customer@example.com",
  "payerName": "Jane", "amount": "150.00", "currency": "USD",
  "items": [{ "description": "Coaching — November", "amount": "150.00" }],
  "paymentMethodId": "…" }
```
- Creates invoice `JAR-1001+`, barcode payload
  `JARVIS|JAR-1001|150.00|USD`, QR data URL, queues the barcode email.
- Response `201`:
```json
{ "invoice": { "id": "…", "number": "JAR-1001", "portalId": "…",
    "payerEmail": "customer@example.com", "amount": "150.00",
    "currency": "USD", "status": "PENDING",
    "barcodePayload": "JARVIS|JAR-1001|150.00|USD",
    "barcodeQrDataUrl": "data:image/png;base64,…",
    "emailStatus": "SIMULATED", "proofHash": null,
    "items": [{ "description": "Coaching — November", "amount": "150.00" }],
    "createdAt": "…" },
  "paymentMethod": { "type": "CASH_APP", "label": "Cash App — APF", "handle": "$MsCarterb" },
  "crypto": null }
```
- For a crypto method, `crypto` is:
  `{ "currency": "BTC", "address": "<public address>", "amount": "0.0042", "reference": "JAR-1001" }`
  and the invoice is **not** `PAID` until confirmation (see below).

### `GET /api/invoices/:id` — customer JWT (own portal) or ADMIN
Response: `{ invoice }` (includes `payments`).

### `GET /api/invoices/:id/pdf` — customer JWT (own portal) or ADMIN
Returns the receipt PDF (`application/pdf`, filename `JAR-1001-receipt.pdf`).

### `POST /api/payments/:invoiceId/confirm` — customer JWT or ADMIN
Body: `{ "reference": "txHash / payment_intent / receipt ref", "method": "CASH_APP" }`
- Fiat/wallet: records the payment; Don's manual confirm (or a Stripe
  webhook — see `payments.ts`) flips the invoice to `PAID`.
- Crypto: stores the reference and calls `CryptoPaymentService.verify()`.
  In SIMULATED mode the payment is recorded as `simulated: true` and the
  invoice stays `PENDING` until Don confirms in the app.
- Response `200`: `{ invoice, payment }`.
- On `PAID`: `proofHash` is set, `paidAt` is set, and the receipt email
  is queued (or `SIMULATED`).

**Never mark `PAID` on QR/barcode scan alone** — see `docs/ARCHITECTURE.md`.

### `GET /api/portals/:portalId/invoices` — ADMIN
Lists invoices for a portal, newest first. Response: `{ invoices: […] }`.

---

## Security — visits, reverse lookup, blocklist

### `POST /api/security/visit` — public
Body: `{ "portalSlug": "vip-coaching", "ip": "203.0.113.10", "userAgent": "…", "path": "/pay", "hasAccess": false }`
- The portal calls this on load; the server also calls it internally for
  unauthenticated hits. `ip` is taken from the request when omitted.
- If `hasAccess` is false, the server runs the reverse lookup and stores
  the findings in the `TrafficLog`.
- Response `201`: `{ log: TrafficLog }`.

**TrafficLog object:**
```json
{ "id": "…", "portalId": "…", "ip": "203.0.113.10",
  "userAgent": "…", "path": "/pay", "hasAccess": false,
  "ptr": "host.example.net", "country": "United States",
  "region": "Georgia", "city": "Atlanta", "isp": "Example ISP",
  "org": "Example Org", "lat": 33.75, "lon": -84.39,
  "lookupSource": "PTR+ip-api", "lookupSimulated": false,
  "createdAt": "…" }
```
On lookup failure, geo fields are `"UNKNOWN"` and `lookupSource` is `"FALLBACK"`.

### `GET /api/security/portals/:portalId/traffic` — ADMIN
Query: `?hasAccess=false&limit=100`. Response: `{ logs: [TrafficLog, …] }`.
This is the per-portal security report / project-folder view.

### `POST /api/security/block` — ADMIN
Body: `{ "portalId": "…", "email": "bad@example.com", "ip": "203.0.113.10", "reason": "Policy violation" }`
- Creates a `BlockedUser` row and sets that email's grants on the portal
  to `TERMINATED`. Response `201`: `{ blocked: BlockedUser }`.

### `GET /api/security/blocked` — ADMIN
Response: `{ blocked: [BlockedUser, …] }`.

### `POST /api/security/unblock` — ADMIN
Body: `{ "blockedId": "…" }` — removes the block (does **not** reactivate
a `TERMINATED` grant; re-invite is required).

---

## Linked accounts (ADMIN)

### `POST /api/portals/:portalId/accounts` — ADMIN
Body: `{ "type": "CASH_APP", "label": "Cash App", "handle": "$MsCarterb", "notes": "APF" }`
Response `201`: the `LinkedAccount`. Never store secrets here — a
handle/notes that looks like a private key, seed phrase, mnemonic,
password, API key, or raw 64-hex key is rejected with `400`.

### `GET /api/portals/:portalId/accounts` — ADMIN
Response: `{ accounts: [LinkedAccount, …] }` — only that portal's
accounts. An unknown portal id (or one Don does not own) returns `404`.

### `DELETE /api/accounts/:id` — ADMIN
Response `200`: `{ ok: true }`. The account must belong to a portal Don
owns, otherwise `404`. If `?portalId=` is supplied and the account
belongs to a different portal, that is also a `404` — deletes never
cross portals.

---

## Error codes

| Code | HTTP | Meaning |
|---|---|---|
| `INVALID_CREDENTIALS` | 401 | Bad login (generic — also used for terminated/blocked) |
| `UNAUTHORIZED` | 401 | Missing / expired token |
| `FORBIDDEN` | 403 | Wrong role / wrong portal |
| `NOT_FOUND` | 404 | Unknown portal / invoice / grant |
| `VALIDATION_ERROR` | 400 | Bad body (field named in `message`) |
| `RATE_LIMITED` | 429 | Too many login / visit attempts |
| `INTERNAL` | 500 | Server error (details in server logs only) |
