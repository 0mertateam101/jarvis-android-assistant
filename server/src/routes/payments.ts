import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import { getCryptoService, isCryptoType } from "../services/crypto";
import { buildProofHash } from "../services/invoice";

// Payment methods (ADMIN) + assignment to portals + payment confirmation.
// `handle` is a public handle / address only — never a secret or private key.
// Invoices are NEVER marked PAID on QR scan alone (see invoices.ts +
// services/crypto.ts): confirmation needs a provider webhook, an on-chain
// check, or Don's manual confirm (dev / simulated mode).

export const paymentsRouter = Router();

const methodSchema = z.object({
  type: z.enum(["CASH_APP", "VENMO", "ZELLE", "CHIME", "PAYPAL", "CARD", "BANK", "BTC", "LTC", "XMR", "ETH"]),
  label: z.string().min(1).max(120),
  handle: z.string().min(1).max(200),
  details: z.record(z.string()).optional(),
});

const confirmSchema = z.object({
  reference: z.string().min(1).max(200),
  method: z.string().min(1).max(60).optional(),
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
paymentsRouter.get("/portals/:slug/public-methods", async (req, res) => {
  const portal = await prisma.portal.findUnique({
    where: { slug: req.params.slug },
    include: { methods: { include: { paymentMethod: true } } },
  });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const methods = portal.methods.map((m) => ({
    id: m.paymentMethod.id,
    type: m.paymentMethod.type,
    label: m.paymentMethod.label,
    handle: m.paymentMethod.handle,
  }));
  res.json({ ok: true, data: { methods } });
});

// --- Payment confirmation ---
paymentsRouter.post("/payments/:invoiceId/confirm", authMiddleware, async (req: AuthedRequest, res) => {
  const parsed = confirmSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
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
  const methodType = invoice.paymentMethod?.type ?? parsed.data.method ?? "UNKNOWN";
  let confirmed = false;
  let simulated = true;
  let note = "";

  if (methodType && isCryptoType(methodType)) {
    const service = getCryptoService();
    const result = await service.verify({ currency: methodType, reference: invoice.number, txHash: parsed.data.reference });
    confirmed = result.confirmed;
    simulated = result.simulated;
    note = result.note;
  } else if (req.auth!.role === "ADMIN" && parsed.data.adminConfirm) {
    // Don's manual confirm in the app (dev / simulated mode, or after he
    // has verified a wallet/bank payment out-of-band).
    confirmed = true;
    simulated = true;
    note = "Confirmed manually by Don in the Jarvis app (simulated).";
  } else {
    // Fiat/wallet reference submitted by the customer: record it, but do
    // NOT mark PAID. Don (or a Stripe webhook — Prompt 7) confirms.
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
    res.json({ ok: true, data: { invoice, payment, note } });
    return;
  }
  const paidAt = new Date();
  const proof = buildProofHash(invoice.number, invoice.amount.toString(), invoice.currency, parsed.data.reference, paidAt.toISOString());
  const updated = await prisma.invoice.update({
    where: { id: invoice.id },
    data: { status: "PAID", paidAt, proofHash: proof },
  });
  await prisma.payment.update({ where: { id: payment.id }, data: { proofHash: proof } });
  res.json({ ok: true, data: { invoice: updated, payment: { ...payment, proofHash: proof }, note } });
});
