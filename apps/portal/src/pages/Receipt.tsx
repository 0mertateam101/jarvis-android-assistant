import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { DENIAL_MESSAGE, downloadReceiptPdf, getInvoice, isDenial, type Invoice } from "../api";

export default function Receipt() {
  const { id = "" } = useParams();
  const [invoice, setInvoice] = useState<Invoice | null>(null);
  const [pdfUrl, setPdfUrl] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    getInvoice(id).then((d) => setInvoice(d.invoice)).catch((err: unknown) =>
      setError(isDenial(err) ? DENIAL_MESSAGE : "Could not load the receipt."));
  }, [id]);

  // The PDF endpoint needs the customer JWT, so a plain link would 401.
  // Fetch it with the token and offer the blob as the download instead.
  useEffect(() => {
    let url = "";
    downloadReceiptPdf(id)
      .then((blob) => { url = URL.createObjectURL(blob); setPdfUrl(url); })
      .catch((err: unknown) => {
        if (isDenial(err)) setError(DENIAL_MESSAGE);
        // Any other failure just leaves the download hidden; the receipt
        // itself is already shown above.
      });
    return () => { if (url) URL.revokeObjectURL(url); };
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
      {invoice.status !== "PAID" && (
        <p>Payment not confirmed yet — the invoice stays unpaid until Don or the payment provider confirms it.</p>
      )}
      {pdfUrl && (
        <p>
          <a href={pdfUrl} download={`${invoice.number}-receipt.pdf`}>
            <button>Download PDF receipt</button>
          </a>
        </p>
      )}
    </div>
  );
}
