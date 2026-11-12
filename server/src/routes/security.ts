import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db";
import { AuthedRequest, authMiddleware } from "../middleware/auth";
import { requireAdmin } from "../middleware/requireAdmin";
import { reverseLookup } from "../services/ipLookup";

// Security — visit logging, reverse lookup on unauthorised traffic,
// per-portal reports, blocklist + termination.
// Every login / payment attempt also checks BlockedUser first (access.ts,
// payments.ts). A blocked or TERMINATED user is always denied with a
// generic message — never with the reason.

export const securityRouter = Router();

const visitSchema = z.object({
  portalSlug: z.string().min(1),
  ip: z.string().min(1).max(45).optional(),
  userAgent: z.string().max(500).optional(),
  path: z.string().max(200).optional(),
  hasAccess: z.boolean().default(false),
  // Optional: when the visitor's email is supplied, the server verifies
  // the grant itself instead of trusting the client's hasAccess flag.
  email: z.string().email().optional(),
});

const blockSchema = z.object({
  portalId: z.string().min(1).optional(),
  email: z.string().email().optional(),
  ip: z.string().min(1).max(45).optional(),
  reason: z.string().min(1).max(300),
});

// Client IP: first X-Forwarded-For entry, else the socket address.
// The ::ffff: IPv4-mapped prefix is stripped so a blocked "127.0.0.1"
// matches the request IP "::ffff:127.0.0.1".
export function clientIp(req: { ip?: string; headers: Record<string, string | string[] | undefined> }): string {
  const forwarded = req.headers["x-forwarded-for"];
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded?.split(",")[0]?.trim();
  const raw = first ?? req.ip ?? "UNKNOWN";
  return raw.replace(/^::ffff:/, "");
}

// Shared blocklist checks (also used by login in access.ts and by payment
// confirm in payments.ts). A block applies to its portal, or globally when
// portalId is null.
export async function isEmailBlocked(portalId: string, email: string): Promise<boolean> {
  const blocked = await prisma.blockedUser.findFirst({
    where: { email: email.toLowerCase(), OR: [{ portalId }, { portalId: null }] },
  });
  return Boolean(blocked);
}

export async function isIpBlocked(ip: string, portalId: string): Promise<boolean> {
  const blocked = await prisma.blockedUser.findFirst({
    where: { ip, OR: [{ portalId }, { portalId: null }] },
  });
  return Boolean(blocked);
}

securityRouter.post("/visit", async (req, res) => {
  const parsed = visitSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  const portal = await prisma.portal.findUnique({ where: { slug: parsed.data.portalSlug } });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const ip = parsed.data.ip ?? clientIp(req);
  // Authorisation is verified server-side when an email is supplied: an
  // ACTIVE grant on this portal (and not blocklisted) means authorised,
  // regardless of what the client claimed. Otherwise the client's
  // hasAccess flag is taken at face value.
  let hasAccess = parsed.data.hasAccess;
  if (parsed.data.email) {
    const email = parsed.data.email.toLowerCase();
    const blocked = await isEmailBlocked(portal.id, email);
    const grant = blocked
      ? null
      : await prisma.accessGrant.findUnique({ where: { portalId_email: { portalId: portal.id, email } } });
    hasAccess = Boolean(grant && grant.status === "ACTIVE");
  }
  let lookup = { ptr: "UNKNOWN", country: "UNKNOWN", region: "UNKNOWN", city: "UNKNOWN", isp: "UNKNOWN", org: "UNKNOWN", lat: null as number | null, lon: null as number | null, source: "FALLBACK", simulated: true };
  if (!hasAccess) {
    // Unauthorised traffic only — authorised visits are logged without a lookup.
    lookup = await reverseLookup(ip);
  }
  const log = await prisma.trafficLog.create({
    data: {
      portalId: portal.id,
      ip,
      userAgent: parsed.data.userAgent ?? null,
      path: parsed.data.path ?? null,
      hasAccess,
      ptr: lookup.ptr,
      country: lookup.country,
      region: lookup.region,
      city: lookup.city,
      isp: lookup.isp,
      org: lookup.org,
      lat: lookup.lat,
      lon: lookup.lon,
      lookupSource: hasAccess ? "SKIPPED-HAS-ACCESS" : lookup.source,
      lookupSimulated: lookup.simulated,
    },
  });
  // A blocked IP is denied (generic) — but the visit is still logged above,
  // so the attempt stays in the portal's report.
  if (await isIpBlocked(ip, portal.id)) {
    res.status(403).json({ ok: false, error: { code: "FORBIDDEN", message: "Access denied" } });
    return;
  }
  res.status(201).json({ ok: true, data: { log } });
});

