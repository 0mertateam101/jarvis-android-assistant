import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { getInvoice, receiptPdfUrl, type Invoice } from "../api";

export default function Receipt() {
  const { id = "" } = useParams();
  const [invoice, setInvoice] = useState<Invoice | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    getInvoice(id).then((d) => setInvoice(d.invoice)).catch(() => setError("Could not load the receipt."));
  }, [id]);

  if (error) return <p style={{ color: "red" }}>{error}</p>;
  if (!invoice) return <p>Loading receipt…</p>;
  return (
    <div>
      <h2>Receipt — {invoice.number}</h2>
      <p>Status: <strong>{invoice.status}</strong></p>
      <p>Amount: <strong>{invoice.amount} {invoice.currency}</strong></p>
      <p>Payer: {invoice.payerEmail}</p>
      <p>Barcode: <code>{invoice.barcodePayload}</code></p>
      {invoice.proofHash ? (
        <p>Proof of payment: <code style={{ wordBreak: "break-all" }}>{invoice.proofHash}</code></p>
      ) : (
        <p>Proof of payment will appear here once the payment is confirmed.</p>
      )}
      <p>
        <a href={receiptPdfUrl(invoice.id)} target="_blank" rel="noreferrer">
          <button>Download PDF receipt</button>
        </a>
      </p>
    </div>
  );
}
