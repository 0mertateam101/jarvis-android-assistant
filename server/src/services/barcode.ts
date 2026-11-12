import QRCode from "qrcode";

// Payment barcode — two representations of the SAME payload:
//  1. A real QR code (PNG data URL) — scan it with any camera / wallet.
//  2. A Code128 payload string — the text a barcode scanner / printer uses.
//
// Payload format (do NOT change without Don's approval):
//   JARVIS|<invoiceNumber>|<amount>|<currency>
//   e.g. JARVIS|JAR-1001|150.00|USD
//
// The Code128 *encoding* (bars) is produced by the printer / label
// software from this payload string; this module returns the payload
// string itself plus the QR image. A future step (Copilot Prompt 6) can
// add a `bwip-js` Code128 PNG if Don wants a printable barcode image.

export function buildBarcodePayload(invoiceNumber: string, amount: string, currency: string): string {
  const safeAmount = Number(amount).toFixed(2);
  return `JARVIS|${invoiceNumber}|${safeAmount}|${currency.toUpperCase()}`;
}

/** Generate a QR code PNG data URL for the payload. */
export async function generateQrDataUrl(payload: string): Promise<string> {
  return QRCode.toDataURL(payload, { errorCorrectionLevel: "M", margin: 2, width: 440 });
}

/** Convenience: payload + QR in one call. */
export async function generateBarcode(invoiceNumber: string, amount: string, currency: string) {
  const payload = buildBarcodePayload(invoiceNumber, amount, currency);
  const qrDataUrl = await generateQrDataUrl(payload);
  return { payload, qrDataUrl, code128: payload };
}
