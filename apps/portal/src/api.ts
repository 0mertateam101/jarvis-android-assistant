// Portal API client — talks to the JARVIS server (docs/API.md).
// Customer JWT is kept in sessionStorage only (never localStorage),
// so it dies when the tab closes.

const API_URL = import.meta.env.VITE_API_URL as string | undefined ?? "http://localhost:4000";

export interface PortalInfo { id: string; slug: string; name: string; }
export interface PublicMethod { id: string; type: string; label: string; handle: string; }
export interface Invoice {
  id: string; number: string; amount: string; currency: string; status: string;
  barcodePayload: string; barcodeQrDataUrl: string | null; emailStatus: string;
  proofHash: string | null; payerEmail: string; createdAt: string; paidAt: string | null;
}

export interface CryptoDetails { currency: string; address: string; amount: string; reference: string; }

/** Error from the API that carries the HTTP status, so pages can tell a
 *  denial (401/403) from any other failure. */
export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

/** The only message a 401/403 ever shows in the portal: generic, with a
 *  "contact the portal owner" hint. Never a raw error body, never a reason
 *  that leaks why access was denied (terminated, blocked, wrong portal). */
export const DENIAL_MESSAGE = "Access denied. If you believe this is a mistake, contact the portal owner.";
export function isDenial(err: unknown): boolean {
  return err instanceof ApiError && (err.status === 401 || err.status === 403);
}

const TOKEN_KEY = "jarvis_customer_token";
const PORTAL_KEY = "jarvis_portal";

export function saveSession(token: string, portal: PortalInfo, email: string): void {
  sessionStorage.setItem(TOKEN_KEY, token);
  sessionStorage.setItem(PORTAL_KEY, JSON.stringify({ ...portal, email }));
}
export function getToken(): string | null { return sessionStorage.getItem(TOKEN_KEY); }
export function getSession(): (PortalInfo & { email: string }) | null {
  const raw = sessionStorage.getItem(PORTAL_KEY);
  return raw ? (JSON.parse(raw) as PortalInfo & { email: string }) : null;
}
export function clearSession(): void { sessionStorage.removeItem(TOKEN_KEY); sessionStorage.removeItem(PORTAL_KEY); }

async function request<T>(path: string, opts: RequestInit = {}): Promise<T> {
  const token = getToken();
  const res = await fetch(`${API_URL}${path}`, {
    ...opts,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(opts.headers ?? {}) },
  });
  const body = (await res.json().catch(() => ({}))) as { ok?: boolean; data?: T; error?: { message?: string } };
  if (!res.ok || body.ok === false) throw new ApiError(res.status, body.error?.message ?? `Request failed (${res.status})`);
  return body.data as T;
}

export async function login(portalSlug: string, email: string, code: string) {
  const data = await request<{ token: string; portal: PortalInfo; email: string }>("/api/access/login", {
    method: "POST", body: JSON.stringify({ portalSlug, email, code }),
  });
  saveSession(data.token, data.portal, data.email);
  return data;
}

/** Log a visit — the server runs a reverse lookup when hasAccess is false. */
export async function logVisit(portalSlug: string, hasAccess: boolean, path: string): Promise<void> {
  try {
    await fetch(`${API_URL}/api/security/visit`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ portalSlug, hasAccess, path, userAgent: navigator.userAgent }),
    });
  } catch { /* visit logging must never break the page */ }
}

export function getPublicMethods(slug: string) {
  return request<{ methods: PublicMethod[] }>(`/api/portals/${encodeURIComponent(slug)}/public-methods`);
}

export function createInvoice(input: { portalSlug: string; payerEmail: string; payerName?: string; amount: string; currency: string; items: { description: string; amount: string }[]; paymentMethodId: string }) {
  return request<{ invoice: Invoice; paymentMethod: PublicMethod; crypto: CryptoDetails | null; code128: string; qrDataUrl: string }>("/api/invoices", {
    method: "POST", body: JSON.stringify(input),
  });
}

export function confirmPayment(invoiceId: string, reference: string) {
  return request<{ invoice: Invoice; note?: string }>(`/api/payments/${encodeURIComponent(invoiceId)}/confirm`, {
    method: "POST", body: JSON.stringify({ reference }),
  });
}

export function getInvoice(id: string) {
  return request<{ invoice: Invoice }>(`/api/invoices/${encodeURIComponent(id)}`);
}

/** Fetch the receipt PDF with the customer JWT — a plain <a href> would
 *  send no Authorization header and the server would answer 401. Throws
 *  ApiError (401/403 → the generic denial) or an Error when the response
 *  is not a PDF. */
export async function downloadReceiptPdf(id: string): Promise<Blob> {
  const token = getToken();
  const res = await fetch(receiptPdfUrl(id), {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: { message?: string } };
    throw new ApiError(res.status, body.error?.message ?? `Request failed (${res.status})`);
  }
  const type = res.headers.get("content-type") ?? "";
  if (!type.includes("application/pdf")) throw new Error("Receipt download did not return a PDF.");
  return res.blob();
}

export function receiptPdfUrl(id: string): string { return `${API_URL}/api/invoices/${encodeURIComponent(id)}/pdf`; }
