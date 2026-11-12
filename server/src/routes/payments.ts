import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import { cryptoMode, cryptoReferenceError, getCryptoService, isCryptoType, verifyWebhookSignature } from "../services/crypto";
import { verifyCaptcha } from "../services/captcha";
import { buildProofHash } from "../services/invoice";
import { sendReceiptEmail } from "./invoices";
import { clientIp, isEmailBlocked, isIpBlocked } from "./security";

// Payment methods (ADMIN) + assignment to portals + payment confirmation.
// `handle` is a public handle / address only — never a secret or private key.
// Invoices are NEVER marked PAID on QR scan alone (see invoices.ts +
// services/crypto.ts): confirmation needs a provider webhook, an on-chain
// check, or Don's manual confirm (dev / simulated mode).

export const paymentsRouter = Router();

const methodSchema = z.object({
  type: z.enum(["CASH_APP", "VENMO", "ZELLE", "CHIME", "PAYPAL", "CARD", "BANK", "BTC", "LTC", "XMR", "ETH", "USDT", "USDC", "DOGE"]),
  label: z.string().min(1).max(120),
  handle: z.string().min(1).max(200),
  details: z.record(z.string()).optional(),
});

const confirmSchema = z.object({
  reference: z.string().min(1).max(200),
  method: z.string().min(1).max(60).optional(),
  // reCAPTCHA token from the Pay page (Prompt 12). Only checked for
  // CUSTOMER submits — Don's ADMIN manual confirm never needs one.
  captchaToken: z.string().max(2000).optional(),
  // Don's explicit manual confirm (admin only, dev/simulated mode).
  // In production with a real provider, the webhook — not this flag —
  // is what confirms. This flag is ignored for non-admin callers.
  adminConfirm: z.boolean().optional(),
});

// --- Payment methods (ADMIN) ---

// Anything that looks like a secret — reject with a clear 400, never store it.
// Same list as the linked-account check (Prompt 3, accounts.ts).
const SECRET_PATTERNS: RegExp[] = [
  /private\s*key/i,
  /seed\s*phrase/i,
  /\bmnemonic\b/i,
  /\bpassword\b/i,
  /api[-_ ]?key/i,
  /client\s*secret/i,
  /secret\s*key/i,
  /-----BEGIN[^-]*PRIVATE KEY-----/i,
  /\b[0-9a-f]{64}\b/i, // raw 64-hex private key
];

function looksLikeSecret(value: string): boolean {
  return SECRET_PATTERNS.some((re) => re.test(value));
}

