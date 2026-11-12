import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { DENIAL_MESSAGE, confirmPayment, createInvoice, getPublicMethods, getSession, isDenial, type CryptoDetails, type Invoice, type PublicMethod } from "../api";

// Pay page: pick a method → create invoice → show QR + Code128 barcode
// (also emailed to the payer by the server) → submit a payment reference
// → receipt. The invoice is NOT paid by scanning the barcode, and a
// customer-submitted reference alone never marks it PAID — Don or the
// payment provider confirms it, and the receipt then shows the proof hash.
//
// reCAPTCHA (Prompt 12): when VITE_RECAPTCHA_SITE_KEY is set, the
// "I'm not a robot" checkbox must be solved before the payment submit
// button enables, and the token is sent with the submit. When no site
// key is set, the page shows a clearly-labelled simulated notice and
// the button stays enabled — the server answers captcha.simulated in
// that case. No captcha npm dependency: the Google script is loaded
// directly (reCAPTCHA v2, explicit render).

const SITE_KEY = (import.meta.env.VITE_RECAPTCHA_SITE_KEY as string | undefined) ?? "";

// Minimal typing for the reCAPTCHA v2 explicit-render API we use.
interface Grecaptcha {
  render: (el: HTMLElement, opts: { sitekey: string; callback: (token: string) => void; "expired-callback": () => void }) => number;
  reset: (widgetId?: number) => void;
}
declare global {
  interface Window { grecaptcha?: Grecaptcha; }
}

