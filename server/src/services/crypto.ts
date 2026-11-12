// Crypto payments — BTC / LTC / XMR / ETH / USDT / USDC / DOGE.
//
// RULE: never mark an invoice PAID on QR/barcode scan alone, and never on
// a customer-submitted txHash alone. Confirmation must come from a
// provider webhook, an on-chain check, or Don's manual confirm in the
// Android app (SIMULATED mode only — with a provider configured, manual
// confirm is refused; see payments.ts). In SIMULATED mode the payment is
// recorded with simulated=true and the invoice stays PENDING until Don
// confirms.

import { createHmac, timingSafeEqual } from "node:crypto";

export type CryptoCurrency = "BTC" | "LTC" | "XMR" | "ETH" | "USDT" | "USDC" | "DOGE";

export interface CryptoQuote {
  currency: CryptoCurrency;
  address: string; // public address only — never a private key
  amount: string; // exact crypto amount the customer must send
  reference: string; // invoice number, e.g. JAR-1001
  fiatAmount: string;
  fiatCurrency: string;
}

export interface CryptoVerification {
  confirmed: boolean;
  txHash?: string;
  confirmations?: number;
  simulated: boolean;
  note: string;
}

export interface CryptoPaymentService {
  /** Build the payment details shown to the customer. */
  quote(opts: {
    currency: CryptoCurrency;
    address: string;
    fiatAmount: string;
    fiatCurrency: string;
  }): Promise<CryptoQuote>;
  /** Verify a payment reference / txHash. Must NOT return confirmed=true in simulated mode. */
  verify(opts: { currency: CryptoCurrency; reference: string; txHash?: string }): Promise<CryptoVerification>;
}

// ---------------------------------------------------------------------------
// Simulated service (default). Used when no provider keys are configured.
// It NEVER confirms a payment on its own — Don confirms manually.
// ---------------------------------------------------------------------------
export class SimulatedCryptoService implements CryptoPaymentService {
  // Fixed dev conversion rates — clearly fake, for UI testing only.
  // Real rates must come from the provider / an exchange API (Prompt 7).
  // USDT / USDC are pegged to 1 USD; DOGE 0.2 is a made-up dev rate.
  private static RATES: Record<CryptoCurrency, number> = { BTC: 60000, LTC: 80, XMR: 150, ETH: 3000, USDT: 1, USDC: 1, DOGE: 0.2 };

  async quote(opts: { currency: CryptoCurrency; address: string; fiatAmount: string; fiatCurrency: string }): Promise<CryptoQuote> {
    const rate = SimulatedCryptoService.RATES[opts.currency];
    const amount = (Number(opts.fiatAmount) / rate).toFixed(8);
    return {
      currency: opts.currency,
      address: opts.address,
      amount,
      reference: "PENDING", // caller overwrites with the invoice number
      fiatAmount: opts.fiatAmount,
      fiatCurrency: opts.fiatCurrency,
    };
  }

  async verify(_opts: { currency: CryptoCurrency; reference: string; txHash?: string }): Promise<CryptoVerification> {
    return {
      confirmed: false,
      simulated: true,
      note: "SIMULATED mode: no provider configured. Don must confirm this payment manually in the Jarvis app.",
    };
  }
}

// ---------------------------------------------------------------------------
// INTEGRATION POINT — real provider (BTCPay Server / Coinbase Commerce).
// Wired in automatically by getCryptoService() when the env vars are set:
//   BTCPay:   BTCPAY_URL + BTCPAY_API_KEY (+ BTCPAY_WEBHOOK_SECRET for the
//             webhook receiver in payments.ts)
//   Coinbase: COINBASE_COMMERCE_API_KEY (+ COINBASE_WEBHOOK_SECRET)
// See .env.example. No real provider call is made anywhere in this repo
// yet — quote() delegates to the simulated quote and verify() always
// returns confirmed=false, so in provider mode an invoice can ONLY become
// PAID through the signed webhook endpoint POST /api/webhooks/crypto/:provider
// (see payments.ts). That is deliberate: a half-wired provider must never
// be able to confirm a payment it did not actually verify.
//
// To finish the integration (a later prompt, once Don has provider keys):
//   1. quote(): call the provider's invoice/charge API (BTCPay
//      POST /api/v1/stores/{storeId}/invoices, or Coinbase
//      POST /v2/charges) and return the provider's address + amount.
//      The fiat→crypto conversion must come from the provider or an
//      exchange rate API — never the fake fixed rates in
//      SimulatedCryptoService.
//   2. verify(): query the provider for `reference` (our invoice number)
//      / `txHash` (BTCPay invoice status, or Coinbase charge timeline)
//      and return confirmed=true ONLY when the provider reports the
//      payment as confirmed/complete. Never confirm on a QR scan, and
//      never confirm on a customer-submitted txHash alone.
//   3. Webhook: point the provider at POST /api/webhooks/crypto/:provider
//      with the webhook secret — that endpoint is already implemented and
//      HMAC-verified; it is the production path to PAID.
// ---------------------------------------------------------------------------
export class ProviderCryptoService implements CryptoPaymentService {
  constructor(private provider: "btcpay" | "coinbase") {}

