# JARVIS — AI Assistant for Custom Website / Payment Portals

> **Don controls Jarvis by text or voice. Jarvis builds the portals. Don controls who gets in.**

JARVIS is a monorepo that lets Don Drop (owner / admin) create custom
website + payment portals, invite customers by email, and collect payment
— including crypto — while keeping unauthorised visitors out and giving
every payer a numbered invoice receipt with proof of payment.

This repo is the **source code for GitHub Copilot** to build and extend.
It is not a hosted app. Nothing here moves real money, sends real email,
or performs a real payment until the integration keys in `.env` are
configured (see **Simulated vs Real** below).

## What Jarvis does

| # | Requirement | Where it lives |
|---|-------------|----------------|
| 1 | Text **or voice** control | `apps/android/` — command bar + Android SpeechRecognizer, optional Whisper hook |
| 2 | Build custom website / payment portals | `POST /api/portals` — `server/src/routes/portals.ts` |
| 3 | Don controls who gets in | `AccessGrant` — one grant per (portal, email) |
| 4 | Enter an email → activate it, generate a code. Email = username, code = password | `POST /api/access/invite` — `server/src/routes/access.ts`, `server/src/utils/codes.ts` |
| 5 | Payment option generates a payment barcode (QR + Code128) sent to the customer's email | `POST /api/invoices` → `barcode.ts` + `email.ts` |
| 6 | Crypto payment on the website | `server/src/services/crypto.ts` — BTC / LTC / XMR / ETH / USDT / USDC / DOGE |
| 7 | Add many payment methods, assign them to many portals | `PaymentMethod` + `PortalPaymentMethod` |
| 8 | Reverse lookup on **all** IP traffic with no access; report filed in that portal's folder | `POST /api/security/visit` + `server/src/services/ipLookup.ts` |
| 9 | Block / terminate users for policy violation | `AccessGrant.status = TERMINATED` + `BlockedUser` |
| 10 | Invoice receipt on completed payment, with proof | `Invoice` `JAR-1001+`, PDF via `invoice.ts` |
| 11 | Link all account info per portal | `LinkedAccount` — `server/src/routes/accounts.ts` |

## Architecture (text diagram)

```
                    +-------------------+
                    |  Android app      |  Jarvis control app
                    |  apps/android     |  text + voice, portals,
                    |  Kotlin/Compose   |  invites, methods, security
                    +--------+----------+
                             |  HTTPS / JWT (Don only)
                    +--------v----------+
                    |  API server       |  Node 20 + Express + TS
                    |  server/          |  Prisma (SQLite dev,
                    |                   |  Postgres prod)
                    +---+-----------+---+
                        |           |
            +-----------v--+  +-----v------------+
            | Customer     |  | Postgres /       |
            | portal       |  | SQLite DB        |
            | apps/portal  |  | User, Portal,    |
            | Vite + React |  | AccessGrant,     |
            | login, pay,  |  | Invoice, Payment,|
            | receipt      |  | TrafficLog, ...  |
            +--------------+  +------------------+
                        |
               nodemailer (SMTP)   qrcode + Code128
               pdfkit (receipts)   ip-api / PTR lookup
```

Data model — see `docs/ARCHITECTURE.md`. API contract — see `docs/API.md`.

## Quick start

### 1. Server (API)

```bash
cd server
cp .env.example .env        # fill JWT_SECRET at minimum; leave the rest blank for SIMULATED mode
npm install
npx prisma migrate dev --name init
npm run dev                 # http://localhost:4000  (health: GET /health)
```

Seed the owner account (first run only):

```bash
npm run seed   # creates admin@jarvis.local / <ADMIN_SEED_PASSWORD from .env> — change it after login
# If you skip seed, register via POST /api/auth/register (first user becomes ADMIN).
```

### 2. Customer portal

```bash
cd apps/portal
cp .env.example .env        # VITE_API_URL=http://localhost:4000
npm install
npm run dev                 # http://localhost:5173
```

Log in with a customer email + the access code Jarvis generated for that
portal. Pay on the Pay page — the barcode/QR is generated locally from the
invoice payload and the email is queued by the server.

### 3. Android control app

Open `apps/android/` in Android Studio (Hedgehog or newer), sync Gradle,
run on an emulator or a physical device. Set the API base URL in
`ApiClient.kt` (`BASE_URL`) to your machine's LAN IP
(e.g. `http://192.168.1.10:4000`) — `10.0.2.2` works from the emulator.

Voice: the mic button uses Android `SpeechRecognizer` on-device. The
optional Whisper hook in `VoiceInput.kt` is disabled unless
`WHISPER_API_KEY` is set — no audio leaves the device by default.

### 4. Docker (server + Postgres)

```bash
docker compose up --build
# server on :4000, postgres on :5432.
```

The compose file passes a `postgresql://...` `DATABASE_URL` to the server
itself — you do **not** need to set it in `server/.env` for Docker.

