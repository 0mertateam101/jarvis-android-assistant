import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import { generateBarcode } from "../services/barcode";
import { getCryptoService, isCryptoType } from "../services/crypto";
import { barcodeEmailBody, receiptEmailBody, sendEmail } from "../services/email";
import { generateReceiptPdf, nextInvoiceNumber } from "../services/invoice";

// Invoices — JAR-1001+, payment barcode (QR + Code128 payload) emailed to
// the payer, receipt PDF with proof hash on completion.
// Creating an invoice does NOT mark it paid. See payments.ts.

export const invoicesRouter = Router();

const createSchema = z.object({
  portalSlug: z.string().min(1),
  payerEmail: z.string().email(),
  payerName: z.string().max(120).optional(),
  amount: z.string().regex(/^\d+(\.\d{1,2})$/, "amount must be a decimal like 150.00"),
  currency: z.string().length(3).default("USD"),
  items: z.array(z.object({ description: z.string().min(1), amount: z.string().min(1) })).min(1),
  paymentMethodId: z.string().min(1),
});

function parseItems(raw: string): Array<{ description: string; amount: string }> {
  try {
    return JSON.parse(raw) as Array<{ description: string; amount: string }>;
  } catch {
    return [];
  }
}

invoicesRouter.post("/", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = createSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: parsed.error.issues[0]?.message ?? "Invalid body" } });
    return;
  }
  // ADMIN only (requireAdmin above — a CUSTOMER token gets 403 here).
  // The portal must belong to the calling admin.
  const portal = await prisma.portal.findFirst({ where: { slug: parsed.data.portalSlug, ownerId: req.auth!.sub } });
  if (!portal || portal.status !== "ACTIVE") {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  // The chosen method must be assigned to this portal.
  const assignment = await prisma.portalPaymentMethod.findUnique({
    where: { portalId_paymentMethodId: { portalId: portal.id, paymentMethodId: parsed.data.paymentMethodId } },
    include: { paymentMethod: true },
  });
  if (!assignment) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Payment method is not available on this portal" } });
    return;
  }
  const method = assignment.paymentMethod;
  const number = await nextInvoiceNumber();
  const { payload, qrDataUrl } = await generateBarcode(number, parsed.data.amount, parsed.data.currency);

  const invoice = await prisma.invoice.create({
    data: {
      number,
      portalId: portal.id,
      payerEmail: parsed.data.payerEmail.toLowerCase(),
      payerName: parsed.data.payerName ?? null,
      amount: parsed.data.amount,
      currency: parsed.data.currency.toUpperCase(),
      status: "PENDING",
      barcodePayload: payload,
      barcodeQrDataUrl: qrDataUrl,
      emailStatus: "SIMULATED",
      items: JSON.stringify(parsed.data.items),
      paymentMethodId: method.id,
    },
  });

  // Crypto details (address + amount) for the Pay page — public address only.
  let crypto: { currency: string; address: string; amount: string; reference: string } | null = null;
  if (isCryptoType(method.type)) {
    const quote = await getCryptoService().quote({
      currency: method.type,
      address: method.handle,
      fiatAmount: parsed.data.amount,
      fiatCurrency: parsed.data.currency,
    });
    crypto = { currency: quote.currency, address: quote.address, amount: quote.amount, reference: number };
  }

  // Email the barcode to the customer (SIMULATED unless SMTP is set).
  const email = barcodeEmailBody({
    portalName: portal.name,
    invoiceNumber: number,
    amount: parsed.data.amount,
    currency: parsed.data.currency,
    barcodePayload: payload,
    qrDataUrl,
    methodLabel: method.label,
    methodHandle: method.handle,
  });
  const emailStatus = await sendEmail({ to: invoice.payerEmail, ...email });
  const updated = await prisma.invoice.update({ where: { id: invoice.id }, data: { emailStatus } });

  // code128 is the Code128 payload string (same as barcodePayload); qrDataUrl
  // is the QR image — both returned top-level for the Pay page / printer.
  res.status(201).json({ ok: true, data: { invoice: updated, paymentMethod: method, crypto, code128: payload, qrDataUrl } });
});

invoicesRouter.get("/:id", authMiddleware, async (req: AuthedRequest, res) => {
  const invoice = await prisma.invoice.findUnique({ where: { id: req.params.id }, include: { payments: true, paymentMethod: true, portal: true } });
  if (!invoice) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Invoice not found" } });
    return;
  }
  if (req.auth!.role === "CUSTOMER" && req.auth!.portalId !== invoice.portalId) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  if (req.auth!.role === "ADMIN" && invoice.portal.ownerId !== req.auth!.sub) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Invoice not found" } });
    return;
  }
  res.json({ ok: true, data: { invoice: { ...invoice, items: parseItems(invoice.items as unknown as string) } } });
});

invoicesRouter.get("/:id/pdf", authMiddleware, async (req: AuthedRequest, res) => {
  const invoice = await prisma.invoice.findUnique({ where: { id: req.params.id }, include: { portal: true, paymentMethod: true, payments: true } });
  if (!invoice) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Invoice not found" } });
    return;
  }
  if (req.auth!.role === "CUSTOMER" && req.auth!.portalId !== invoice.portalId) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  if (req.auth!.role === "ADMIN" && invoice.portal.ownerId !== req.auth!.sub) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Invoice not found" } });
    return;
  }
  const pdf = await generateReceiptPdf({
    number: invoice.number,
    portalName: invoice.portal.name,
    payerEmail: invoice.payerEmail,
    payerName: invoice.payerName,
    amount: invoice.amount.toString(),
    currency: invoice.currency,
    status: invoice.status,
    items: parseItems(invoice.items as unknown as string),
    methodLabel: invoice.paymentMethod?.label,
    methodType: invoice.paymentMethod?.type,
    reference: invoice.payments?.[0]?.reference ?? null,
    proofHash: invoice.proofHash,
    barcodePayload: invoice.barcodePayload,
    createdAt: invoice.createdAt,
    paidAt: invoice.paidAt,
  });
  res.setHeader("Content-Type", "application/pdf");
  res.setHeader("Content-Disposition", `attachment; filename="${invoice.number}-receipt.pdf"`);
  res.send(pdf);
});

// Admin: list invoices for a portal. Also sends the receipt email when an
// invoice flips to PAID via a manual/admin path — the payments route is
// the primary place this happens; this helper is exported for reuse.
export async function sendReceiptEmail(invoiceId: string): Promise<void> {
  const invoice = await prisma.invoice.findUnique({ where: { id: invoiceId }, include: { portal: true } });
  if (!invoice || invoice.status !== "PAID" || !invoice.proofHash) return;
  const body = receiptEmailBody({
    portalName: invoice.portal.name,
    invoiceNumber: invoice.number,
    amount: invoice.amount.toString(),
    currency: invoice.currency,
    proofHash: invoice.proofHash,
  });
  await sendEmail({ to: invoice.payerEmail, ...body });
}

// Deprecated alias for the canonical GET /api/portals/:portalId/invoices
// (see portals.ts + docs/API.md). Kept so existing callers keep working.
// Owner-scoped like the canonical route: unknown / unowned portal → 404.
invoicesRouter.get("/portals/:portalId/list", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const portal = await prisma.portal.findFirst({ where: { id: req.params.portalId, ownerId: req.auth!.sub } });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const invoices = await prisma.invoice.findMany({ where: { portalId: portal.id }, orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { invoices } });
});