// Loose per-type format check for the public handle / address. Deliberately
// loose — this is a sanity check, not a full validator. Returns an error
// message, or null when the handle looks plausible for the type.
function handleFormatError(type: string, handle: string): string | null {
  switch (type) {
    case "CASH_APP":
    case "CHIME":
      return /^\$[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/.test(handle) ? null : "handle must look like $username";
    case "VENMO":
      return /^@[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/.test(handle) ? null : "handle must look like @username";
    case "ZELLE":
    case "PAYPAL": {
      const email = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(handle);
      const digits = handle.replace(/\D/g, "");
      const phone = /^\+?[0-9][0-9\s().-]{6,}$/.test(handle) && digits.length >= 7;
      return email || phone ? null : "handle must be an email address or phone number";
    }
    case "BTC":
      return /^(bc1[a-z0-9]{6,}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})$/.test(handle)
        ? null
        : "handle must be a BTC address";
    case "LTC":
      return /^(ltc1[a-z0-9]{6,}|[LM3][a-km-zA-HJ-NP-Z1-9]{26,33})$/.test(handle)
        ? null
        : "handle must be an LTC address";
    case "XMR":
      return /^4[0-9A-Za-z]{94}$/.test(handle) ? null : "handle must be an XMR address";
    case "ETH":
      return /^0x[a-fA-F0-9]{40}$/.test(handle) ? null : "handle must be an ETH address (0x + 40 hex chars)";
    case "USDT":
    case "USDC": {
      // Stablecoins live on several chains — accept either common form
      // and never lock to one chain: ERC-20 style (0x + 40 hex) or
      // Tron style (T + 33 base58 chars). A 0x address is 40 hex, not
      // 64, so it does not trip the secret check above.
      const erc20 = /^0x[a-fA-F0-9]{40}$/.test(handle);
      const tron = /^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(handle);
      return erc20 || tron ? null : "handle must be a USDT/USDC address (0x + 40 hex, or T + 33 base58 chars)";
    }
    case "DOGE":
      // Dogecoin: D prefix (P2SH: A prefix), base58, 26–34 chars total.
      return /^[DA][a-km-zA-HJ-NP-Z1-9]{25,33}$/.test(handle)
        ? null
        : "handle must be a DOGE address (D or A prefix, 26–34 chars)";
    case "CARD":
      return /^\d{13,19}$/.test(handle.replace(/[\s-]/g, "")) ? null : "handle must be a card number (13–19 digits)";
    case "BANK":
      return handle.trim().length >= 4 ? null : "handle must be at least 4 characters";
    default:
      return null;
  }
}

// Look a portal up by id OR slug, scoped to the calling admin — same
// behaviour as the portal routes (Prompt 3).
async function findOwnedPortal(ownerId: string, idOrSlug: string) {
  const byId = await prisma.portal.findFirst({ where: { id: idOrSlug, ownerId } });
  if (byId) return byId;
  return prisma.portal.findFirst({ where: { slug: idOrSlug, ownerId } });
}

paymentsRouter.post("/payment-methods", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = methodSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  if (looksLikeSecret(parsed.data.handle)) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Never store a private key or seed phrase" } });
    return;
  }
  if (parsed.data.details && Object.values(parsed.data.details).some((v) => looksLikeSecret(v))) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Never store a private key or seed phrase" } });
    return;
  }
  const formatError = handleFormatError(parsed.data.type, parsed.data.handle);
  if (formatError) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: formatError } });
    return;
  }
  const method = await prisma.paymentMethod.create({
    data: {
      ...parsed.data,
      details: parsed.data.details ? JSON.stringify(parsed.data.details) : null,
      ownerId: req.auth!.sub,
    },
  });
  res.status(201).json({ ok: true, data: { method } });
});

paymentsRouter.get("/payment-methods", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const methods = await prisma.paymentMethod.findMany({ where: { ownerId: req.auth!.sub }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { methods } });
});

paymentsRouter.get("/payment-methods/:id", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const method = await prisma.paymentMethod.findFirst({ where: { id: req.params.id, ownerId: req.auth!.sub } });
  if (!method) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Payment method not found" } });
    return;
  }
  res.json({ ok: true, data: { method } });
});

paymentsRouter.delete("/payment-methods/:id", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const method = await prisma.paymentMethod.findFirst({ where: { id: req.params.id, ownerId: req.auth!.sub } });
  if (!method) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Payment method not found" } });
    return;
  }
  try {
    // Portal assignments cascade away (PortalPaymentMethod onDelete: Cascade).
    await prisma.paymentMethod.delete({ where: { id: method.id } });
  } catch (e) {
    // A method already used by an invoice cannot be deleted outright.
    const code = (e as { code?: string }).code;
    if (code === "P2003") {
      res.status(409).json({ ok: false, error: { code: "CONFLICT", message: "Payment method is used by an invoice" } });
      return;
    }
    throw e;
  }
  res.json({ ok: true, data: { ok: true } });
});

// Assign / unassign a method to a portal (ADMIN).
paymentsRouter.post("/portals/:portalId/methods", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = z.object({ paymentMethodId: z.string().min(1) }).safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  const method = await prisma.paymentMethod.findFirst({ where: { id: parsed.data.paymentMethodId, ownerId: req.auth!.sub } });
  if (!portal || !method) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal or payment method not found" } });
    return;
  }
  // Idempotent: assigning twice returns the same link, never a duplicate.
  const link = await prisma.portalPaymentMethod.upsert({
    where: { portalId_paymentMethodId: { portalId: portal.id, paymentMethodId: method.id } },
    update: {},
    create: { portalId: portal.id, paymentMethodId: method.id },
  });
  res.status(201).json({ ok: true, data: { link } });
});

paymentsRouter.delete("/portals/:portalId/methods/:methodId", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const portal = await findOwnedPortal(req.auth!.sub, req.params.portalId);
  const method = await prisma.paymentMethod.findFirst({ where: { id: req.params.methodId, ownerId: req.auth!.sub } });
  if (!portal || !method) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal or payment method not found" } });
    return;
  }
  await prisma.portalPaymentMethod.deleteMany({
    where: { portalId: portal.id, paymentMethodId: method.id },
  });
  res.json({ ok: true, data: { ok: true } });
});

