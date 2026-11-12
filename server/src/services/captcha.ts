// reCAPTCHA verification (Prompt 12) — prove a payment submit comes
// from a human before the server records it.
//
// Two modes, exactly like the rest of Jarvis:
// - SIMULATED (default): no RECAPTCHA_SECRET_KEY configured. Captcha is
//   NOT required, every submit passes, and the response says so
//   (simulated: true). Nothing is sent to Google.
// - CONFIGURED: RECAPTCHA_SECRET_KEY is set. A customer submit MUST
//   carry a valid token: missing token → not verified; the token is
//   POSTed to Google's siteverify endpoint and Google's `success` value
//   decides. A network error (or timeout) counts as NOT verified —
//   never as a pass. Don's ADMIN manual confirm never needs a captcha.
//
// No real keys live in this repo — see .env.example. The client-side
// site key (RECAPTCHA_SITE_KEY) is a public identifier, not a secret,
// and is read by the portal app from VITE_RECAPTCHA_SITE_KEY.

export interface CaptchaResult {
  /** Whether a captcha check was required at all (false in SIMULATED mode). */
  required: boolean;
  /** Whether the submit is verified as human. */
  ok: boolean;
  /** True when no secret is configured (SIMULATED mode). */
  simulated: boolean;
}

const SITEVERIFY_URL = "https://www.google.com/recaptcha/api/siteverify";
const VERIFY_TIMEOUT_MS = 5_000;

function isConfigured(): boolean {
  return Boolean(process.env.RECAPTCHA_SECRET_KEY);
}

/**
 * Verify a customer-submitted reCAPTCHA token. `token` may be undefined
 * (no token sent). In SIMULATED mode this always returns ok=true and
 * never calls Google. In configured mode a missing token fails fast
 * and a present token is checked against Google with a 5s timeout.
 */
export async function verifyCaptcha(token: string | undefined): Promise<CaptchaResult> {
  if (!isConfigured()) {
    return { required: false, ok: true, simulated: true };
  }
  if (!token) {
    return { required: true, ok: false, simulated: false };
  }
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), VERIFY_TIMEOUT_MS);
    try {
      const res = await fetch(SITEVERIFY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ secret: process.env.RECAPTCHA_SECRET_KEY as string, response: token }),
        signal: controller.signal,
      });
      const body = (await res.json()) as { success?: boolean };
      return { required: true, ok: body.success === true, simulated: false };
    } finally {
      clearTimeout(timer);
    }
  } catch {
    // Network error / timeout: NOT verified. A failure to reach Google
    // must never silently pass a bot through.
    return { required: true, ok: false, simulated: false };
  }
}
