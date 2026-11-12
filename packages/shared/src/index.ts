// Shared types — mirrors the server API (docs/API.md).
// The server is the source of truth; keep these in sync manually.

export type Role = "ADMIN" | "CUSTOMER";
export type PortalStatus = "ACTIVE" | "ARCHIVED";
export type GrantStatus = "ACTIVE" | "REVOKED" | "TERMINATED";
export type PaymentMethodType =
  | "CASH_APP" | "VENMO" | "ZELLE" | "CHIME" | "PAYPAL"
  | "CARD" | "BANK" | "BTC" | "LTC" | "XMR" | "ETH";
export type InvoiceStatus = "PENDING" | "PAID" | "FAILED" | "REFUNDED" | "CANCELLED";
export type EmailStatus = "QUEUED" | "SENT" | "SIMULATED" | "FAILED";

export interface Portal { id: string; slug: string; name: string; description: string | null; currency: string; status: PortalStatus; ownerId: string; createdAt: string; updatedAt: string; }
export interface AccessGrant { id: string; portalId: string; email: string; status: GrantStatus; lastUsedAt: string | null; createdAt: string; }
export interface PaymentMethod { id: string; type: PaymentMethodType; label: string; handle: string; details: string | null; ownerId: string; createdAt: string; }
export interface InvoiceItem { description: string; amount: string; }
export interface Invoice { id: string; number: string; portalId: string; payerEmail: string; payerName: string | null; amount: string; currency: string; status: InvoiceStatus; barcodePayload: string; barcodeQrDataUrl: string | null; emailStatus: EmailStatus; proofHash: string | null; items: InvoiceItem[]; paymentMethodId: string | null; createdAt: string; paidAt: string | null; }
export interface TrafficLog { id: string; portalId: string; ip: string; userAgent: string | null; path: string | null; hasAccess: boolean; ptr: string | null; country: string | null; region: string | null; city: string | null; isp: string | null; org: string | null; lat: number | null; lon: number | null; lookupSource: string | null; lookupSimulated: boolean; createdAt: string; }
export interface LinkedAccount { id: string; portalId: string; type: string; label: string; handle: string; notes: string | null; createdAt: string; }

export interface ApiResponse<T> { ok: true; data: T; }
export interface ApiError { ok: false; error: { code: string; message: string }; }

/** Barcode payload: JARVIS|<invoice>|<amount>|<currency> */
export function buildBarcodePayload(invoiceNumber: string, amount: string, currency: string): string {
  return `JARVIS|${invoiceNumber}|${Number(amount).toFixed(2)}|${currency.toUpperCase()}`;
}
export const CRYPTO_TYPES: PaymentMethodType[] = ["BTC", "LTC", "XMR", "ETH"];
export function isCryptoType(type: string): boolean { return (CRYPTO_TYPES as string[]).includes(type); }
