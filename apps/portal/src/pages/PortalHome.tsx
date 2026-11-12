import { useEffect, useState, type FormEvent } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { DENIAL_MESSAGE, assetFileUrl, getMyIdVerification, getPublicMethods, getSession, isDenial, uploadIdVerification, type IdVerification, type PublicDocument, type PublicMethod } from "../api";

const ID_TYPES = [
  { value: "DRIVERS_LICENSE", label: "Driver's license" },
  { value: "STATE_ID", label: "State ID card" },
  { value: "NATIONAL_ID", label: "National ID card" },
] as const;

export default function PortalHome() {
  const { slug = "" } = useParams();
  const session = getSession();
  const navigate = useNavigate();
  const [methods, setMethods] = useState<PublicMethod[]>([]);
  const [logoAssetId, setLogoAssetId] = useState<string | null>(null);
  const [bannerAssetId, setBannerAssetId] = useState<string | null>(null);
  const [documents, setDocuments] = useState<PublicDocument[]>([]);
  const [error, setError] = useState("");
  const [verification, setVerification] = useState<IdVerification | null>(null);
  const [idType, setIdType] = useState<string>("DRIVERS_LICENSE");
  const [front, setFront] = useState<File | null>(null);
  const [back, setBack] = useState<File | null>(null);
  const [selfie, setSelfie] = useState<File | null>(null);
  const [frontPreview, setFrontPreview] = useState<string | null>(null);
  const [backPreview, setBackPreview] = useState<string | null>(null);
  const [selfiePreview, setSelfiePreview] = useState<string | null>(null);
  const [idMessage, setIdMessage] = useState("");
  const [idError, setIdError] = useState("");
  const [idBusy, setIdBusy] = useState(false);

  // A customer may only see their own portal: visiting another portal's
  // home is a generic denial, never that portal's methods.
  const wrongPortal = session !== null && session.slug !== slug;

  useEffect(() => {
    if (!session) { navigate("/"); return; }
    if (wrongPortal) return;
    getPublicMethods(slug).then((d) => {
      setMethods(d.methods);
      setLogoAssetId(d.logoAssetId);
      setBannerAssetId(d.bannerAssetId);
      setDocuments(d.documents);
    }).catch((err: unknown) =>
      setError(isDenial(err) ? DENIAL_MESSAGE : "Could not load payment methods."));
    getMyIdVerification(slug).then((d) => setVerification(d.verification)).catch(() => {
      // 404 = no verification uploaded yet — not an error.
    });
  }, [slug, session, navigate, wrongPortal]);

  async function submitId(e: FormEvent) {
    e.preventDefault(); setIdError(""); setIdMessage("");
    if (!front || !back || !selfie) { setIdError("All three pictures are required: front, back, and a picture of you holding the ID."); return; }
    setIdBusy(true);
    try {
      const portalId = session!.id;
      const data = await uploadIdVerification(portalId, idType, front, back, selfie);
      setVerification(data.verification);
      setIdMessage("ID pictures uploaded — status: PENDING. Don will review them. You can still pay while you wait; verification does not block payment.");
    } catch (err) {
      setIdError(err instanceof Error ? err.message : "Could not upload ID pictures.");
    } finally { setIdBusy(false); }
  }

  if (!session) return null;
  if (wrongPortal) return <p style={{ color: "red" }}>{DENIAL_MESSAGE}</p>;
  const input = { display: "block", width: "100%", padding: 10, margin: "6px 0 12px", fontSize: 16 } as const;
  function pickFile(setFile: (f: File | null) => void, setPreview: (u: string | null) => void) {
    return (e: React.ChangeEvent<HTMLInputElement>) => {
      const f = e.target.files?.[0] ?? null;
      setFile(f);
      setPreview(f ? URL.createObjectURL(f) : null);
    };
  }
  return (
    <div>
      {logoAssetId && <img src={assetFileUrl(slug, logoAssetId)} alt="Portal logo" style={{ maxWidth: 200, display: "block", marginBottom: 12 }} />}
      {bannerAssetId && <img src={assetFileUrl(slug, bannerAssetId)} alt="Portal banner" style={{ maxWidth: "100%", display: "block", marginBottom: 12 }} />}
      <h2>Welcome, {session.email}</h2>
      <p>You have access to this portal. Choose a payment method to pay.</p>
      {error && <p style={{ color: "red" }}>{error}</p>}
      <ul>
        {methods.map((m) => (
          <li key={m.id} style={{ margin: "8px 0" }}>
            <strong>{m.label}</strong> — {m.type} ({m.handle})
          </li>
        ))}
        {methods.length === 0 && <li>No payment methods assigned to this portal yet.</li>}
      </ul>
      <Link to={`/portal/${slug}/pay`}><button>Pay now</button></Link>

      {documents.length > 0 && (
        <div style={{ marginTop: 24 }}>
          <h3>Documents</h3>
          <ul>
            {documents.map((d) => (
              <li key={d.id}>
                <a href={assetFileUrl(slug, d.id)} target="_blank" rel="noreferrer">{d.originalName}</a> ({d.kind})
              </li>
            ))}
          </ul>
        </div>
      )}

      <div style={{ marginTop: 24, borderTop: "1px solid #ccc", paddingTop: 16 }}>
        <h3>ID verification</h3>
        <p>Upload pictures of your ID so Don can verify who is paying. Passports are <strong>not</strong> accepted — use a driver's license, state ID, or national ID card.</p>
        {verification && (
          <p>
            Current status: <strong>{verification.status}</strong> ({verification.idType.replace(/_/g, " ")}
            {verification.status === "REJECTED" ? " — please upload again with clear pictures." : ""}
            {verification.status === "VERIFIED" ? " — verified by Don." : ""})
          </p>
        )}
        <form onSubmit={submitId}>
          <label>ID type
            <select style={input} value={idType} onChange={(e) => setIdType(e.target.value)}>
              {ID_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </label>
          <label>Front of ID
            <input style={input} type="file" accept="image/jpeg,image/png,image/webp" onChange={pickFile(setFront, setFrontPreview)} required />
          </label>
          {frontPreview && <img src={frontPreview} alt="Front of ID preview" style={{ maxWidth: 220, display: "block", marginBottom: 12 }} />}
          <label>Back of ID
            <input style={input} type="file" accept="image/jpeg,image/png,image/webp" onChange={pickFile(setBack, setBackPreview)} required />
          </label>
          {backPreview && <img src={backPreview} alt="Back of ID preview" style={{ maxWidth: 220, display: "block", marginBottom: 12 }} />}
          <label>Picture of you holding the ID
            <input style={input} type="file" accept="image/jpeg,image/png,image/webp" onChange={pickFile(setSelfie, setSelfiePreview)} required />
          </label>
          {selfiePreview && <img src={selfiePreview} alt="Selfie holding ID preview" style={{ maxWidth: 220, display: "block", marginBottom: 12 }} />}
          {idError && <p style={{ color: "red" }}>{idError}</p>}
          {idMessage && <p>{idMessage}</p>}
          <button type="submit" disabled={idBusy}>{idBusy ? "Uploading…" : verification ? "Re-upload ID pictures" : "Upload ID pictures"}</button>
        </form>
        <p style={{ color: "#666" }}>Your ID pictures are private — only Don can see them. Verification does not block payment.</p>
      </div>
    </div>
  );
}
