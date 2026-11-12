# Muse Instructions — JARVIS (jarvis-android-assistant)

You are working in Don Drop's JARVIS monorepo. Jarvis is an AI assistant
app Don controls by **text or voice** that builds custom website/payment
portals. Don controls who gets in, who can pay, and who is blocked.

## Project layout (do not restructure without asking Don)

```
server/          Node 20 + Express + TypeScript + Prisma (SQLite dev, Postgres prod)
  prisma/schema.prisma        # data model — source of truth for the DB
  src/index.ts                # app entry, route wiring, /health
  src/db.ts                   # Prisma client singleton
  src/middleware/auth.ts      # JWT verify (Don/admin + customer grant tokens)
  src/middleware/requireAdmin.ts
  src/utils/codes.ts          # generate + bcrypt-hash + verify access codes
  src/services/email.ts       # nodemailer, SIMULATED when SMTP_* unset
  src/services/barcode.ts     # QR (qrcode) + Code128 payload string
  src/services/crypto.ts      # CryptoPaymentService interface + simulated confirm
  src/services/ipLookup.ts    # reverse DNS + geo/ISP lookup, with fallback
  src/services/invoice.ts     # PDF receipt (pdfkit), JAR-1001+ numbering
  src/routes/ auth, portals, access, payments, invoices, security, accounts
apps/portal/     Vite + React + TypeScript — customer portal (login / pay / receipt)
apps/android/    Kotlin + Jetpack Compose — Jarvis control app (Don only)
packages/shared/ Shared types. Server types are the source of truth; keep
                 shared types in sync manually — do not auto-generate drift.
docs/            ARCHITECTURE.md (data model + flows), API.md (REST contract)
```

## Conventions

- TypeScript strict, ES modules, `async/await`, no callbacks.
- Express routers are thin: validate input → call a service → return JSON.
  Business logic lives in `src/services/`, never inline in a route.
- API shape: `{ ok: true, data: ... }` on success,
  `{ ok: false, error: { code, message } }` on failure. HTTP codes: 200/201,
  400 validation, 401 unauthenticated, 403 forbidden / blocked, 404 not found.
- Invoice numbers: `JAR-1001`, `JAR-1002`, … (sequential, never reused).
- Barcode payload format (do NOT change without Don's approval):
  `JARVIS|<invoiceNumber>|<amount>|<currency>` — e.g. `JARVIS|JAR-1001|150.00|USD`
- Dates: ISO 8601 UTC. Money: decimal strings with 2 places for fiat
  (`"150.00"`), 8 places max for crypto amounts.
- IDs: Prisma `cuid()` strings.
- Naming: `camelCase` for TS/Kotlin vars, `PascalCase` for models/components,
  `SCREAMING_SNAKE_CASE` for env vars and enum values (`ACTIVE`, `TERMINATED`).

## Security rules — non-negotiable

1. **Access codes:** generate with `crypto.randomBytes` in `utils/codes.ts`,
   format `XXXX-XXXX-XXXX` (uppercase, no ambiguous chars I/O/0/1).
   **bcrypt-hash before storing. Never store, log, or return the plain code
   after the invite response.** Show it once to Don only. Verify with
   `bcrypt.compare` — never compare plain strings.
2. **Never log codes, passwords, JWTs, SMTP passwords, API keys, or wallet
   private keys.** Redact in logs. If you need a value for debugging, log
   only its first 4 chars + `…`.
3. **Blocklist first:** every login and payment attempt checks
   `BlockedUser` and `AccessGrant.status === 'TERMINATED'` before anything
   else. Deny with the generic message `Invalid credentials` / `Access denied`
   — never reveal that an account was terminated.
4. **Human approval gate:** Jarvis never sends an email, SMS, outreach, or
   payment request on its own. Every send is triggered by Don's explicit
   action in the Android app or an explicit admin API call.
5. **Payments:** never mark an invoice `PAID` on QR/barcode scan alone.
   Card = Stripe webhook (or explicit admin confirm in dev). Crypto =
   provider webhook / on-chain confirmation via `CryptoPaymentService`.
   The simulated confirm in `crypto.ts` is for dev only and is labelled
   `SIMULATED` in the DB.
6. **No secrets in code, docs, tests, or seed data.** Use `.env` placeholders
   only. Public payment handles (Cash App `$MsCarterb`, Chime
   `$apfmoneygoat`, Venmo `@Plummer2002`) may appear in docs/seed as
   *example* handles — they are not secrets. Never add a private key or
   seed phrase.
7. **Admin vs customer auth:** Don uses JWT (`Authorization: Bearer <jwt>`,
   role `ADMIN`). Customers use an email + access-code session scoped to one
   portal (short-lived JWT, `role: CUSTOMER`, `portalId` claim). Never let a
   customer token access admin routes, and never let one portal's token
   access another portal.
8. **IP logging:** log every portal visit (`TrafficLog`). Run a reverse
   lookup only for visits with no valid grant. Store the report; do not
   expose raw IPs to customers — only to Don in the portal's Security tab.

## How to extend each feature

- **New portal field:** schema.prisma → `prisma migrate dev` → update
  `docs/ARCHITECTURE.md` + `docs/API.md` + portal + Android UI.
- **New payment method type:** add to `PaymentMethodType` enum, add the
  display/config fields to `PaymentMethod`, wire it in `payments.ts` and
  in the portal Pay page. Card = Stripe; crypto = `crypto.ts`.
- **New invoice item / receipt field:** update `Invoice` model, `invoice.ts`
  PDF layout, and the receipt page in `apps/portal/src/pages/Receipt.tsx`.
- **New IP provider:** replace the `ip-api.com` call inside `ipLookup.ts`
  only — keep the `IpLookupResult` shape (`ptr, country, region, city, isp,
  org, lat, lon, source, simulated`).
- **Voice:** Android `VoiceInput.kt` is the only voice entry point.
  Keep on-device SpeechRecognizer as default; Whisper is an optional hook.

## What NOT to do

- Do not push to GitHub, do not create releases, do not change the repo
  name, LICENSE, or the `0mertateam101/jarvis-android-assistant` remote.
- Do not add a new database, queue, or paid service without flagging it
  in your reply (cost / key needed).
- Do not "finish" a feature by leaving a `TODO` where working code was
  requested — mark real integration points as `// INTEGRATION POINT:`
  with the exact env var and the behaviour in SIMULATED mode.
- Do not invent Don's business data, customers, prices, or wallet
  addresses. Use the example handles above or clearly-labelled placeholders.
