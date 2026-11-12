// Load server/.env first — before any module reads process.env
// (PORT, JWT_SECRET, DATABASE_URL). dotenv does not override variables
// already set in the shell.
import "dotenv/config";
import cors from "cors";
import express, { NextFunction, Request, Response } from "express";
import rateLimit from "express-rate-limit";
import helmet from "helmet";
import { accessRouter } from "./routes/access";
import { accountsRouter } from "./routes/accounts";
import { authRouter } from "./routes/auth";
import { invoicesRouter } from "./routes/invoices";
import { paymentsRouter } from "./routes/payments";
import { portalsRouter } from "./routes/portals";
import { securityRouter } from "./routes/security";

// JARVIS API server — see README.md and docs/API.md.
// Simulated by default: no real money, email, or payment confirmation
// happens until SMTP / Stripe / crypto-provider keys are configured.

const app = express();
const PORT = Number(process.env.PORT ?? 4000);

app.disable("x-powered-by");
app.use(helmet());
app.use(cors({ origin: process.env.APP_URL ?? "http://localhost:5173", credentials: true }));
app.use(
  express.json({
    limit: "1mb",
    // Stash the raw body on the request so the crypto provider webhook
    // (payments.ts) can verify its HMAC-SHA256 signature. No other route
    // reads it.
    verify: (req, _res, buf) => {
      (req as unknown as { rawBody?: Buffer }).rawBody = buf;
    },
  }),
);

// Rate limits — login is the sensitive one.
const loginLimiter = rateLimit({ windowMs: 60_000, limit: 10, standardHeaders: true, legacyHeaders: false });
const visitLimiter = rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: true, legacyHeaders: false });

app.get("/health", (_req, res) => {
  res.json({ ok: true, data: { status: "ok", time: new Date().toISOString() } });
});

app.use("/api/auth", authRouter);
// paymentsRouter is mounted BEFORE portalsRouter on purpose: it owns the
// PUBLIC Pay-page route GET /api/portals/:slug/public-methods, and the
// portals router applies authMiddleware + requireAdmin to everything
// under /api/portals. Mounted after it, the public route would 401.
app.use("/api", paymentsRouter); // /api/payment-methods, /api/portals/:id/methods, /api/payments/:id/confirm
app.use("/api/portals", portalsRouter);
app.use("/api/access/login", loginLimiter);
app.use("/api/access", accessRouter);
app.use("/api/invoices", invoicesRouter);
app.use("/api/security/visit", visitLimiter);
app.use("/api/security", securityRouter);
app.use("/api", accountsRouter); // /api/portals/:portalId/accounts, /api/accounts/:id

// 404 for unknown API routes.
app.use("/api", (_req, res) => {
  res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Route not found" } });
});

// Error handler — never leak stack traces to clients.
app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  console.error("[server error]", err);
  res.status(500).json({ ok: false, error: { code: "INTERNAL", message: "Internal server error" } });
});

app.listen(PORT, () => {
  const simulated = !process.env.SMTP_HOST ? "SIMULATED email" : "SMTP configured";
  const stripe = process.env.STRIPE_SECRET_KEY ? "Stripe configured" : "SIMULATED payments";
  console.log(`[jarvis] server listening on http://localhost:${PORT} — ${simulated}, ${stripe}`);
});
