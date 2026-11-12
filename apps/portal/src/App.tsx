import { useState } from "react";
import { Route, Routes, useNavigate } from "react-router-dom";
import Login from "./pages/Login";
import Pay from "./pages/Pay";
import PortalHome from "./pages/PortalHome";
import Receipt from "./pages/Receipt";
import { clearSession, getSession } from "./api";

// Customer portal shell. Routes:
//   /                → login (email + access code)
//   /portal/:slug    → portal home (assigned payment methods)
//   /portal/:slug/pay → create invoice, show barcode/QR, confirm payment
//   /receipt/:id     → receipt with proof hash + PDF download

export default function App() {
  const [session, setSession] = useState(getSession());
  const navigate = useNavigate();

  function handleLogin() { setSession(getSession()); }
  function handleLogout() { clearSession(); setSession(null); navigate("/"); }

  return (
    <div style={{ fontFamily: "system-ui, sans-serif", maxWidth: 640, margin: "0 auto", padding: 24 }}>
      <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <h1 style={{ fontSize: 22 }}>JARVIS Portal</h1>
        {session && <button onClick={handleLogout}>Sign out</button>}
      </header>
      <Routes>
        <Route path="/" element={<Login onLogin={handleLogin} />} />
        <Route path="/portal/:slug" element={<PortalHome />} />
        <Route path="/portal/:slug/pay" element={<Pay />} />
        <Route path="/receipt/:id" element={<Receipt />} />
        <Route path="*" element={<p>Page not found. <a href="/">Go to sign in</a></p>} />
      </Routes>
      <footer style={{ marginTop: 32, fontSize: 12, color: "#666" }}>
        Powered by JARVIS. Payments are confirmed by the portal owner or the payment provider — never by a barcode scan alone.
      </footer>
    </div>
  );
}
