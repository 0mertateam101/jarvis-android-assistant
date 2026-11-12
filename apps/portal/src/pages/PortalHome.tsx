import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { DENIAL_MESSAGE, getPublicMethods, getSession, isDenial, type PublicMethod } from "../api";

export default function PortalHome() {
  const { slug = "" } = useParams();
  const session = getSession();
  const navigate = useNavigate();
  const [methods, setMethods] = useState<PublicMethod[]>([]);
  const [error, setError] = useState("");

  // A customer may only see their own portal: visiting another portal's
  // home is a generic denial, never that portal's methods.
  const wrongPortal = session !== null && session.slug !== slug;

  useEffect(() => {
    if (!session) { navigate("/"); return; }
    if (wrongPortal) return;
    getPublicMethods(slug).then((d) => setMethods(d.methods)).catch((err: unknown) =>
      setError(isDenial(err) ? DENIAL_MESSAGE : "Could not load payment methods."));
  }, [slug, session, navigate, wrongPortal]);

  if (!session) return null;
  if (wrongPortal) return <p style={{ color: "red" }}>{DENIAL_MESSAGE}</p>;
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
