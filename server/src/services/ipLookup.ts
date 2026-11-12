import dns from "node:dns";

// Reverse lookup for unauthorised portal visitors.
// Runs ONLY when the visitor has no valid grant (see routes/security.ts).
// Two steps, both best-effort with a 3s timeout, then a safe fallback:
//   1. dns.reverse(ip) → PTR hostname
//   2. GET <IP_LOOKUP_BASE_URL>/json/<ip> (default ip-api.com, free, no key)
//      → country / region / city / ISP / org / lat / lon
// On any failure the fields fall back to "UNKNOWN" — the visit is still
// logged, and lookupSource records "FALLBACK" so Don can see it was a
// degraded lookup. No paid lookup key is needed.

export interface IpLookupResult {
  ptr: string;
  country: string;
  region: string;
  city: string;
  isp: string;
  org: string;
  lat: number | null;
  lon: number | null;
  source: string; // "PTR+ip-api" | "FALLBACK"
  simulated: boolean; // true when the lookup was degraded / local IP
}

const UNKNOWN: IpLookupResult = {
  ptr: "UNKNOWN",
  country: "UNKNOWN",
  region: "UNKNOWN",
  city: "UNKNOWN",
  isp: "UNKNOWN",
  org: "UNKNOWN",
  lat: null,
  lon: null,
  source: "FALLBACK",
  simulated: true,
};

function reversePtr(ip: string): Promise<string> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("UNKNOWN"), 3000);
    dns.reverse(ip, (err, hostnames) => {
      clearTimeout(timer);
      if (err || !hostnames?.length) resolve("UNKNOWN");
      else resolve(hostnames[0]);
    });
  });
}

interface IpApiResponse {
  status?: string;
  country?: string;
  regionName?: string;
  city?: string;
  isp?: string;
  org?: string;
  lat?: number;
  lon?: number;
}

async function geoLookup(ip: string): Promise<Partial<IpLookupResult>> {
  const base = (process.env.IP_LOOKUP_BASE_URL ?? "http://ip-api.com").replace(/\/$/, "");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const res = await fetch(`${base}/json/${encodeURIComponent(ip)}?fields=status,country,regionName,city,isp,org,lat,lon`, {
      signal: controller.signal,
    });
    if (!res.ok) return {};
    const data = (await res.json()) as IpApiResponse;
    if (data.status !== "success") return {};
    return {
      country: data.country ?? "UNKNOWN",
      region: data.regionName ?? "UNKNOWN",
      city: data.city ?? "UNKNOWN",
      isp: data.isp ?? "UNKNOWN",
      org: data.org ?? "UNKNOWN",
      lat: data.lat ?? null,
      lon: data.lon ?? null,
    };
  } catch {
    return {};
  } finally {
    clearTimeout(timer);
  }
}

function isPrivateOrLocal(ip: string): boolean {
  return (
    ip === "::1" ||
    ip === "127.0.0.1" ||
    ip.startsWith("10.") ||
    ip.startsWith("192.168.") ||
    ip.startsWith("172.16.") ||
    ip.startsWith("172.17.") ||
    ip.startsWith("172.18.") ||
    ip.startsWith("172.19.") ||
    ip.startsWith("172.2") ||
    ip.startsWith("172.30.") ||
    ip.startsWith("172.31.")
  );
}

export async function reverseLookup(ip: string): Promise<IpLookupResult> {
  if (isPrivateOrLocal(ip)) {
    return { ...UNKNOWN, ptr: "LOCAL/PRIVATE", source: "FALLBACK" };
  }
  const [ptr, geo] = await Promise.all([reversePtr(ip), geoLookup(ip)]);
  const degraded = ptr === "UNKNOWN" && !geo.country;
  return {
    ptr,
    country: geo.country ?? "UNKNOWN",
    region: geo.region ?? "UNKNOWN",
    city: geo.city ?? "UNKNOWN",
    isp: geo.isp ?? "UNKNOWN",
    org: geo.org ?? "UNKNOWN",
    lat: geo.lat ?? null,
    lon: geo.lon ?? null,
    source: degraded ? "FALLBACK" : "PTR+ip-api",
    simulated: degraded,
  };
}
