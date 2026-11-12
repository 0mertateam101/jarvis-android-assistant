import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { getPublicMethods, getSession, type PublicMethod } from "../api";

export default function PortalHome() {
  const { slug = "" } = useParams();
  const session = getSession();
  const navigate = useNavigate();
  const [methods, setMethods] = useState<PublicMethod[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!session) { navigate("/"); return; }
    getPublicMethods(slug).then((d) => setMethods(d.methods)).catch(() => setError("Could not load payment methods."));
  }, [slug, session, navigate]);

  if (!session) return null;
  return (
    <div>
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
    </div>
  );
}
