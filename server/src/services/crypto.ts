// Crypto payments — BTC / LTC / XMR / ETH.
//
// RULE: never mark an invoice PAID on QR/barcode scan alone.
// Confirmation must come from a provider webhook, an on-chain check, or
// Don's manual confirm in the Android app (dev / SIMULATED mode only).
// In SIMULATED mode the payment is recorded with simulated=true and the
// invoice stays PENDING until Don confirms.

export type CryptoCurrency = "BTC" | "LTC" | "XMR" | "ETH";

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
  private static RATES: Record<CryptoCurrency, number> = { BTC: 60000, LTC: 80, XMR: 150, ETH: 3000 };

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
// Copilot Prompt 7: implement this class, wire it in payments.ts when
// BTCPAY_URL + BTCPAY_API_KEY or COINBASE_COMMERCE_API_KEY are set.
// The provider webhook (not this method alone) is what flips an invoice
// to PAID in production.
// ---------------------------------------------------------------------------
export class ProviderCryptoService implements CryptoPaymentService {
  constructor(private provider: "btcpay" | "coinbase") {}

  async quote(opts: { currency: CryptoCurrency; address: string; fiatAmount: string; fiatCurrency: string }): Promise<CryptoQuote> {
    // TODO (Prompt 7): call the provider's invoice/charge API to create a
    // charge and return its address + amount. For now, delegate to the
    // simulated quote so the flow still works end-to-end in dev.
    const sim = new SimulatedCryptoService();
    const q = await sim.quote(opts);
    return { ...q, reference: "PENDING" };
  }

  async verify(opts: { currency: CryptoCurrency; reference: string; txHash?: string }): Promise<CryptoVerification> {
    // TODO (Prompt 7): query the provider (BTCPay invoice status or
    // Coinbase charge timeline) for `reference` / `txHash`.
    // Return confirmed=true ONLY when the provider reports the payment
    // as confirmed/complete. Never confirm on a QR scan.
    void opts;
    return { confirmed: false, simulated: false, note: `Provider (${this.provider}) verification not yet implemented — see Prompt 7.` };
  }
}

/** Factory: real provider when keys are set, simulated otherwise. */
export function getCryptoService(): CryptoPaymentService {
  if (process.env.BTCPAY_URL && process.env.BTCPAY_API_KEY) return new ProviderCryptoService("btcpay");
  if (process.env.COINBASE_COMMERCE_API_KEY) return new ProviderCryptoService("coinbase");
  return new SimulatedCryptoService();
}

export function isCryptoType(type: string): type is CryptoCurrency {
  return type === "BTC" || type === "LTC" || type === "XMR" || type === "ETH";
}