**Dual-schema rule (important):** there are two Prisma schemas with
identical models — `server/prisma/schema.prisma` (SQLite, local dev and
tests) and `server/prisma/postgres/schema.prisma` (Postgres, Docker /
production). A SQLite URL only works with the SQLite schema and a
Postgres URL only with the Postgres schema; mixing them crashes the
server at startup with Prisma error P1012 ("the URL must start with the
protocol `file:`"). The Dockerfile generates its Prisma client from the
Postgres schema and runs `prisma migrate deploy
--schema=prisma/postgres/schema.prisma` on start. Keep the two schemas
in sync when you change a model — same fields, same relations, only the
`provider` differs. Full detail: `docs/ARCHITECTURE.md` → "Data model".

## Environment variables

Copy `server/.env.example` → `server/.env`. **Never commit `.env`.**
No real values are in this repo — only placeholders.

| Variable | Required? | Notes |
|---|---|---|
| `DATABASE_URL` | yes | `file:./dev.db` for SQLite dev (pairs with `prisma/schema.prisma`); `postgresql://...` for Docker/prod (pairs with `prisma/postgres/schema.prisma` — never mix them, see §4) |
| `JWT_SECRET` | yes | Long random string. Generate: `openssl rand -hex 32` |
| `PORT` | no | Default `4000` |
| `ADMIN_SEED_PASSWORD` | dev only | Seed admin password; change after first login |
| `SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASS / SMTP_FROM` | no | Leave blank = SIMULATED email (logged + marked `SIMULATED` in DB) |
| `STRIPE_SECRET_KEY` | no | Leave blank = SIMULATED card payments |
| `BTCPAY_URL / BTCPAY_API_KEY` or `COINBASE_COMMERCE_API_KEY` | no | Leave blank = SIMULATED crypto confirm |
| `WHISPER_API_KEY` | no | Android voice transcription; blank = on-device only |
| `IP_LOOKUP_BASE_URL` | no | Default `http://ip-api.com` (free tier, no key) |
| `APP_URL` | no | Public base URL shown on receipts, default `http://localhost:5173` |

### Example payment handles (Don's already-known handles — NOT secrets)

These are public payment handles Don already uses for All Pockets Full
Consulting, listed here only so Copilot / Don can seed *example* payment
methods in docs and dev seed data. They are **not** credentials, keys, or
passwords. Never add a private key, seed phrase, password, or API key
anywhere in this repo.

- Cash App: `$MsCarterb`
- Chime: `$apfmoneygoat`
- Venmo: `@Plummer2002`
- Crypto: BTC / LTC / XMR / ETH / USDT / USDC / DOGE addresses are configured per portal in the app
  (enter the public address only — never a private key). USDT / USDC accept
  an ERC-20 style `0x` address or a Tron style `T` address; DOGE uses a
  `D` (or P2SH `A`) address.

## Simulated vs Real — read this before you demo or go live

| Area | SIMULATED (default, no keys) | REAL (keys configured) |
|---|---|---|
| Email | Logged to console + stored as `SIMULATED` / `QUEUED` in DB. No email leaves the server. | Sent via SMTP when `SMTP_*` are set. |
| Card / wallet payment | Invoice marked `PENDING`; `completePayment` in dev only simulates confirmation. | Stripe (or other processor) webhook must confirm before `PAID`. |
| Crypto payment | Address + amount shown; confirmation is **simulated** and clearly labelled. **Never mark paid on QR scan alone.** | BTCPay / Coinbase Commerce webhook (or on-chain check) confirms before `PAID`. |
| IP reverse lookup | PTR via `dns.reverse` + free `ip-api.com` geo/ISP; falls back to `UNKNOWN` on failure. No paid lookup key needed. | Same flow; swap the provider in `ipLookup.ts` if you need a paid provider. |

**Safety rules baked into the code:**
- Access codes are **bcrypt-hashed** on creation. The plain code is shown
  **once** (to Don, at invite time) and never stored, never logged.
- Every login / payment attempt checks the blocklist first; a
  `TERMINATED` grant is denied with a generic message ("Invalid credentials")
  — it does not reveal that the account was terminated.
- Jarvis never sends outreach, email, or payment requests without Don's
  explicit action in the app (human approval gate).
- No secrets, wallet private keys, or seed phrases in code, docs, or logs.

## Repo layout

```
jarvis-android-assistant/
├── README.md                    # this file
├── COPILOT_PROMPTS.md           # 10 ordered prompts for Copilot Agent
├── docker-compose.yml           # server + postgres
├── .github/muse-instructions.md # Copilot repo instructions
├── docs/ARCHITECTURE.md         # data model, security, flows
├── docs/API.md                  # REST endpoints + examples
├── server/                      # Node 20 + Express + TS + Prisma
│   ├── prisma/schema.prisma     # SQLite — local dev / tests
│   ├── prisma/postgres/schema.prisma  # Postgres — Docker / prod
│   └── src/  index, db, middleware, utils, services, routes
├── apps/portal/                 # Vite + React + TS customer portal
├── apps/android/                # Kotlin + Jetpack Compose control app
└── packages/shared/             # shared types (server is source of truth)
```

## Copilot — how to continue this build

1. Read `.github/muse-instructions.md` first.
2. Work through `COPILOT_PROMPTS.md` in order (1 → 10). Each prompt is
   self-contained and says which files it touches.
3. Do not invent secrets, do not change the invoice numbering (`JAR-1001+`)
   or the barcode payload format (`JARVIS|<invoice>|<amount>|<currency>`)
   without Don's approval.

## License

See `LICENSE` in the GitHub repo (do not overwrite it from this package).