securityRouter.get("/portals/:portalId/traffic", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  // Owner-scoped report (Prompts 3–4 pattern): unknown portal, or one Don
  // does not own, is a 404. Accepts portal id or slug.
  const portal = await prisma.portal.findFirst({
    where: { ownerId: req.auth!.sub, OR: [{ id: req.params.portalId }, { slug: req.params.portalId }] },
  });
  if (!portal) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
    return;
  }
  const hasAccess = req.query.hasAccess === "true" ? true : req.query.hasAccess === "false" ? false : undefined;
  const limit = Math.min(Number(req.query.limit ?? 100) || 100, 500);
  const logs = await prisma.trafficLog.findMany({
    where: { portalId: portal.id, ...(hasAccess !== undefined ? { hasAccess } : {}) },
    orderBy: { createdAt: "desc" },
    take: limit,
  });
  res.json({ ok: true, data: { logs } });
});

securityRouter.post("/block", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = blockSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  if (!parsed.data.email && !parsed.data.ip) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Provide an email or an IP to block" } });
    return;
  }
  // If a portal is named (id or slug), it must exist and belong to the
  // caller — otherwise a bogus id would hit a foreign-key error (500) or
  // terminate another admin's grants.
  let portalId: string | null = null;
  if (parsed.data.portalId) {
    const portal = await prisma.portal.findFirst({
      where: { ownerId: req.auth!.sub, OR: [{ id: parsed.data.portalId }, { slug: parsed.data.portalId }] },
    });
    if (!portal) {
      res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Portal not found" } });
      return;
    }
    portalId = portal.id;
  }
  const blocked = await prisma.blockedUser.create({
    data: {
      portalId,
      email: parsed.data.email?.toLowerCase() ?? null,
      ip: parsed.data.ip ?? null,
      reason: parsed.data.reason,
      blockedById: req.auth!.sub,
    },
  });
  // Terminate that email's grants on the portal (policy termination).
  // Blocking an email with no grant is fine — it just pre-emptively blocks
  // future invites/logins for that email; nothing is terminated.
  if (parsed.data.email && portalId) {
    await prisma.accessGrant.updateMany({
      where: { portalId, email: parsed.data.email.toLowerCase() },
      data: { status: "TERMINATED" },
    });
  }
  res.status(201).json({ ok: true, data: { blocked } });
});

securityRouter.get("/blocked", authMiddleware, requireAdmin, async (_req, res) => {
  const blocked = await prisma.blockedUser.findMany({ orderBy: { createdAt: "desc" } });
  res.json({ ok: true, data: { blocked } });
});

securityRouter.post("/unblock", authMiddleware, requireAdmin, async (req: AuthedRequest, res) => {
  const parsed = z.object({ blockedId: z.string().min(1) }).safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid body" } });
    return;
  }
  // Unknown id, or a block on a portal Don does not own, is a 404 — never
  // a 500, and never an unblock across admins.
  const row = await prisma.blockedUser.findUnique({
    where: { id: parsed.data.blockedId },
    include: { portal: { select: { ownerId: true } } },
  });
  if (!row) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Blocked entry not found" } });
    return;
  }
  if (row.portal && row.portal.ownerId !== req.auth!.sub) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Blocked entry not found" } });
    return;
  }
  if (!row.portal && row.blockedById !== req.auth!.sub) {
    res.status(404).json({ ok: false, error: { code: "NOT_FOUND", message: "Blocked entry not found" } });
    return;
  }
  await prisma.blockedUser.delete({ where: { id: row.id } });
  // Note: unblocking does NOT reactivate a TERMINATED grant. Re-invite
  // the customer (POST /api/access/invite) to give them a fresh code.
  res.json({ ok: true, data: { ok: true } });
});
