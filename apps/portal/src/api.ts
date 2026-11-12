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
  if (!res.ok || body.ok === false) throw new Error(body.error?.message ?? `Request failed (${res.status})`);
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
  return request<{ invoice: Invoice; paymentMethod: PublicMethod; crypto: CryptoDetails | null }>("/api/invoices", {
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

export function receiptPdfUrl(id: string): string { return `${API_URL}/api/invoices/${encodeURIComponent(id)}/pdf`; }