// Public list of methods assigned to a portal (customer Pay page).
// Also carries the portal's branding + downloadable documents (Prompt 12)
// so the customer portal can render the logo/banner and list documents
// without a second call — this is the portal's public read.
paymentsRouter.get("/portals/:slug/public-methods", async (req, res) => {
  const portal = await prisma.portal.findUnique({
    where: { slug: req.params.slug },
    include: { methods: { include: { paymentMethod: true } }, assets: true },
  });
  // ARCHIVED portals are invisible on the public routes, exactly like a
  // missing portal — no payment methods, branding, or documents leak.
  if (!portal || portal.status !== "ACTIVE") {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const methods = portal.methods.map((m) => ({
    id: m.paymentMethod.id,
    type: m.paymentMethod.type,
    label: m.paymentMethod.label,
    handle: m.paymentMethod.handle,
  }));
  const logo = portal.assets.find((a) => a.kind === "LOGO") ?? null;
  const banner = portal.assets.find((a) => a.kind === "BANNER") ?? null;
  const documents = portal.assets
    .filter((a) => a.kind === "DOCUMENT" || a.kind === "FILE")
    .map((a) => ({ id: a.id, kind: a.kind, originalName: a.originalName, mimeType: a.mimeType, size: a.size }));
  res.json({ ok: true, data: { methods, logoAssetId: logo?.id ?? null, bannerAssetId: banner?.id ?? null, documents } });
});

// --- Payment confirmation ---
// HARD RULE (Prompt 7): an invoice is NEVER marked PAID on a QR/barcode
// scan alone, and never on a customer-submitted txHash/reference alone.
// PAID needs a confirmation record: a provider webhook, an on-chain /
// provider verification, or Don's manual confirm — and Don's manual
// confirm only works in SIMULATED mode. With a real provider configured,
// manual confirm is refused and only the webhook can flip PAID.
// CAPTCHA RULE (Prompt 12): a CUSTOMER submit must pass reCAPTCHA
// (verifyCaptcha in services/captcha.ts) — in SIMULATED mode the check
// always passes and is labelled simulated; when configured, a missing or
// invalid token is a 400 and nothing is recorded. Don's ADMIN manual
// confirm never needs a captcha.
paymentsRouter.post("/payments/:invoiceId/confirm", authMiddleware, async (req: AuthedRequest, res) => {
  const parsed = confirmSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  // Don's manual confirm is an ADMIN-only action. A customer trying to
  // self-confirm is forbidden — the flag is never silently ignored.
  if (parsed.data.adminConfirm === true && req.auth!.role !== "ADMIN") {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Only Don can manually confirm payments" } });
    return;
  }
  const invoice = await prisma.invoice.findUnique({
    where: { id: req.params.invoiceId },
    include: { paymentMethod: true, portal: true },
  });
  if (!invoice) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Invoice not found" } });
    return;
  }
  // Customers may only confirm invoices on their own portal.
  if (req.auth!.role === "CUSTOMER" && req.auth!.portalId !== invoice.portalId) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  if (invoice.status === "PAID") {
    res.json({ ok: true, data: { invoice, payment: null, note: "Already paid" } });
    return;
  }
  // Blocklist enforcement (Prompt 8): a blocked payer can NEVER pay —
  // generic denial, no payment row is created, the invoice stays PENDING.
  // This applies to customer and ADMIN confirm alike; unblock first,
  // then confirm.
  if ((await isEmailBlocked(invoice.portalId, invoice.payerEmail)) || (await isIpBlocked(clientIp(req), invoice.portalId))) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  // reCAPTCHA (Prompt 12): a CUSTOMER payment submit must come from a
  // human. In SIMULATED mode (no RECAPTCHA_SECRET_KEY configured) the
  // check always passes and the response says so — the submit is NOT
  // blocked. When configured, a missing/invalid token is a 400 and
  // nothing is recorded. Don's ADMIN manual confirm path below is
  // unchanged and never needs a captcha.
  let captcha: { required: boolean; ok: boolean; simulated: boolean } | undefined;
  if (req.auth!.role === "CUSTOMER" && parsed.data.adminConfirm !== true) {
    captcha = await verifyCaptcha(parsed.data.captchaToken);
    if (!captcha.ok) {
      res.status(400).json({
        ok: false,
        error: { code: "VALIDATION_ERROR", message: "Please complete the captcha to confirm you are human before submitting your payment." },
      });
      return;
    }
  }
  const methodType = invoice.paymentMethod?.type ?? parsed.data.method ?? "UNKNOWN";
  let confirmed = false;
  let simulated = true;
  let note = "";

  if (methodType && isCryptoType(methodType)) {
    // Crypto: the submitted reference is a txHash / provider reference.
    // Validate its shape before it is ever stored.
    const refError = cryptoReferenceError(parsed.data.reference);
    if (refError) {
      res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: refError } });
      return;
    }
    if (parsed.data.adminConfirm === true && req.auth!.role === "ADMIN") {
      if (cryptoMode() === "provider") {
        // With a real provider configured, only the provider webhook /
        // on-chain check can confirm. Don's manual confirm is refused.
        res.status(400).json({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Manual confirm is disabled when a crypto provider is configured — confirmation must come from the provider webhook or an on-chain check",
          },
        });
        return;
      }
      // SIMULATED mode: Don's manual confirm is the confirmation. It is
      // explicitly labelled simulated — no on-chain or provider check ran.
      confirmed = true;
      simulated = true;
      note = "Confirmed manually by Don in the Jarvis app (SIMULATED — no on-chain or provider verification was performed).";
    } else {
      // A customer-submitted txHash alone NEVER confirms. verify() is the
      // only other path, and in SIMULATED mode it always returns
      // confirmed=false — Don must confirm manually. In provider mode the
      // (still unimplemented) provider check is the only path, and the
      // webhook is what actually flips PAID.
      const service = getCryptoService();
      const result = await service.verify({ currency: methodType, reference: invoice.number, txHash: parsed.data.reference });
      confirmed = result.confirmed;
      simulated = result.simulated;
      note = result.note;
    }
  } else if (req.auth!.role === "ADMIN" && parsed.data.adminConfirm) {
    // Don's manual confirm in the app (dev / simulated mode, or after he
    // has verified a wallet/bank payment out-of-band).
    confirmed = true;
    simulated = true;
    note = "Confirmed manually by Don in the Jarvis app (simulated).";
  } else {
    // Fiat/wallet reference submitted by the customer: record it, but do
    // NOT mark PAID. Don (or a Stripe webhook) confirms.
    note = "Reference recorded. Awaiting confirmation — invoice stays PENDING until Don or the payment provider confirms.";
  }

  const payment = await prisma.payment.create({
    data: {
      invoiceId: invoice.id,
      method: methodType,
      amount: invoice.amount,
      currency: invoice.currency,
      reference: parsed.data.reference,
      status: confirmed ? "CONFIRMED" : "PENDING",
      simulated,
      proofHash: null,
    },
  });

  if (!confirmed) {
    res.json({ ok: true, data: { invoice, payment, note, ...(captcha ? { captcha } : {}) } });
    return;
  }
  const paidAt = new Date();
  const proof = buildProofHash(invoice.number, invoice.amount.toString(), invoice.currency, parsed.data.reference, paidAt.toISOString());
  const updated = await prisma.invoice.update({
    where: { id: invoice.id },
    data: { status: "PAID", paidAt, proofHash: proof },
  });
  await prisma.payment.update({ where: { id: payment.id }, data: { proofHash: proof } });
  // Receipt email (queued or SIMULATED) now that the invoice is PAID.
  await sendReceiptEmail(invoice.id);
  res.json({ ok: true, data: { invoice: updated, payment: { ...payment, proofHash: proof }, note, ...(captcha ? { captcha } : {}) } });
});