  async quote(opts: { currency: CryptoCurrency; address: string; fiatAmount: string; fiatCurrency: string }): Promise<CryptoQuote> {
    // TODO (provider integration, step 1 above): call the provider's
    // invoice/charge API and return its address + amount. For now, delegate
    // to the simulated quote so the flow still works end-to-end in dev.
    const sim = new SimulatedCryptoService();
    const q = await sim.quote(opts);
    return { ...q, reference: "PENDING" };
  }

  async verify(opts: { currency: CryptoCurrency; reference: string; txHash?: string }): Promise<CryptoVerification> {
    // TODO (provider integration, step 2 above): query the provider
    // (BTCPay invoice status or Coinbase charge timeline) for `reference` /
    // `txHash`. Return confirmed=true ONLY when the provider reports the
    // payment as confirmed/complete. Never confirm on a QR scan.
    void opts;
    return { confirmed: false, simulated: false, note: `Provider (${this.provider}) verification not yet implemented — confirmation must arrive via the provider webhook (see payments.ts).` };
  }
}

/** Factory: real provider when keys are set, simulated otherwise. */
export function getCryptoService(): CryptoPaymentService {
  if (process.env.BTCPAY_URL && process.env.BTCPAY_API_KEY) return new ProviderCryptoService("btcpay");
  if (process.env.COINBASE_COMMERCE_API_KEY) return new ProviderCryptoService("coinbase");
  return new SimulatedCryptoService();
}

/** "provider" when real provider keys are configured, otherwise "simulated". */
export function cryptoMode(): "simulated" | "provider" {
  if (process.env.BTCPAY_URL && process.env.BTCPAY_API_KEY) return "provider";
  if (process.env.COINBASE_COMMERCE_API_KEY) return "provider";
  return "simulated";
}

export function isCryptoType(type: string): type is CryptoCurrency {
  return type === "BTC" || type === "LTC" || type === "XMR" || type === "ETH" || type === "USDT" || type === "USDC" || type === "DOGE";
}

// --- Customer-submitted reference validation ---
// A crypto payment reference is either a transaction hash (64 hex chars,
// optionally 0x-prefixed for ETH) or a provider reference (e.g. a BTCPay
// invoice id / Coinbase charge code). Anything else — too short, spaces,
// punctuation — is rejected with a 400 before it is ever stored.
const TX_HASH_64 = /^(0x)?[0-9a-fA-F]{64}$/;
const PROVIDER_REF = /^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$/;

/** Validate a customer-submitted crypto reference. Returns an error message, or null when it looks plausible. */
export function cryptoReferenceError(value: string): string | null {
  if (TX_HASH_64.test(value)) return null;
  if (PROVIDER_REF.test(value)) return null;
  return "reference must be a transaction hash (64 hex chars, optionally 0x-prefixed) or a provider reference";
}

// --- Provider webhook signature verification ---
// BTCPay sends `BTCPay-Sig: sha256=<hex>`; Coinbase sends
// `X-CC-Webhook-Signature: <hex>` — both are HMAC-SHA256 over the raw
// request body. The raw body is stashed on the request by the json
// middleware in src/index.ts (express.json `verify` option).
/** Verify an HMAC-SHA256 webhook signature (hex, optionally "sha256=" prefixed). */
export function verifyWebhookSignature(secret: string, rawBody: Buffer, signature: string | undefined): boolean {
  if (!signature) return false;
  const hex = signature.startsWith("sha256=") ? signature.slice("sha256=".length) : signature;
  if (!/^[0-9a-fA-F]+$/.test(hex)) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest("hex");
  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(hex.toLowerCase(), "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
