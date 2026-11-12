import nodemailer from "nodemailer";

// Email service — SIMULATED by default.
// Real sending only happens when SMTP_HOST/SMTP_USER/SMTP_PASS are set.
// In SIMULATED mode the email is logged (without secrets/codes) and the
// caller stores EmailStatus.SIMULATED in the DB, so Don can tell real
// from demo in the data itself.

export type EmailStatus = "QUEUED" | "SENT" | "SIMULATED" | "FAILED";

export interface SendEmailInput {
  to: string;
  subject: string;
  text: string;
  html?: string;
}

function smtpConfigured(): boolean {
  return Boolean(process.env.SMTP_HOST && process.env.SMTP_USER && process.env.SMTP_PASS);
}

function getTransporter() {
  return nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT ?? 587),
    secure: Number(process.env.SMTP_PORT) === 465,
    auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
  });
}

/**
 * Send an email. Returns the status to store in the DB.
 * NEVER call this with an access code in the body unless Don explicitly
 * approved that template (human approval gate — see muse-instructions).
 */
export async function sendEmail(input: SendEmailInput): Promise<EmailStatus> {
  if (!smtpConfigured()) {
    console.log(
      `[email SIMULATED] to=${input.to} subject=${JSON.stringify(input.subject)} ` +
        `(SMTP not configured — no email left the server)`,
    );
    return "SIMULATED";
  }
  try {
    await getTransporter().sendMail({
      from: process.env.SMTP_FROM ?? "Jarvis <no-reply@example.com>",
      to: input.to,
      subject: input.subject,
      text: input.text,
      html: input.html,
    });
    console.log(`[email SENT] to=${input.to} subject=${JSON.stringify(input.subject)}`);
    return "SENT";
  } catch (err) {
    console.error("[email FAILED]", err instanceof Error ? err.message : err);
    return "FAILED";
  }
}

/** Barcode email body for a new invoice. `qrDataUrl` is embedded in the HTML. */
export function barcodeEmailBody(opts: {
  portalName: string;
  invoiceNumber: string;
  amount: string;
  currency: string;
  barcodePayload: string;
  qrDataUrl: string;
  methodLabel: string;
  methodHandle: string;
}): { subject: string; text: string; html: string } {
  const subject = `Your payment barcode — ${opts.invoiceNumber} (${opts.portalName})`;
  const text =
    `Your payment for ${opts.portalName} is ready.\n\n` +
    `Invoice: ${opts.invoiceNumber}\nAmount: ${opts.amount} ${opts.currency}\n` +
    `Pay with: ${opts.methodLabel} (${opts.methodHandle})\n` +
    `Barcode: ${opts.barcodePayload}\n\n` +
    `Show the barcode / QR code in the attached image at checkout, or pay ` +
    `with the method above. Your receipt will follow once payment completes.`;
  const html =
    `<p>Your payment for <strong>${opts.portalName}</strong> is ready.</p>` +
    `<p>Invoice: <strong>${opts.invoiceNumber}</strong><br/>` +
    `Amount: <strong>${opts.amount} ${opts.currency}</strong><br/>` +
    `Pay with: <strong>${opts.methodLabel}</strong> (${opts.methodHandle})</p>` +
    `<p><img src="${opts.qrDataUrl}" alt="Payment QR code" width="220" height="220"/></p>` +
    `<p>Barcode: <code>${opts.barcodePayload}</code></p>` +
    `<p>Your receipt will follow once payment completes.</p>`;
  return { subject, text, html };
}

export function receiptEmailBody(opts: {
  portalName: string;
  invoiceNumber: string;
  amount: string;
  currency: string;
  proofHash: string;
}): { subject: string; text: string } {
  const subject = `Receipt — ${opts.invoiceNumber} paid (${opts.portalName})`;
  const text =
    `Payment received for ${opts.portalName}.\n\n` +
    `Invoice: ${opts.invoiceNumber}\nAmount paid: ${opts.amount} ${opts.currency}\n` +
    `Proof of payment: ${opts.proofHash}\n\nThank you.`;
  return { subject, text };
}