export default function Pay() {
  const { slug = "" } = useParams();
  const session = getSession();
  const navigate = useNavigate();
  const [methods, setMethods] = useState<PublicMethod[]>([]);
  const [methodId, setMethodId] = useState("");
  const [description, setDescription] = useState("");
  const [amount, setAmount] = useState("");
  const [invoice, setInvoice] = useState<Invoice | null>(null);
  const [code128, setCode128] = useState("");
  const [crypto, setCrypto] = useState<CryptoDetails | null>(null);
  const [reference, setReference] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [captchaToken, setCaptchaToken] = useState<string | null>(null);
  const [captchaFailed, setCaptchaFailed] = useState(false);
  const captchaBox = useRef<HTMLDivElement | null>(null);
  const captchaWidget = useRef<number | null>(null);

  // A customer may only pay on their own portal.
  const wrongPortal = session !== null && session.slug !== slug;

  useEffect(() => {
    if (!session) { navigate("/"); return; }
    if (wrongPortal) return;
    getPublicMethods(slug).then((d) => { setMethods(d.methods); setMethodId(d.methods[0]?.id ?? ""); }).catch((err: unknown) =>
      setError(isDenial(err) ? DENIAL_MESSAGE : "Could not load payment methods."));
  }, [slug, session, navigate, wrongPortal]);

  // Load + render the reCAPTCHA checkbox once the invoice (and the
  // confirm form) exists. Skips re-rendering if the widget is already up.
  useEffect(() => {
    if (!SITE_KEY || !invoice || !captchaBox.current || captchaWidget.current !== null) return;
    function render() {
      if (!captchaBox.current || !window.grecaptcha || captchaWidget.current !== null) return;
      captchaWidget.current = window.grecaptcha.render(captchaBox.current, {
        sitekey: SITE_KEY,
        callback: (token: string) => { setCaptchaToken(token); setCaptchaFailed(false); },
        "expired-callback": () => setCaptchaToken(null),
      });
    }
    if (window.grecaptcha) { render(); return; }
    const existing = document.querySelector('script[src*="recaptcha/api.js"]');
    if (existing) {
      existing.addEventListener("load", render);
      existing.addEventListener("error", () => setCaptchaFailed(true));
      return;
    }
    const script = document.createElement("script");
    script.src = "https://www.google.com/recaptcha/api.js?render=explicit";
    script.async = true;
    script.defer = true;
    script.onload = render;
    script.onerror = () => setCaptchaFailed(true);
    document.head.appendChild(script);
  }, [invoice]);

  function showError(err: unknown, fallback: string) {
    setError(isDenial(err) ? DENIAL_MESSAGE : err instanceof Error ? err.message : fallback);
  }

  async function create(e: FormEvent) {
    e.preventDefault(); setError(""); setMessage(""); setBusy(true);
    try {
      const data = await createInvoice({
        portalSlug: slug, payerEmail: session!.email, amount: Number(amount).toFixed(2),
        currency: "USD", items: [{ description, amount: Number(amount).toFixed(2) }], paymentMethodId: methodId,
      });
      setInvoice(data.invoice); setCrypto(data.crypto); setCode128(data.code128);
      setMessage(data.invoice.emailStatus === "SENT"
        ? "Barcode generated and sent to your email."
        : "Barcode generated. Email delivery is simulated in this build (no SMTP configured) — the barcode below is your payment barcode.");
    } catch (err) { showError(err, "Could not create invoice."); }
    finally { setBusy(false); }
  }

  async function confirm(e: FormEvent) {
    e.preventDefault(); setError(""); setBusy(true);
    try {
      const data = await confirmPayment(invoice!.id, reference.trim(), captchaToken ?? undefined);
      if (data.invoice.status === "PAID") {
        navigate(`/receipt/${invoice!.id}`);
      } else {
        // Reference recorded, invoice stays PENDING until Don or the
        // provider confirms — the receipt page shows that state, and the
        // proof of payment appears there once it is confirmed.
        setInvoice(data.invoice);
        setMessage(data.note ?? "Reference recorded. Awaiting confirmation — the invoice stays unpaid until Don or the payment provider confirms it.");
      }
    } catch (err) { showError(err, "Could not confirm payment."); }
    finally { setBusy(false); }
  }

  if (!session) return null;
  if (wrongPortal) return <p style={{ color: "red" }}>{DENIAL_MESSAGE}</p>;
  const input = { display: "block", width: "100%", padding: 10, margin: "6px 0 12px", fontSize: 16 } as const;
  const captchaRequired = SITE_KEY !== "";
  const captchaDone = !captchaRequired || captchaToken !== null;
  return (
    <div>
      <h2>Pay</h2>
      {!invoice ? (
        <form onSubmit={create}>
          <label>Payment method
            <select style={input} value={methodId} onChange={(e) => setMethodId(e.target.value)}>
              {methods.map((m) => <option key={m.id} value={m.id}>{m.label} — {m.handle}</option>)}
            </select>
          </label>
          <label>What is this for?
            <input style={input} value={description} onChange={(e) => setDescription(e.target.value)} required />
          </label>
          <label>Amount (USD)
            <input style={input} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="150.00" required />
          </label>
          {error && <p style={{ color: "red" }}>{error}</p>}
          <button type="submit" disabled={busy}>{busy ? "Generating barcode…" : "Generate payment barcode"}</button>
        </form>
      ) : (
        <div>
          <h3>Invoice {invoice.number} — {invoice.amount} {invoice.currency}</h3>
          <p>{message}</p>
          {invoice.barcodeQrDataUrl && <img src={invoice.barcodeQrDataUrl} alt="Payment QR code" width={220} height={220} />}
          <p>Barcode (Code128): <code>{code128 || invoice.barcodePayload}</code></p>
          {crypto && (
            <div style={{ border: "1px solid #ccc", padding: 12, margin: "12px 0" }}>
              <strong>Crypto payment — {crypto.currency}</strong>
              <p>Send exactly <strong>{crypto.amount} {crypto.currency}</strong> to:</p>
              <p><code style={{ wordBreak: "break-all" }}>{crypto.address}</code></p>
              <p>Reference: <code>{crypto.reference}</code>. Do not mark this paid until the payment is confirmed on-chain or by the provider.</p>
            </div>
          )}
          <form onSubmit={confirm}>
            <label>Payment reference (transaction hash / receipt ref)
              <input style={input} value={reference} onChange={(e) => setReference(e.target.value)} required />
            </label>
            {captchaRequired ? (
              <div style={{ margin: "12px 0" }}>
                <div ref={captchaBox} />
                {captchaFailed && <p style={{ color: "red" }}>Captcha could not be loaded. Check your connection and refresh the page.</p>}
                {!captchaToken && !captchaFailed && <p>Please complete the captcha above to confirm you are human.</p>}
              </div>
            ) : (
              <p style={{ color: "#666" }}>Captcha not configured — simulated mode. No human check is running on this portal yet.</p>
            )}
            {error && <p style={{ color: "red" }}>{error}</p>}
            <button type="submit" disabled={busy || !captchaDone}>{busy ? "Submitting…" : "I have paid — submit reference"}</button>
          </form>
          <p><Link to={`/receipt/${invoice.id}`}>View receipt</Link></p>
        </div>
      )}
    </div>
  );
}