// --- Crypto provider webhook (BTCPay / Coinbase Commerce) ---
// INTEGRATION POINT — the production path to PAID for crypto invoices.
// Point the provider at POST /api/webhooks/crypto/:provider with the
// webhook secret configured (BTCPAY_WEBHOOK_SECRET /
// COINBASE_WEBHOOK_SECRET — see .env.example). The request is
// authenticated by HMAC-SHA256 over the raw body (BTCPay-Sig /
// X-CC-Webhook-Signature header). No auth JWT is needed — the signature
// IS the auth, and a missing/invalid signature is a 401.
//
// Body contract (both providers are normalised to this shape):
//   { "reference": "<invoice number, e.g. JAR-1001>",
//     "txHash": "<transaction hash, optional>",
//     "status": "confirmed" | "settled" | "complete" | "paid" }
// Coinbase charge events are also accepted: { "event": { "type":
// "charge:confirmed", "data": { "metadata": { "reference": "JAR-1001" } } } }.
// A valid signature with a non-confirmation event (e.g. charge created)
// is acknowledged with { ignored: true } and changes nothing.
paymentsRouter.post("/webhooks/crypto/:provider", async (req, res) => {
  const provider = req.params.provider;
  if (provider !== "btcpay" && provider !== "coinbase") {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Unknown provider" } });
    return;
  }
  const secret = provider === "btcpay" ? process.env.BTCPAY_WEBHOOK_SECRET : process.env.COINBASE_WEBHOOK_SECRET;
  if (!secret) {
    res.status(501).json({ ok: false, error: { code: "WEBHOOK_NOT_CONFIGURED", message: "Crypto webhook secret is not configured for this provider" } });
    return;
  }
  const signatureHeader = provider === "btcpay" ? req.headers["btcpay-sig"] : req.headers["x-cc-webhook-signature"];
  const rawBody = (req as unknown as { rawBody?: Buffer }).rawBody ?? Buffer.from(JSON.stringify(req.body ?? {}));
  if (!verifyWebhookSignature(secret, rawBody, typeof signatureHeader === "string" ? signatureHeader : undefined)) {
    res.status(401).json({ ok: false, error: { code: "UNAUTHORIZED", message: "Invalid webhook signature" } });
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const nestedMeta = (body.data as Record<string, unknown> | undefined)?.metadata as Record<string, unknown> | undefined;
  const reference =
    (typeof body.reference === "string" && body.reference) ||
    (typeof (body.metadata as Record<string, unknown> | undefined)?.reference === "string" &&
      ((body.metadata as Record<string, unknown>).reference as string)) ||
    (typeof nestedMeta?.reference === "string" && (nestedMeta.reference as string)) ||
    "";
  const statusRaw =
    (typeof body.status === "string" && body.status) ||
    (typeof body.type === "string" && body.type) ||
    (typeof (body.event as Record<string, unknown> | undefined)?.type === "string" &&
      ((body.event as Record<string, unknown>).type as string)) ||
    "";
  if (!reference) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Webhook body must include a reference (invoice number)" } });
    return;
  }
  const confirmedStatuses = new Set(["confirmed", "settled", "complete", "completed", "paid", "charge:confirmed", "invoicesettled", "invoicepaid"]);
  if (!confirmedStatuses.has(statusRaw.toLowerCase().replace(/[^a-z0-9:]/g, ""))) {
    res.json({ ok: true, data: { ignored: true, reason: `event "${statusRaw || "(none)"}" is not a payment confirmation` } });
    return;
  }
  const invoice = await prisma.invoice.findUnique({ where: { number: reference }, include: { paymentMethod: true } });
  if (!invoice) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Invoice not found" } });
    return;
  }
  if (!invoice.paymentMethod || !isCryptoType(invoice.paymentMethod.type)) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invoice is not a crypto invoice" } });
    return;
  }
  if (invoice.status === "PAID") {
    res.json({ ok: true, data: { invoice, payment: null, alreadyPaid: true, note: "Already paid" } });
    return;
  }
  const txHash = typeof body.txHash === "string" && body.txHash.length > 0 ? body.txHash : reference;
  const refError = cryptoReferenceError(txHash);
  if (refError) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: refError } });
    return;
  }
  // Provider-verified confirmation: this is a real (non-simulated)
  // confirmation record — the only path to PAID in provider mode.
  const paidAt = new Date();
  const proof = buildProofHash(invoice.number, invoice.amount.toString(), invoice.currency, txHash, paidAt.toISOString());
  const payment = await prisma.payment.create({
    data: {
      invoiceId: invoice.id,
      method: invoice.paymentMethod.type,
      amount: invoice.amount,
      currency: invoice.currency,
      reference: txHash,
      status: "CONFIRMED",
      simulated: false,
      proofHash: proof,
    },
  });
  const updated = await prisma.invoice.update({
    where: { id: invoice.id },
    data: { status: "PAID", paidAt, proofHash: proof },
  });
  await sendReceiptEmail(invoice.id);
  res.json({
    ok: true,
    data: { invoice: updated, payment, note: `Confirmed by ${provider} webhook (provider verification, not simulated).` },
  });
});
